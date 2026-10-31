// PW-CS2-Optimizer.cs  (v5.0  GUI Edition)
// 完美世界竞技平台 / CS2 CPU+内存 优化器
// 编译: csc /target:winexe /win32manifest:app.manifest ...
// 依赖: .NET Framework 4.x (Windows 自带)，无任何第三方库

using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Linq;
using System.Management;
using System.Runtime.InteropServices;
using System.Runtime.Serialization;
using System.Runtime.Serialization.Json;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

// ==================================================================
//  Win32 P/Invoke
// ==================================================================
internal static class Native
{
    [StructLayout(LayoutKind.Sequential)]
    public struct PTS { public uint Version; public uint ControlMask; public uint StateMask; }

    [StructLayout(LayoutKind.Sequential)]
    public struct MEMPRIO { public uint MemoryPriority; }

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    public struct LUID { public uint Low; public int High; }

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    public struct LUID_AND_ATTRIBUTES { public LUID Luid; public uint Attributes; }

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    public struct TOKEN_PRIVILEGES { public uint Count; public LUID_AND_ATTRIBUTES Priv; }

    [StructLayout(LayoutKind.Sequential)]
    public struct MEMSTATUS
    {
        public uint dwLength;
        public uint dwMemoryLoad;
        public ulong ullTotalPhys;
        public ulong ullAvailPhys;
        public ulong ullTotalPageFile;
        public ulong ullAvailPageFile;
        public ulong ullTotalVirtual;
        public ulong ullAvailVirtual;
        public ulong ullAvailExtendedVirtual;
    }

    public const int ProcessMemoryPriority = 0;
    public const int ProcessPowerThrottling = 4;
    public const uint ExecutionSpeed = 0x1;
    public const uint Access = 0x0200 | 0x0400 | 0x1000;
    public const uint BelowNormalPriorityClass = 0x00004000;
    public const uint NormalPriorityClass = 0x00000020;
    public const uint AboveNormalPriorityClass = 0x00008000;
    public const uint HighPriorityClass = 0x00000080;
    public const uint MemoryPriorityLow = 2;

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool SetProcessInformation(IntPtr h, int cls, ref PTS info, uint size);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetProcessInformation(IntPtr h, int cls, ref PTS info, uint size);
    [DllImport("kernel32.dll", EntryPoint = "SetProcessInformation", SetLastError = true)]
    public static extern bool SetProcessInfoMem(IntPtr h, int cls, ref MEMPRIO info, uint size);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool SetPriorityClass(IntPtr h, uint cls);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool SetProcessAffinityMask(IntPtr h, UIntPtr mask);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetProcessAffinityMask(IntPtr h, out UIntPtr procMask, out UIntPtr sysMask);
    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern bool OpenProcessToken(IntPtr p, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool LookupPrivilegeValue(string system, string name, out LUID luid);
    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern bool AdjustTokenPrivileges(IntPtr token, bool disableAll, ref TOKEN_PRIVILEGES newState, uint len, IntPtr prev, IntPtr retLen);
    [DllImport("kernel32.dll")]
    public static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GlobalMemoryStatusEx(ref MEMSTATUS lpBuffer);
    [DllImport("kernel32.dll")]
    public static extern bool GetSystemTimes(out ulong idle, out ulong kernel, out ulong user);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool IsProcessInJob(IntPtr proc, IntPtr job, out bool result);

    public static bool EnablePrivilege(string name)
    {
        IntPtr token;
        if (!OpenProcessToken(GetCurrentProcess(), 0x0020 | 0x0008, out token)) return false;
        try
        {
            LUID luid;
            if (!LookupPrivilegeValue(null, name, out luid)) return false;
            TOKEN_PRIVILEGES tp = new TOKEN_PRIVILEGES();
            tp.Count = 1;
            tp.Priv.Luid = luid;
            tp.Priv.Attributes = 0x00000002;
            return AdjustTokenPrivileges(token, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
        }
        finally { CloseHandle(token); }
    }

    public static bool MemInfo(out ulong totalMb, out ulong availMb, out uint loadPct)
    {
        MEMSTATUS m = new MEMSTATUS();
        m.dwLength = (uint)Marshal.SizeOf(typeof(MEMSTATUS));
        totalMb = 0; availMb = 0; loadPct = 0;
        if (!GlobalMemoryStatusEx(ref m)) return false;
        totalMb = m.ullTotalPhys / 1048576UL;
        availMb = m.ullAvailPhys / 1048576UL;
        loadPct = m.dwMemoryLoad;
        return true;
    }
}

// ==================================================================
//  进程调优结果
// ==================================================================
public class TuneResult
{
    public bool EcoOn;
    public bool PriorityOk;
    public bool MemoryOk;
    public bool AffinityOk;
    public int Error;
    public bool Ok { get { return EcoOn && PriorityOk && AffinityOk; } }
}

public static class ProcTuner
{
    public static TuneResult ApplyPlatform(int pid, ulong mask, bool supportEco)
    {
        TuneResult r = new TuneResult();
        IntPtr h = Native.OpenProcess(Native.Access, false, pid);
        if (h == IntPtr.Zero) { r.Error = Marshal.GetLastWin32Error(); return r; }
        try
        {
            if (supportEco)
            {
                Native.PTS s = new Native.PTS();
                s.Version = 1;
                s.ControlMask = Native.ExecutionSpeed;
                s.StateMask = Native.ExecutionSpeed;
                r.EcoOn = Native.SetProcessInformation(h, Native.ProcessPowerThrottling, ref s, (uint)Marshal.SizeOf(typeof(Native.PTS)));
                if (!r.EcoOn) r.Error = Marshal.GetLastWin32Error();
            }
            else r.EcoOn = true;

            r.PriorityOk = Native.SetPriorityClass(h, Native.BelowNormalPriorityClass);
            if (!r.PriorityOk && r.Error == 0) r.Error = Marshal.GetLastWin32Error();

            Native.MEMPRIO m = new Native.MEMPRIO();
            m.MemoryPriority = Native.MemoryPriorityLow;
            r.MemoryOk = Native.SetProcessInfoMem(h, Native.ProcessMemoryPriority, ref m, 4);

            r.AffinityOk = Native.SetProcessAffinityMask(h, new UIntPtr(mask));
            if (!r.AffinityOk && r.Error == 0) r.Error = Marshal.GetLastWin32Error();
            return r;
        }
        finally { Native.CloseHandle(h); }
    }

    public static TuneResult ApplyGame(int pid, ulong mask, uint prioClass)
    {
        TuneResult r = new TuneResult();
        IntPtr h = Native.OpenProcess(Native.Access, false, pid);
        if (h == IntPtr.Zero) { r.Error = Marshal.GetLastWin32Error(); return r; }
        try
        {
            r.PriorityOk = Native.SetPriorityClass(h, prioClass);
            if (!r.PriorityOk) r.Error = Marshal.GetLastWin32Error();
            r.AffinityOk = Native.SetProcessAffinityMask(h, new UIntPtr(mask));
            if (!r.AffinityOk && r.Error == 0) r.Error = Marshal.GetLastWin32Error();
            r.EcoOn = true;
            r.MemoryOk = true;
            return r;
        }
        finally { Native.CloseHandle(h); }
    }
}

public static class ErrText
{
    public static string Get(int code)
    {
        switch (code)
        {
            case 0: return "成功";
            case 5: return "拒绝访问（进程权限更高，通常为反作弊/系统进程，属正常）";
            case 87: return "参数无效（进程可能正在退出）";
            case 6: return "句柄无效";
            case 1168: return "找不到元素（进程已退出）";
            default: return "错误码 " + code;
        }
    }
}

// ==================================================================
//  配置
// ==================================================================
[DataContract]
public class AppConfig
{
    [DataMember(Name = "PlatformPath")] public string PlatformPath = "";
    [DataMember(Name = "GameProcessName")] public string GameProcessName = "cs2";
    [DataMember(Name = "Cs2Affinity")] public string Cs2Affinity = "Exclude01";
    [DataMember(Name = "CustomMask")] public string CustomMask = "";
    [DataMember(Name = "Cs2Priority")] public string Cs2Priority = "AboveNormal";
    [DataMember(Name = "PlatCoresCount")] public int PlatCoresCount = 2;
    [DataMember(Name = "IntervalMs")] public int IntervalMs = 1000;
    [DataMember(Name = "AutoLaunchPlatform")] public bool AutoLaunchPlatform = true;
    [DataMember(Name = "LogMaxMb")] public int LogMaxMb = 10;
    [DataMember(Name = "GameKillApps")] public List<string> GameKillApps = new List<string>();
    [DataMember(Name = "ClearLogAfterGame")] public bool ClearLogAfterGame = true;

    public AppConfig Clone()
    {
        AppConfig c = new AppConfig();
        c.PlatformPath = PlatformPath;
        c.GameProcessName = GameProcessName;
        c.Cs2Affinity = Cs2Affinity;
        c.CustomMask = CustomMask;
        c.Cs2Priority = Cs2Priority;
        c.PlatCoresCount = PlatCoresCount;
        c.IntervalMs = IntervalMs;
        c.AutoLaunchPlatform = AutoLaunchPlatform;
        c.LogMaxMb = LogMaxMb;
        c.GameKillApps = new List<string>(GameKillApps);
        c.ClearLogAfterGame = ClearLogAfterGame;
        return c;
    }
}

public static class ConfigStore
{
    public static string Dir
    {
        get { return Path.GetDirectoryName(Application.ExecutablePath); }
    }

    public static string ConfigPath
    {
        get { return Path.Combine(Dir, "cs2wd-40.config.json"); }
    }

    // 旧版本配置文件名（用于平滑迁移，避免老用户配置丢失）
    public static string LegacyConfigPath
    {
        get { return Path.Combine(Dir, "PW-CS2-Optimizer.config.json"); }
    }

    public static string LogPath
    {
        get { return Path.Combine(Dir, "cs2wd-40.log"); }
    }

    public static string LoadPath
    {
        get
        {
            if (File.Exists(ConfigPath)) return ConfigPath;
            if (File.Exists(LegacyConfigPath)) return LegacyConfigPath;
            return ConfigPath;
        }
    }

    public static AppConfig Load()
    {
        try
        {
            if (!File.Exists(LoadPath)) return new AppConfig();
            using (FileStream fs = new FileStream(LoadPath, FileMode.Open, FileAccess.Read))
            {
                DataContractJsonSerializer ser = new DataContractJsonSerializer(typeof(AppConfig));
                AppConfig c = (AppConfig)ser.ReadObject(fs);
                if (c == null) return new AppConfig();
                if (c.GameKillApps == null) c.GameKillApps = new List<string>();
                return c;
            }
        }
        catch { return new AppConfig(); }
    }

    public static bool Save(AppConfig c)
    {
        try
        {
            using (MemoryStream ms = new MemoryStream())
            {
                DataContractJsonSerializer ser = new DataContractJsonSerializer(typeof(AppConfig));
                ser.WriteObject(ms, c);
                string json = Encoding.UTF8.GetString(ms.ToArray());
                File.WriteAllText(ConfigPath, json, new UTF8Encoding(false));
            }
            return true;
        }
        catch { return false; }
    }
}

// ==================================================================
//  进程影响说明（关闭该进程的影响）
// ==================================================================
public enum ImpactLevel { Safe, Warn, Danger, Unknown }

public class Impact
{
    public ImpactLevel Level;
    public string Desc;
    public Impact(ImpactLevel l, string d) { Level = l; Desc = d; }
}

public static class ImpactDb
{
    static Dictionary<string, Impact> map = Build();

    static Dictionary<string, Impact> Build()
    {
        Dictionary<string, Impact> m = new Dictionary<string, Impact>();
        Action<string, ImpactLevel, string> add = delegate (string n, ImpactLevel l, string d) { m[n] = new Impact(l, d); };

        add("msedge", ImpactLevel.Safe, "Edge 浏览器");
        add("chrome", ImpactLevel.Safe, "Chrome 浏览器");
        add("firefox", ImpactLevel.Safe, "Firefox 浏览器");
        add("msedgewebview2", ImpactLevel.Safe, "网页内嵌组件");
        add("iexplore", ImpactLevel.Safe, "IE 浏览器");
        add("excel", ImpactLevel.Safe, "Excel（未保存内容会丢失）");
        add("winword", ImpactLevel.Safe, "Word（未保存内容会丢失）");
        add("powerpnt", ImpactLevel.Safe, "PowerPoint");
        add("onenote", ImpactLevel.Safe, "OneNote");
        add("outlook", ImpactLevel.Safe, "Outlook 邮件");
        add("qq", ImpactLevel.Safe, "QQ（关闭后需重新登录）");
        add("wechat", ImpactLevel.Safe, "微信（关闭后需重新登录）");
        add("weixin", ImpactLevel.Safe, "微信");
        add("discord", ImpactLevel.Safe, "Discord");
        add("tim", ImpactLevel.Safe, "TIM");
        add("onedrive", ImpactLevel.Safe, "OneDrive 同步（暂停同步）");
        add("baidunetdisk", ImpactLevel.Safe, "百度网盘");
        add("potplayer", ImpactLevel.Safe, "播放器");
        add("wmplayer", ImpactLevel.Safe, "媒体播放器");
        add("vlc", ImpactLevel.Safe, "VLC 播放器");
        add("mspcmanagerservice", ImpactLevel.Safe, "微软电脑管家服务");
        add("msofficeplusservice", ImpactLevel.Safe, "Office 增强服务");
        add("notepad", ImpactLevel.Safe, "记事本");
        add("calc", ImpactLevel.Safe, "计算器");

        add("trae", ImpactLevel.Warn, "当前 IDE，关闭会丢失未保存内容");
        add("code", ImpactLevel.Warn, "VS Code，关闭会丢失未保存内容");
        add("nvcontainer", ImpactLevel.Warn, "NVIDIA 驱动组件（覆盖层/录制可能失效）");
        add("nvsphelper64", ImpactLevel.Warn, "NVIDIA 组件");
        add("dwm", ImpactLevel.Warn, "桌面窗口管理器，关闭会导致桌面黑屏");
        add("explorer", ImpactLevel.Warn, "桌面/任务栏，关闭后任务栏消失");
        add("ctfmon", ImpactLevel.Warn, "输入法，关闭后无法切换输入法");
        add("steamwebhelper", ImpactLevel.Warn, "Steam 内嵌组件（商店/好友可能异常）");
        add("hipsdaemon", ImpactLevel.Warn, "火绒安全主防，关闭后失去实时防护");
        add("wsctrl", ImpactLevel.Warn, "火绒安全组件");
        add("spoolsv", ImpactLevel.Warn, "打印服务，关闭后无法打印");
        add("searchui", ImpactLevel.Warn, "Windows 搜索界面");
        add("searchindexer", ImpactLevel.Warn, "Windows 搜索索引（关闭后搜索变慢）");
        add("runtimebroker", ImpactLevel.Warn, "系统运行时组件");
        add("shellexperiencehost", ImpactLevel.Warn, "开始菜单/通知中心");

        add("audiodg", ImpactLevel.Danger, "Windows 音频引擎，关闭会没声音");
        add("steam", ImpactLevel.Danger, "Steam 客户端，CS2 依赖它运行");
        add("system", ImpactLevel.Danger, "系统进程，禁止关闭");
        add("svchost", ImpactLevel.Danger, "系统服务宿主，禁止关闭");
        add("lsass", ImpactLevel.Danger, "系统安全进程，禁止关闭");
        add("csrss", ImpactLevel.Danger, "系统进程，禁止关闭");
        add("winlogon", ImpactLevel.Danger, "系统进程，禁止关闭");
        add("wininit", ImpactLevel.Danger, "系统进程，禁止关闭");
        add("smss", ImpactLevel.Danger, "系统进程，禁止关闭");
        add("services", ImpactLevel.Danger, "服务控制管理器，禁止关闭");
        add("vgc", ImpactLevel.Danger, "Vanguard 反作弊，关闭会被游戏踢出");
        add("vgk", ImpactLevel.Danger, "Vanguard 内核反作弊");
        add("beservice", ImpactLevel.Danger, "BattlEye 反作弊");
        add("easyanticheat", ImpactLevel.Danger, "EasyAntiCheat 反作弊");
        add("perfectworldarena", ImpactLevel.Danger, "完美世界平台本体");
        add("conhost", ImpactLevel.Warn, "控制台宿主");
        return m;
    }

    public static Impact Get(string name)
    {
        if (string.IsNullOrEmpty(name)) return new Impact(ImpactLevel.Unknown, "未知进程");
        Impact i;
        if (map.TryGetValue(name.ToLower(), out i)) return i;
        return new Impact(ImpactLevel.Unknown, "未知进程，关闭前请确认");
    }

    public static string LevelText(ImpactLevel l)
    {
        switch (l)
        {
            case ImpactLevel.Safe: return "安全";
            case ImpactLevel.Warn: return "慎用";
            case ImpactLevel.Danger: return "禁止";
            default: return "未知";
        }
    }

    public static Color LevelColor(ImpactLevel l)
    {
        switch (l)
        {
            case ImpactLevel.Safe: return Color.FromArgb(30, 130, 60);
            case ImpactLevel.Warn: return Color.FromArgb(200, 120, 0);
            case ImpactLevel.Danger: return Color.FromArgb(190, 40, 40);
            default: return Color.Gray;
        }
    }
}

// ==================================================================
//  圆环仪表盘控件
// ==================================================================
public class ArcGauge : Control
{
    double _value;
    string _caption = "";
    string _sub = "";
    Color _ring = Color.FromArgb(70, 140, 220);

    // setter 必须 Invalidate，否则界面永不重绘
    public double Value { get { return _value; } set { _value = value; Invalidate(); } }
    public string Caption { get { return _caption; } set { _caption = value ?? ""; Invalidate(); } }
    public string SubText { get { return _sub; } set { _sub = value ?? ""; Invalidate(); } }
    public Color RingColor { get { return _ring; } set { _ring = value; Invalidate(); } }

    public ArcGauge()
    {
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        BackColor = Color.White;
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        Graphics g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.Clear(BackColor);

        int m = 18;
        int size = Math.Min(Width, Height) - m * 2;
        if (size <= 10) return;
        Rectangle rect = new Rectangle((Width - size) / 2, (Height - size) / 2, size, size);

        using (Pen bg = new Pen(Color.FromArgb(226, 230, 236), 13))
            g.DrawArc(bg, rect, -90, 360);

        double v = Value; if (v < 0) v = 0; if (v > 100) v = 100;
        float sweep = (float)(360.0 * v / 100.0);
        if (sweep > 0.5f)
        {
            using (Pen fg = new Pen(RingColor, 13))
            {
                fg.StartCap = LineCap.Round;
                fg.EndCap = LineCap.Round;
                g.DrawArc(fg, rect, -90, sweep);
            }
        }

        Font bigFont = new Font("Segoe UI", Math.Max(12, size / 8), FontStyle.Bold);
        Font capFont = new Font("Segoe UI", 8.5f);
        string pct = (Value >= 100 ? "100" : Value.ToString("0")) + "%";
        SizeF psz = g.MeasureString(pct, bigFont);
        using (SolidBrush br = new SolidBrush(Color.FromArgb(40, 45, 55)))
            g.DrawString(pct, bigFont, br, (Width - psz.Width) / 2, (Height - psz.Height) / 2 - 10);

        if (!string.IsNullOrEmpty(SubText))
        {
            SizeF ssz = g.MeasureString(SubText, capFont);
            using (SolidBrush br = new SolidBrush(Color.Gray))
                g.DrawString(SubText, capFont, br, (Width - ssz.Width) / 2, (Height) / 2 + psz.Height / 2 + 2);
        }
        if (!string.IsNullOrEmpty(Caption))
        {
            SizeF csz = g.MeasureString(Caption, capFont);
            using (SolidBrush br = new SolidBrush(Color.FromArgb(90, 95, 105)))
                g.DrawString(Caption, capFont, br, (Width - csz.Width) / 2, Height - m - 2);
        }
        bigFont.Dispose();
        capFont.Dispose();
    }
}

// ==================================================================
//  日志条目
// ==================================================================
public class LogEntry
{
    public char Tag;
    public string Text;
    public LogEntry(char t, string s) { Tag = t; Text = s; }
}

// ==================================================================
//  应用占用条目（内存 + CPU）
// ==================================================================
public class TopApp
{
    public string Name;
    public ulong MemMb;
    public double CpuPct;
    public string Kind;   // "游戏" / "平台" / 空
    public TopApp(string n, ulong m, double c, string k) { Name = n; MemMb = m; CpuPct = c; Kind = k; }
}

// ==================================================================
//  统计快照（后台线程 -> UI）
// ==================================================================
public class Snapshot
{
    public double CpuPct;
    public double GameCpu;
    public double PlatCpu;
    public uint MemLoad;
    public ulong MemTotalMb;
    public ulong MemAvailMb;
    public ulong GameMemMb;
    public ulong PlatMemMb;
    public int PlatTotal;
    public int PlatOk;
    public int PlatFail;
    public string GameState;
    public bool GameAlive;
    public List<TopApp> TopMem;
    public int TickCount;
}
