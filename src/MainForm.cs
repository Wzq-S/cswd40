// MainForm.cs  - 主界面 + 监控引擎
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Management;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

public class ProcState
{
    public bool Ok;
    public bool Notified;
    public bool FailLogged;
}

public class MainForm : Form
{
    // ---------- 配置/引擎 ----------
    AppConfig cfg = new AppConfig();
    Thread worker;
    volatile bool running;
    volatile bool reportPending;
    readonly object fileLock = new object();
    readonly ConcurrentQueue<LogEntry> logQ = new ConcurrentQueue<LogEntry>();
    Snapshot latest;

    // ---------- 进程识别 ----------
    string platExe = "";
    string gameName = "cs2";
    ulong platMask = 3;
    int platCoresActual = 2;
    ulong gameMask = 0xFFFC;
    uint gamePrio = Native.AboveNormalPriorityClass;
    bool supportEco = true;
    List<string> platRoots = new List<string>();
    readonly List<string> platNames = new List<string>(new string[] {
        "perfectworldarena","perfectworld","pwplatform","pwclient","pwautil64",
        "pwhelper","pwlauncher","pwupdate","dota2assist","pwahelper"
    });
    readonly List<string> steamNames = new List<string>(new string[] {
        "steam","steamwebhelper","steamservice","gameoverlayui","steamerrorreporter"
    });
    Dictionary<int, int> ppidMap = new Dictionary<int, int>();
    Dictionary<int, string> pathCache = new Dictionary<int, string>();
    Dictionary<int, string> kindCache = new Dictionary<int, string>();
    Dictionary<int, ProcState> stateMap = new Dictionary<int, ProcState>();
    Dictionary<int, double> prevCpu = new Dictionary<int, double>();
    DateTime prevCpuTime = DateTime.MinValue;
    ulong prevIdle, prevKernel, prevUser;

    // ---------- 统计 ----------
    int tickCount, okCount, warnCount, errCount;
    DateTime sessionStart = DateTime.Now;
    bool gameWasRunning;
    int emptyTicks;
    bool everSeen;

    // ---------- 空闲态实时采样 ----------
    DateTime lastIdleSample = DateTime.MinValue;
    Dictionary<int, double> prevAllCpu = new Dictionary<int, double>();
    DateTime prevAllTime = DateTime.MinValue;
    int selfPid = -1;

    // ---------- UI ----------
    ArcGauge gaugeCpu, gaugeMem;
    RichTextBox logBox;
    Label lblDetail, lblStats, lblStatus;
    Button btnStart, btnStop, btnConfig, btnLog;
    System.Windows.Forms.Timer uiTimer;

    public MainForm()
    {
        cfg = ConfigStore.Load();
        try { selfPid = Process.GetCurrentProcess().Id; } catch { selfPid = -1; }
        BuildUi();
        ApplyConfig();
        AppendLog('i', "cs2wd-40 v5.2 已就绪。点击「启动」自动拉起平台并开始优化。");
    }

    // ==============================================================
    //  创建界面
    // ==============================================================
    void BuildUi()
    {
        Text = "cs2wd-40";
        Size = new Size(860, 720);
        MinimumSize = new Size(780, 620);
        StartPosition = FormStartPosition.CenterScreen;
        BackColor = Color.FromArgb(246, 247, 250);
        Font = new Font("Microsoft YaHei UI", 9);
        // 统一图标：窗口左上角 + 任务栏 + Alt-Tab 均使用 exe 内嵌图标
        try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }

        // --- 顶部条 ---
        Panel top = new Panel();
        top.Dock = DockStyle.Top;
        top.Height = 58;
        top.BackColor = Color.FromArgb(28, 44, 72);
        Controls.Add(top);

        Label title = new Label();
        title.Text = "cs2wd-40";
        title.ForeColor = Color.White;
        title.Font = new Font("Microsoft YaHei UI", 13, FontStyle.Bold);
        title.AutoSize = false;
        title.Location = new Point(18, 15);
        title.Size = new Size(220, 28);
        top.Controls.Add(title);

        lblStatus = new Label();
        lblStatus.Text = "● 空闲";
        lblStatus.ForeColor = Color.FromArgb(180, 190, 205);
        lblStatus.Font = new Font("Microsoft YaHei UI", 9);
        lblStatus.AutoSize = false;
        lblStatus.TextAlign = ContentAlignment.MiddleRight;
        lblStatus.Location = new Point(top.Width - 220, 18);
        lblStatus.Size = new Size(200, 22);
        lblStatus.Anchor = AnchorStyles.Top | AnchorStyles.Right;
        top.Controls.Add(lblStatus);
        top.Resize += delegate { lblStatus.Left = top.Width - 214; };

        // --- 仪表盘区 ---
        Panel gauges = new Panel();
        gauges.Dock = DockStyle.Top;
        gauges.Height = 216;
        gauges.BackColor = Color.White;
        Controls.Add(gauges);
        gauges.Paint += delegate (object s, PaintEventArgs e)
        {
            using (Pen p = new Pen(Color.FromArgb(232, 235, 240)))
                e.Graphics.DrawLine(p, 0, gauges.Height - 1, gauges.Width, gauges.Height - 1);
        };

        gaugeCpu = new ArcGauge();
        gaugeCpu.Location = new Point(28, 10);
        gaugeCpu.Size = new Size(196, 196);
        gaugeCpu.Caption = "CPU 占用";
        gaugeCpu.RingColor = Color.FromArgb(70, 140, 220);
        gauges.Controls.Add(gaugeCpu);

        gaugeMem = new ArcGauge();
        gaugeMem.Location = new Point(236, 10);
        gaugeMem.Size = new Size(196, 196);
        gaugeMem.Caption = "内存占用";
        gaugeMem.RingColor = Color.FromArgb(120, 170, 90);
        gauges.Controls.Add(gaugeMem);

        lblDetail = new Label();
        lblDetail.Location = new Point(456, 24);
        lblDetail.Size = new Size(370, 176);
        lblDetail.Font = new Font("Microsoft YaHei UI", 9);
        lblDetail.ForeColor = Color.FromArgb(70, 76, 90);
        lblDetail.Text = "等待监控启动...";
        lblDetail.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right;
        gauges.Controls.Add(lblDetail);
        gauges.Resize += delegate { lblDetail.Width = gauges.Width - 466; };

        // --- 日志区 ---
        Panel logWrap = new Panel();
        logWrap.Dock = DockStyle.Fill;
        logWrap.Padding = new Padding(12, 10, 12, 0);
        logWrap.BackColor = Color.FromArgb(246, 247, 250);
        Controls.Add(logWrap);

        logBox = new RichTextBox();
        logBox.Dock = DockStyle.Fill;
        logBox.ReadOnly = true;
        logBox.BorderStyle = BorderStyle.FixedSingle;
        logBox.BackColor = Color.FromArgb(252, 252, 254);
        logBox.ForeColor = Color.FromArgb(80, 88, 100);
        logBox.Font = new Font("Consolas", 9.5f);
        logBox.HideSelection = false;
        logBox.WordWrap = false;
        logWrap.Controls.Add(logBox);

        // --- 底部条 ---
        Panel bottom = new Panel();
        bottom.Dock = DockStyle.Bottom;
        bottom.Height = 62;
        bottom.BackColor = Color.White;
        bottom.Paint += delegate (object s, PaintEventArgs e)
        {
            using (Pen p = new Pen(Color.FromArgb(232, 235, 240)))
                e.Graphics.DrawLine(p, 0, 0, bottom.Width, 0);
        };
        Controls.Add(bottom);

        lblStats = new Label();
        lblStats.Location = new Point(16, 20);
        lblStats.Size = new Size(470, 24);
        lblStats.Font = new Font("Microsoft YaHei UI", 9);
        lblStats.ForeColor = Color.FromArgb(70, 76, 90);
        lblStats.Text = "巡检 0 次  |  成功 0  |  失败 0  |  警告 0  |  错误 0";
        bottom.Controls.Add(lblStats);

        btnLog = MakeButton("📁 日志目录", 560, 15, 92, Color.FromArgb(240, 243, 248), Color.FromArgb(60, 70, 90));
        btnConfig = MakeButton("⚙ 配置", 660, 15, 82, Color.FromArgb(240, 243, 248), Color.FromArgb(60, 70, 90));
        btnStart = MakeButton("▶ 启动", 748, 15, 100, Color.FromArgb(46, 160, 90), Color.White);
        btnStop = MakeButton("■ 停止", 748, 15, 100, Color.FromArgb(200, 70, 70), Color.White);
        btnStart.Font = new Font("Microsoft YaHei UI", 9, FontStyle.Bold);
        btnStop.Font = new Font("Microsoft YaHei UI", 9, FontStyle.Bold);
        btnStop.Visible = false;

        foreach (Button b in new Button[] { btnLog, btnConfig, btnStart, btnStop })
        {
            b.Anchor = AnchorStyles.Top | AnchorStyles.Right;
            bottom.Controls.Add(b);
        }
        bottom.Resize += delegate
        {
            btnStart.Left = bottom.Width - 118;
            btnStop.Left = bottom.Width - 118;
            btnConfig.Left = bottom.Width - 208;
            btnLog.Left = bottom.Width - 308;
        };

        btnStart.Click += delegate { StartMonitor(); };
        btnStop.Click += delegate { StopMonitor(false); };
        btnConfig.Click += delegate { OpenConfig(); };
        btnLog.Click += delegate
        {
            try { Process.Start("explorer.exe", "/select,\"" + ConfigStore.LogPath + "\""); }
            catch { }
        };

        // 修正停靠顺序（WinForms 索引大的先停靠）：
        // top 顶边 → bottom 底边 → gauges 顶边 → logWrap 填充中部。
        // 否则 logWrap 会先填满整个窗口，日志文本被仪表盘面板盖住。
        Controls.SetChildIndex(logWrap, 0);
        Controls.SetChildIndex(gauges, 1);
        Controls.SetChildIndex(bottom, 2);
        Controls.SetChildIndex(top, 3);

        uiTimer = new System.Windows.Forms.Timer();
        uiTimer.Interval = 200;
        uiTimer.Tick += delegate { FlushUi(); };
        uiTimer.Start();
    }

    Button MakeButton(string text, int x, int y, int w, Color back, Color fore)
    {
        Button b = new Button();
        b.Text = text;
        b.Location = new Point(x, y);
        b.Size = new Size(w, 32);
        b.FlatStyle = FlatStyle.Flat;
        b.FlatAppearance.BorderColor = back == Color.White ? Color.Silver : back;
        b.BackColor = back;
        b.ForeColor = fore;
        b.Cursor = Cursors.Hand;
        return b;
    }

    // ==============================================================
    //  应用配置
    // ==============================================================
    void ApplyConfig()
    {
        cfg = ConfigStore.Load();
        if (cfg.IntervalMs < 500) cfg.IntervalMs = 1000;
        if (cfg.PlatCoresCount < 1) cfg.PlatCoresCount = 2;
        gameName = (cfg.GameProcessName ?? "cs2").ToLower().Trim();

        int cores = Environment.ProcessorCount;
        int pc = cfg.PlatCoresCount;
        if (pc < 1) pc = 1;
        if (cores <= 4) pc = Math.Min(pc, Math.Max(1, cores - 2));
        if (pc > cores / 2) pc = Math.Max(1, cores / 2);
        if (pc > 8) pc = 8;
        platCoresActual = pc;
        platMask = (1UL << pc) - 1UL;
        ulong full = cores >= 64 ? ulong.MaxValue : ((1UL << cores) - 1UL);

        string aff = (cfg.Cs2Affinity ?? "Exclude01");
        if (aff == "All") gameMask = full;
        else if (aff == "Custom")
        {
            ulong cm = 0;
            try { cm = Convert.ToUInt64((cfg.CustomMask ?? "").Trim(), 16); } catch { cm = 0; }
            if (cm == 0) cm = full & ~platMask;
            gameMask = cm;
        }
        else gameMask = full & ~platMask;

        if (gameMask == 0) gameMask = full;

        switch ((cfg.Cs2Priority ?? "AboveNormal"))
        {
            case "High": gamePrio = Native.HighPriorityClass; break;
            case "Normal": gamePrio = Native.NormalPriorityClass; break;
            default: gamePrio = Native.AboveNormalPriorityClass; break;
        }

        Version v = Environment.OSVersion.Version;
        supportEco = v.Build >= 19041;

        pc = Math.Min(pc, cores / 2);
        if (pc < 1) pc = 1;

        platExe = ResolvePlatformPath(cfg.PlatformPath);
        platRoots = new List<string>();
        if (!string.IsNullOrEmpty(platExe) && File.Exists(platExe))
        {
            string dir = Path.GetDirectoryName(platExe);
            if (!dir.EndsWith("\\")) dir += "\\";
            platRoots.Add(dir);
            try
            {
                string parent = Path.GetDirectoryName(dir.TrimEnd('\\'));
                string leaf = Path.GetFileName(parent) ?? "";
                if (leaf.ToLower().Contains("完美") || leaf.ToLower().Contains("perfect") || leaf.ToLower().Contains("wmpvp"))
                {
                    if (!parent.EndsWith("\\")) parent += "\\";
                    platRoots.Add(parent);
                }
            }
            catch { }
        }
        lblDetail.Text = BuildReadyText();
    }

    string BuildReadyText()
    {
        StringBuilder sb = new StringBuilder();
        sb.AppendLine("平台位置：" + (string.IsNullOrEmpty(platExe) ? "❌ 未配置" : Path.GetFileName(platExe)));
        sb.AppendLine("平台绑定：CPU0 - CPU" + (platCoresActual - 1) + "（效率模式 / BelowNormal / 内存Low）");
        sb.AppendLine("游戏过程：" + gameName + " → " + MaskText(gameMask) + "  优先级 " + PrioText(gamePrio));
        sb.AppendLine("巡检间隔：" + (cfg.IntervalMs < 1000 ? 1000 : cfg.IntervalMs) + " ms（游戏中自动 1000 ms）");
        sb.AppendLine("游戏时关闭：" + (cfg.GameKillApps != null && cfg.GameKillApps.Count > 0 ? string.Join(", ", cfg.GameKillApps.ToArray()) : "（未设置）"));
        sb.Append("系统：" + Environment.OSVersion.VersionString + "  ·  " + Environment.ProcessorCount + " 逻辑核心  ·  " + (supportEco ? "支持效率模式" : "不支持效率模式"));
        return sb.ToString();
    }

    string MaskText(ulong mask)
    {
        List<int> cpus = new List<int>();
        for (int i = 0; i < 64; i++) if ((mask & (1UL << i)) != 0) cpus.Add(i);
        if (cpus.Count == 0) return "无";
        if (cpus.Count == 1) return "CPU" + cpus[0];
        bool continuous = true;
        for (int i = 1; i < cpus.Count; i++) if (cpus[i] != cpus[0] + i) { continuous = false; break; }
        if (continuous) return "CPU" + cpus[0] + "-CPU" + cpus[cpus.Count - 1];
        return string.Join(",", cpus.Select(i => "CPU" + i).ToArray());
    }

    string PrioText(uint p)
    {
        if (p == Native.HighPriorityClass) return "High";
        if (p == Native.AboveNormalPriorityClass) return "AboveNormal";
        if (p == Native.NormalPriorityClass) return "Normal";
        if (p == Native.BelowNormalPriorityClass) return "BelowNormal";
        return "Normal";
    }

    internal static string ResolvePlatformPath(string configured)
    {
        if (!string.IsNullOrEmpty(configured) && File.Exists(configured)) return configured;
        string[] rootKeys = new string[] {
            @"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
            @"SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
            @"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
        };
        try
        {
            foreach (string rk in rootKeys)
            {
                using (RegistryKey rk2 = Registry.LocalMachine.OpenSubKey(rk))
                {
                    if (rk2 == null) continue;
                    foreach (string sk in rk2.GetSubKeyNames())
                    {
                        using (RegistryKey k = rk2.OpenSubKey(sk))
                        {
                            if (k == null) continue;
                            string icon = k.GetValue("DisplayIcon") as string;
                            if (string.IsNullOrEmpty(icon)) continue;
                            if (!icon.ToLower().Contains("perfectworldarena")) continue;
                            string exe = icon.Split(',')[0].Trim();
                            if (File.Exists(exe)) return exe;
                        }
                    }
                }
            }
        }
        catch { }

        try
        {
            string[] dirs = new string[] {
                Environment.GetFolderPath(Environment.SpecialFolder.Desktop),
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads"),
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData)
            };
            foreach (string d in dirs)
            {
                if (string.IsNullOrEmpty(d) || !Directory.Exists(d)) continue;
                foreach (string sub in Directory.GetDirectories(d, "*perfectworldarena*", SearchOption.AllDirectories))
                {
                    string[] exes = Directory.GetFiles(sub, "*.exe");
                    string best = "";
                    long bestSize = -1;
                    foreach (string ex in exes)
                    {
                        string nm = Path.GetFileName(ex).ToLower();
                        if (nm.StartsWith("uninst")) continue;
                        try
                        {
                            long len = new FileInfo(ex).Length;
                            if (len > bestSize) { bestSize = len; best = ex; }
                        }
                        catch { }
                    }
                    if (!string.IsNullOrEmpty(best)) return best;
                }
            }
        }
        catch { }
        return configured ?? "";
    }

    // ==============================================================
    //  启动 / 停止
    // ==============================================================
    void StartMonitor()
    {
        if (running) return;
        ApplyConfig();
        if (string.IsNullOrEmpty(platExe) || !File.Exists(platExe))
        {
            MessageBox.Show("还没有配置平台路径。请先点击「配置」选择完美世界竞技平台的 exe。",
                "缺少配置", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            OpenConfig();
            return;
        }

        Native.EnablePrivilege("SeDebugPrivilege");
        Native.EnablePrivilege("SeIncreaseBasePriorityPrivilege");

        // 重置运行态
        stateMap.Clear(); pathCache.Clear(); kindCache.Clear(); ppidMap.Clear();
        prevCpu.Clear(); prevCpuTime = DateTime.MinValue;
        prevIdle = prevKernel = prevUser = 0;
        tickCount = okCount = warnCount = errCount = 0;
        gameWasRunning = false; emptyTicks = 0; everSeen = false;
        sessionStart = DateTime.Now;
        reportPending = false;

        ClearLogFile();
        running = true;
        btnStart.Visible = false;
        btnStop.Visible = true;
        SetStatus("● 监控中", Color.FromArgb(120, 220, 150));

        AppendLog('i', "===== 新的监控会话开始 =====");

        // 自动拉起平台（监控是附带动作，用户只需点一次「启动」）
        if (cfg.AutoLaunchPlatform)
        {
            if (IsPlatformRunning())
            {
                Log('i', "检测到完美世界竞技平台已在运行，直接开始优化。");
            }
            else
            {
                Log('i', "正在启动完美世界竞技平台...");
                try
                {
                    // 本程序是管理员权限，直接 Process.Start 会让平台/CS2 也变成高权限，
                    // 可能引起反作弊或安全软件异常。交给 explorer 以普通用户身份拉起。
                    Process.Start("explorer.exe", "\"" + platExe + "\"");
                    Log('+', "完美世界竞技平台已启动。");
                }
                catch (Exception ex)
                {
                    Log('x', "平台启动失败：" + ex.Message + "（可手动启动，监控会继续）");
                }
            }
        }
        Log('i', "开始监控（关闭本窗口即结束）");

        ThreadStart ts = new ThreadStart(WorkerLoop);
        worker = new Thread(ts);
        worker.IsBackground = true;
        worker.Start();
    }

    bool IsPlatformRunning()
    {
        // 注意：不能用 TestPlatName 判平台，它把 "pw" 开头的进程都算平台，
        // 而优化器自己就叫 PW-CS2-Optimizer，会造成"永远认为平台在运行"。
        Process[] procs = Process.GetProcesses();
        int selfId = selfPid;
        foreach (Process p in procs)
        {
            try
            {
                if (p.Id == selfId) continue;
                if (p.Threads.Count == 0) continue;
                string path = "";
                try { path = p.MainModule.FileName; } catch { }
                if (TestPlatPath(path)) return true;
                string n = p.ProcessName.ToLower();
                if (n.Contains("完美世界") || n.Contains("perfectworld")) return true;
                if (platNames.Contains(n)) return true;
            }
            catch { }
            finally { try { p.Dispose(); } catch { } }
        }
        return false;
    }

    void StopMonitor(bool auto)
    {
        if (!running) return;
        running = false;
        if (worker != null)
        {
            try { worker.Join(1500); } catch { }
            worker = null;
        }
        btnStart.Visible = true;
        btnStop.Visible = false;
        SetStatus("● 已停止", Color.FromArgb(230, 170, 90));
        AppendLog('i', auto ? "监控已自动停止。" : "监控已手动停止。");
        if (auto) reportPending = true;
    }

    void SetStatus(string text, Color c)
    {
        lblStatus.Text = text;
        lblStatus.ForeColor = c;
    }

    // ==============================================================
    //  后台巡检
    // ==============================================================
    void WorkerLoop()
    {
        DateTime lastPpid = DateTime.MinValue;
        while (running)
        {
            DateTime t0 = DateTime.Now;
            try
            {
                if ((DateTime.Now - lastPpid).TotalSeconds > 15) { UpdatePpidMap(); lastPpid = DateTime.Now; }
                Tick();
            }
            catch { }

            int sleep = cfg.IntervalMs;
            if (sleep < 500) sleep = 1000;
            if (latest != null && latest.GameAlive && sleep > 1000) sleep = 1000;

            int elapsed = (int)(DateTime.Now - t0).TotalMilliseconds;
            int wait = sleep - elapsed;
            if (wait < 100) wait = 100;
            if (elapsed > sleep + 1200)
            {
                Log('!', string.Format("系统响应变慢：本次巡检耗时 {0} ms（正常约 {1} ms），可能发生磁盘/内存/驱动级卡顿", elapsed, sleep));
            }
            Thread.Sleep(wait);
        }
    }

    void UpdatePpidMap()
    {
        Dictionary<int, int> map = new Dictionary<int, int>();
        try
        {
            using (ManagementObjectSearcher s = new ManagementObjectSearcher("SELECT ProcessId, ParentProcessId FROM Win32_Process"))
            using (ManagementObjectCollection col = s.Get())
            {
                foreach (ManagementObject o in col)
                {
                    try
                    {
                        int pid = Convert.ToInt32(o["ProcessId"]);
                        int ppid = Convert.ToInt32(o["ParentProcessId"]);
                        map[pid] = ppid;
                    }
                    catch { }
                    o.Dispose();
                }
            }
        }
        catch { }
        ppidMap = map;
    }

    bool TestPlatName(string name)
    {
        if (string.IsNullOrEmpty(name)) return false;
        string n = name.ToLower();
        if (steamNames.Contains(n)) return false;
        if (n.StartsWith("pw")) return true;
        if (n.StartsWith("pwa")) return true;
        return platNames.Contains(n);
    }

    bool TestPlatPath(string path)
    {
        if (string.IsNullOrEmpty(path)) return false;
        foreach (string r in platRoots)
            if (path.StartsWith(r, StringComparison.OrdinalIgnoreCase)) return true;
        return false;
    }

    bool TestPlatByParent(int pid)
    {
        int p = pid;
        for (int depth = 0; depth < 10; depth++)
        {
            int pp;
            if (!ppidMap.TryGetValue(p, out pp)) return false;
            if (pp <= 0 || pp == p) return false;
            string cached;
            if (kindCache.TryGetValue(pp, out cached))
            {
                if (cached == "plat") return true;
                if (cached == "game") return false;
            }
            string pname = "";
            try { using (Process pr = Process.GetProcessById(pp)) pname = pr.ProcessName; } catch { return false; }
            if (TestPlatName(pname)) return true;
            p = pp;
        }
        return false;
    }

    void Tick()
    {
        tickCount++;
        Dictionary<int, double> curCpu = new Dictionary<int, double>();
        Dictionary<int, ulong> curMem = new Dictionary<int, ulong>();
        Dictionary<int, string> curNames = new Dictionary<int, string>();
        HashSet<int> seen = new HashSet<int>();
        HashSet<int> platIds = new HashSet<int>();
        HashSet<int> gameIds = new HashSet<int>();

        int platTotal = 0, platOk = 0, platFail = 0;
        bool gameAlive = false;
        List<string> failNames = new List<string>();

        Process[] procs = Process.GetProcesses();
        foreach (Process p in procs)
        {
            int pid = 0;
            string pname = "";
            try { pid = p.Id; pname = p.ProcessName; } catch { continue; }
            if (pid == selfPid) { try { p.Dispose(); } catch { } continue; }   // 不优化自己
            seen.Add(pid);

            string path;
            if (!pathCache.TryGetValue(pid, out path))
            {
                path = "";
                try { path = p.MainModule.FileName; } catch { path = ""; }
                if (path == null) path = "";
                pathCache[pid] = path;
            }

            double cpuSec = 0;
            try { cpuSec = p.TotalProcessorTime.TotalSeconds; } catch { cpuSec = prevCpu.ContainsKey(pid) ? prevCpu[pid] : 0; }
            ulong ws = 0;
            try { ws = (ulong)(p.WorkingSet64 / 1048576L); } catch { ws = 0; if (curMem.ContainsKey(pid)) ws = curMem[pid]; }

            curCpu[pid] = cpuSec;
            curMem[pid] = ws;
            curNames[pid] = pname;

            string kind;
            if (!kindCache.TryGetValue(pid, out kind) || kind == null)
            {
                if (pname.ToLower() == gameName) kind = "game";
                else if (TestPlatPath(path) || TestPlatName(pname) || TestPlatByParent(pid)) kind = "plat";
                else kind = "";
                kindCache[pid] = kind;
            }
            if (kind == "") { try { p.Dispose(); } catch { } continue; }
            if (IsZombie(p)) { try { p.Dispose(); } catch { } continue; }

            if (kind == "game") { gameIds.Add(pid); gameAlive = true; }
            else platIds.Add(pid);

            ProcState rec;
            if (!stateMap.TryGetValue(pid, out rec))
            {
                rec = new ProcState();
                stateMap[pid] = rec;
            }

            TuneResult res;
            bool okNow;
            string maskDesc;
            if (kind == "game")
            {
                res = ProcTuner.ApplyGame(pid, gameMask, gamePrio);
                okNow = res.Ok;
                maskDesc = MaskText(gameMask) + " · " + PrioText(gamePrio);
                if (!okNow) { platFail++; failNames.Add(pname + "(PID " + pid + ")"); }
            }
            else
            {
                res = ProcTuner.ApplyPlatform(pid, platMask, supportEco);
                okNow = res.Ok;
                maskDesc = "CPU0-CPU" + (platCoresActual - 1);
                platTotal++;
                if (okNow) platOk++;
                else { platFail++; failNames.Add(pname + "(PID " + pid + ")"); }
            }

            if (!rec.Notified)
            {
                rec.Notified = true;
                if (okNow)
                {
                    Interlocked.Increment(ref okCount);
                    Log('+', string.Format("新进程 {0} (PID {1}) → {2}", PrettyName(pname), pid, maskDesc));
                }
            }
            if (rec.Ok && !okNow)
            {
                List<string> drift = new List<string>();
                if (!res.EcoOn && supportEco) drift.Add("效率模式");
                if (!res.AffinityOk) drift.Add("相关性");
                if (!res.PriorityOk) drift.Add("优先级");
                Log('!', string.Format("{0} (PID {1}) {2}被重置，已重新锁定", PrettyName(pname), pid, string.Join("/", drift.ToArray())));
                rec.FailLogged = false;
            }
            if (!okNow && !rec.FailLogged)
            {
                string what = (!res.EcoOn && supportEco) ? "效率模式" : (res.AffinityOk ? "优先级" : "相关性");
                Log('x', string.Format("{0} (PID {1}) {2}设置失败：{3}", PrettyName(pname), pid, what, ErrText.Get(res.Error)));
                rec.FailLogged = true;
            }
            rec.Ok = okNow;

            try { p.Dispose(); } catch { }
        }

        // 清理已退出进程的缓存
        List<int> gone = new List<int>();
        foreach (KeyValuePair<int, ProcState> kv in stateMap) if (!seen.Contains(kv.Key)) gone.Add(kv.Key);
        foreach (int k in gone) stateMap.Remove(k);
        gone.Clear();
        foreach (KeyValuePair<int, string> kv in pathCache) if (!seen.Contains(kv.Key)) gone.Add(kv.Key);
        foreach (int k in gone) pathCache.Remove(k);
        gone.Clear();
        foreach (KeyValuePair<int, string> kv in kindCache) if (!seen.Contains(kv.Key)) gone.Add(kv.Key);
        foreach (int k in gone) kindCache.Remove(k);

        // 游戏启动 → 关闭指定应用
        if (gameAlive && !gameWasRunning)
        {
            gameWasRunning = true;
            KillConfiguredApps();
        }
        else if (!gameAlive) gameWasRunning = false;

        // CPU 采样（含全应用按名聚合）
        double sysCpu = 0, gameCpu = 0, platCpu = 0;
        ulong gameMem = 0, platMem = 0;
        Dictionary<string, double> cpuByName = new Dictionary<string, double>();

        DateTime now = DateTime.Now;
        if (prevCpuTime != DateTime.MinValue)
        {
            double secs = (now - prevCpuTime).TotalSeconds * Environment.ProcessorCount;
            if (secs > 0)
            {
                foreach (KeyValuePair<int, double> kv in curCpu)
                {
                    double old;
                    if (!prevCpu.TryGetValue(kv.Key, out old)) continue;
                    double pct = 100.0 * (kv.Value - old) / secs;
                    if (pct < 0) pct = 0;
                    if (gameIds.Contains(kv.Key)) gameCpu += pct;
                    else if (platIds.Contains(kv.Key)) platCpu += pct;
                    string nm = curNames.ContainsKey(kv.Key) ? curNames[kv.Key] : "?";
                    double agg;
                    if (cpuByName.TryGetValue(nm, out agg)) cpuByName[nm] = agg + pct;
                    else cpuByName[nm] = pct;
                }
                gameCpu = Math.Round(gameCpu, 1);
                platCpu = Math.Round(platCpu, 1);
            }
        }
        sysCpu = GetSystemCpu();

        foreach (int id in gameIds) { ulong m; if (curMem.TryGetValue(id, out m)) gameMem += m; }
        foreach (int id in platIds) { ulong m; if (curMem.TryGetValue(id, out m)) platMem += m; }

        Dictionary<string, ulong> memByName = new Dictionary<string, ulong>();
        foreach (KeyValuePair<int, ulong> kv in curMem)
        {
            if (kv.Value < 20UL) continue;
            string nm = curNames.ContainsKey(kv.Key) ? curNames[kv.Key] : "?";
            ulong cur;
            if (memByName.TryGetValue(nm, out cur)) memByName[nm] = cur + kv.Value;
            else memByName[nm] = kv.Value;
        }

        // 平台进程名集合（按路径/父进程识别出来的，比关键字更可靠）
        HashSet<string> platNameSet = new HashSet<string>();
        foreach (int id in platIds)
        {
            string nm;
            if (curNames.TryGetValue(id, out nm)) platNameSet.Add(nm);
        }
        List<TopApp> topMem = BuildTopRows(memByName, cpuByName, platNameSet, 6);

        ulong totalMb, availMb; uint load;
        Native.MemInfo(out totalMb, out availMb, out load);

        Snapshot snap = new Snapshot();
        snap.CpuPct = sysCpu;
        snap.GameCpu = gameCpu;
        snap.PlatCpu = platCpu;
        snap.MemLoad = load;
        snap.MemTotalMb = totalMb;
        snap.MemAvailMb = availMb;
        snap.GameMemMb = gameMem;
        snap.PlatMemMb = platMem;
        snap.PlatTotal = platTotal;
        snap.PlatOk = platOk;
        snap.PlatFail = platFail;
        snap.GameAlive = gameAlive;
        snap.GameState = gameAlive ? "运行中" : "未运行";
        snap.TopMem = topMem;
        snap.TickCount = tickCount;
        latest = snap;

        prevCpu = curCpu;
        prevCpuTime = now;

        // 状态行
        if (tickCount % 10 == 0)
        {
            Log('i', string.Format("第 {0} 次巡检 | 平台进程 {1} 个（正常 {2} / 失败 {3}）| {4}：{5}",
                tickCount, platTotal, platOk, platFail, gameName, snap.GameState));
            if (failNames.Count > 0) Log('!', "设置未生效：" + string.Join(", ", failNames.ToArray()));
        }

        // 全部退出 → 自动停止
        if (platTotal > 0 || gameAlive)
        {
            everSeen = true; emptyTicks = 0;
        }
        else if (everSeen)
        {
            emptyTicks++;
            if (emptyTicks >= 4)
            {
                running = false;
                BeginInvoke(new Action(delegate { StopMonitor(false); reportPending = true; }));
            }
        }
    }

    bool IsZombie(Process p)
    {
        try { return p.Threads.Count == 0; } catch { return false; }
    }

    double GetSystemCpu()
    {
        ulong idle, kernel, user;
        if (!Native.GetSystemTimes(out idle, out kernel, out user)) return 0;
        if (prevIdle == 0 && prevKernel == 0) { prevIdle = idle; prevKernel = kernel; prevUser = user; return 0; }
        ulong dIdle = idle - prevIdle;
        ulong dKernel = kernel - prevKernel;
        ulong dUser = user - prevUser;
        prevIdle = idle; prevKernel = kernel; prevUser = user;
        ulong total = dKernel + dUser;
        if (total == 0) return 0;
        double used = 100.0 * (total - dIdle) / total;
        if (used < 0) used = 0; if (used > 100) used = 100;
        return Math.Round(used, 1);
    }

    string PrettyName(string pname)
    {
        if (pname.ToLower() == gameName) return gameName.ToUpper();
        if (TestPlatName(pname)) return "完美世界竞技平台";
        return pname;
    }

    void KillConfiguredApps()
    {
        if (cfg.GameKillApps == null || cfg.GameKillApps.Count == 0) return;
        foreach (string raw in cfg.GameKillApps)
        {
            if (string.IsNullOrEmpty(raw)) continue;
            string name = raw.Trim();
            if (name.ToLower() == gameName) continue;
            try
            {
                Process[] hits = Process.GetProcessesByName(name);
                foreach (Process h in hits)
                {
                    try
                    {
                        int id = h.Id;
                        h.Kill();
                        Log('i', string.Format("游戏开始，已关闭后台应用：{0} (PID {1})", name, id));
                    }
                    catch { }
                    finally { try { h.Dispose(); } catch { } }
                }
            }
            catch { }
        }
    }

    // ==============================================================
    //  日志 / UI 刷新
    // ==============================================================
    void AppendLog(char tag, string msg)
    {
        string line = "[" + DateTime.Now.ToString("MM-dd HH:mm:ss") + "] " + tag + " " + msg;
        logQ.Enqueue(new LogEntry(tag, line));
    }

    void Log(char tag, string msg)
    {
        AppendLog(tag, msg);

        if (tag == '+') Interlocked.Increment(ref okCount);
        else if (tag == '!') Interlocked.Increment(ref warnCount);
        else if (tag == 'x') Interlocked.Increment(ref errCount);

        lock (fileLock)
        {
            try
            {
                if (cfg.LogMaxMb > 0 && File.Exists(ConfigStore.LogPath))
                {
                    FileInfo fi = new FileInfo(ConfigStore.LogPath);
                    if (fi.Length > (long)cfg.LogMaxMb * 1024L * 1024L)
                    {
                        string bak = ConfigStore.LogPath + ".bak";
                        if (File.Exists(bak)) File.Delete(bak);
                        File.Move(ConfigStore.LogPath, bak);
                    }
                }
                File.AppendAllText(ConfigStore.LogPath, "[" + DateTime.Now.ToString("MM-dd HH:mm:ss") + "] " + tag + " " + msg + Environment.NewLine, new UTF8Encoding(false));
            }
            catch { }
        }
    }

    void ClearLogFile()
    {
        lock (fileLock)
        {
            try { File.WriteAllText(ConfigStore.LogPath, "", new UTF8Encoding(false)); }
            catch { }
        }
    }

    void FlushUi()
    {
        // 日志
        LogEntry ent;
        int drained = 0;
        while (logQ.TryDequeue(out ent) && drained < 200)
        {
            drained++;
            Color c;
            switch (ent.Tag)
            {
                case '+': c = Color.FromArgb(30, 140, 70); break;
                case '!': c = Color.FromArgb(200, 120, 0); break;
                case 'x': c = Color.FromArgb(200, 50, 50); break;
                default: c = Color.FromArgb(95, 104, 120); break;
            }
            AppendRich(ent.Text, c);
        }
        if (drained > 0) TrimLog();

        // 仪表盘：监控中走快照；空闲时走实时系统采样（窗口一打开就有数据）
        if (running)
        {
            Snapshot s = latest;
            if (s != null)
            {
                gaugeCpu.Value = s.CpuPct;
                gaugeCpu.SubText = "全系统实时";
                gaugeMem.Value = s.MemLoad;
                gaugeMem.SubText = "可用 " + s.MemAvailMb + " / " + s.MemTotalMb + " MB";

                StringBuilder sb = new StringBuilder();
                sb.AppendLine("平台进程 " + s.PlatTotal + " 个（正常 " + s.PlatOk + " / 失败 " + s.PlatFail +
                    "）   " + gameName.ToUpper() + "：" + s.GameState);
                sb.Append(FormatTopRows(s.TopMem, "应用占用 Top（含游戏 / 平台）"));
                lblDetail.Text = sb.ToString();

                lblStats.Text = string.Format("巡检 {0} 次  |  成功 {1}  |  警告 {2}  |  错误 {3}  |  已运行 {4}",
                    s.TickCount, okCount, warnCount, errCount, ElapsedText());
            }
        }
        else if ((DateTime.Now - lastIdleSample).TotalMilliseconds >= 1000)
        {
            lastIdleSample = DateTime.Now;
            SampleIdle();
        }

        if (reportPending)
        {
            reportPending = false;
            ShowGameReport();
        }
    }

    string ElapsedText()
    {
        TimeSpan ts = DateTime.Now - sessionStart;
        return string.Format("{0:00}:{1:00}:{2:00}", (int)ts.TotalHours, ts.Minutes, ts.Seconds);
    }

    // ==============================================================
    //  空闲态实时采样：窗口一打开就显示全系统 CPU/内存与全应用占用
    // ==============================================================
    void SampleIdle()
    {
        double cpu = GetSystemCpu();
        ulong totalMb, availMb; uint load;
        Native.MemInfo(out totalMb, out availMb, out load);

        gaugeCpu.Value = cpu;
        gaugeCpu.SubText = "全系统实时";
        gaugeMem.Value = load;
        gaugeMem.SubText = "可用 " + availMb + " / " + totalMb + " MB";

        Process[] procs = Process.GetProcesses();
        Dictionary<string, ulong> memByName = new Dictionary<string, ulong>();
        Dictionary<string, double> cpuByName = new Dictionary<string, double>();
        Dictionary<int, double> curAll = new Dictionary<int, double>();
        DateTime now = DateTime.Now;
        double secs = prevAllTime == DateTime.MinValue ? 0 :
            (now - prevAllTime).TotalSeconds * Environment.ProcessorCount;

        foreach (Process p in procs)
        {
            string nm; ulong ws; double cs;
            try
            {
                if (p.Id == selfPid) { p.Dispose(); continue; }
                nm = p.ProcessName;
                ws = (ulong)(p.WorkingSet64 / 1048576L);
                cs = p.TotalProcessorTime.TotalSeconds;
            }
            catch { try { p.Dispose(); } catch { } continue; }
            curAll[p.Id] = cs;
            if (ws >= 20)
            {
                ulong agg;
                if (memByName.TryGetValue(nm, out agg)) memByName[nm] = agg + ws;
                else memByName[nm] = ws;
            }
            if (secs > 0)
            {
                double old;
                if (prevAllCpu.TryGetValue(p.Id, out old))
                {
                    double pct = 100.0 * (cs - old) / secs;
                    if (pct > 0)
                    {
                        double agg2;
                        if (cpuByName.TryGetValue(nm, out agg2)) cpuByName[nm] = agg2 + pct;
                        else cpuByName[nm] = pct;
                    }
                }
            }
            try { p.Dispose(); } catch { }
        }
        prevAllCpu = curAll;
        prevAllTime = now;

        List<TopApp> top = BuildTopRows(memByName, cpuByName, null, 6);

        StringBuilder sb = new StringBuilder();
        sb.AppendLine("全系统 CPU " + cpu.ToString("0.0") + "%   内存 " + load + "%（可用 " + availMb +
            " / " + totalMb + " MB）");
        sb.Append(FormatTopRows(top, "应用占用 Top（含游戏 / 平台）"));
        lblDetail.Text = sb.ToString();

        lblStats.Text = "待机中 — 点击「启动」自动拉起平台并开始优化";
    }

    // ==============================================================
    //  占用列表构建：按内存排序，并强制保证「游戏」「平台」可见
    // ==============================================================
    string KindOf(string name, HashSet<string> platNamesSet)
    {
        string n = name.ToLower();
        if (n == gameName) return "游戏";
        if (platNamesSet != null && platNamesSet.Contains(name)) return "平台";
        if (n.Contains("完美世界") || n.Contains("perfectworld")) return "平台";
        return "";
    }

    List<TopApp> BuildTopRows(Dictionary<string, ulong> mem, Dictionary<string, double> cpu,
        HashSet<string> platNamesSet, int max)
    {
        List<TopApp> all = new List<TopApp>();
        foreach (KeyValuePair<string, ulong> kv in mem)
        {
            double c = cpu.ContainsKey(kv.Key) ? Math.Round(cpu[kv.Key], 1) : 0;
            all.Add(new TopApp(kv.Key, kv.Value, c, KindOf(kv.Key, platNamesSet)));
        }
        // 内存为主排序，CPU 高但内存小的也往上提一点，避免"占 CPU 不吃内存"的应用被埋没
        all.Sort(delegate (TopApp a, TopApp b)
        {
            double sa = a.MemMb + a.CpuPct * 30;
            double sb = b.MemMb + b.CpuPct * 30;
            return sb.CompareTo(sa);
        });

        List<TopApp> rows = new List<TopApp>();
        for (int i = 0; i < all.Count && i < max; i++) rows.Add(all[i]);

        foreach (string kind in new string[] { "游戏", "平台" })
        {
            bool exist = false;
            foreach (TopApp r in rows) if (r.Kind == kind) { exist = true; break; }
            if (exist) continue;
            TopApp best = null;
            foreach (TopApp a in all) if (a.Kind == kind) { best = a; break; }
            if (best == null) continue;
            if (rows.Count >= max) rows.RemoveAt(rows.Count - 1);
            rows.Add(best);
        }
        return rows;
    }

    string FormatTopRows(List<TopApp> rows, string header)
    {
        StringBuilder sb = new StringBuilder();
        sb.AppendLine(header);
        if (rows.Count == 0) { sb.AppendLine("  （暂无）"); return sb.ToString(); }
        int i = 1;
        foreach (TopApp t in rows)
        {
            string tag = t.Kind.Length == 0 ? "      " : "[" + t.Kind + "]";
            sb.AppendLine(string.Format("  {0}. {1} {2,-16} {3,5} MB  CPU {4,4:0.0}%",
                i++, tag, t.Name, t.MemMb, t.CpuPct));
        }
        return sb.ToString();
    }

    void AppendRich(string text, Color c)
    {
        logBox.SelectionStart = logBox.TextLength;
        logBox.SelectionLength = 0;
        logBox.SelectionColor = c;
        logBox.AppendText(text + Environment.NewLine);
        logBox.SelectionColor = logBox.ForeColor;
        logBox.SelectionStart = logBox.TextLength;
        logBox.ScrollToCaret();
    }

    void TrimLog()
    {
        if (logBox.Lines.Length > 4000)
        {
            int cut = logBox.GetFirstCharIndexFromLine(1000);
            if (cut > 0) logBox.Select(0, cut);
            if (logBox.SelectionLength > 0) logBox.SelectedText = "";
        }
    }

    // ==============================================================
    //  本局结束报告
    // ==============================================================
    void ShowGameReport()
    {
        List<string> errors = new List<string>();
        List<string> warns = new List<string>();
        lock (fileLock)
        {
            try
            {
                if (File.Exists(ConfigStore.LogPath))
                {
                    foreach (string ln in File.ReadAllLines(ConfigStore.LogPath))
                    {
                        int idx = ln.IndexOf("] x ");
                        if (idx >= 0) { errors.Add(ln); continue; }
                        idx = ln.IndexOf("] ! ");
                        if (idx >= 0) warns.Add(ln);
                    }
                }
            }
            catch { }
        }

        int slow = 0, reset = 0;
        foreach (string w in warns)
        {
            if (w.Contains("系统响应变慢")) slow++;
            else if (w.Contains("被重置")) reset++;
        }

        StringBuilder sb = new StringBuilder();
        sb.AppendLine("本局运行报告");
        sb.AppendLine("────────────────────────────");
        sb.AppendLine("运行时长：" + ElapsedText());
        sb.AppendLine("巡检次数：" + tickCount);
        sb.AppendLine("平台设置成功：" + okCount + " 次");
        sb.AppendLine("警告：" + warns.Count + " 次（系统响应变慢 " + slow + " / 设置被重置 " + reset + "）");
        sb.AppendLine("错误：" + errors.Count + " 次");
        if (errors.Count > 0)
        {
            sb.AppendLine();
            sb.AppendLine("错误明细：");
            int shown = 0;
            foreach (string er in errors)
            {
                sb.AppendLine(er);
                shown++;
                if (shown >= 8) break;
            }
            if (errors.Count > 8) sb.AppendLine("... 共 " + errors.Count + " 条");
        }
        else
        {
            sb.AppendLine();
            sb.AppendLine("✔ 所有进程设置均成功生效，未发现错误。");
        }
        sb.AppendLine();
        sb.Append(cfg.ClearLogAfterGame ? "（报告后日志已自动清理）" : "（日志已保留）");

        MessageBox.Show(this, sb.ToString(), "本局运行报告", MessageBoxButtons.OK,
            errors.Count > 0 ? MessageBoxIcon.Warning : MessageBoxIcon.Information);

        if (cfg.ClearLogAfterGame)
        {
            lock (fileLock)
            {
                try { if (File.Exists(ConfigStore.LogPath)) File.Delete(ConfigStore.LogPath); }
                catch { }
            }
            Log('i', "本局日志已清理，下一次会话将重新记录。");
        }
    }

    // ==============================================================
    //  打开配置
    // ==============================================================
    void OpenConfig()
    {
        if (running)
        {
            if (MessageBox.Show(this, "监控正在运行，修改配置需要先停止监控。是否停止并打开配置？",
                "提示", MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes) return;
            StopMonitor(false);
        }
        using (SettingsForm sf = new SettingsForm(cfg))
        {
            if (sf.ShowDialog(this) == DialogResult.OK)
            {
                cfg = sf.Result;
                ConfigStore.Save(cfg);
                ApplyConfig();
                AppendLog('i', "配置已保存并应用。");
            }
        }
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        running = false;
        if (worker != null) { try { worker.Join(1000); } catch { } }
        base.OnFormClosing(e);
    }
}

// ==================================================================
//  程序入口
// ==================================================================
static class Program
{
    static Mutex mutex;

    [STAThread]
    static void Main()
    {
        bool created = false;
        mutex = new Mutex(true, "Local\\cs2wd40-Optimizer", out created);
        if (!created)
        {
            MessageBox.Show("cs2wd-40 已经在运行了。请查看任务栏中的窗口。", "cs2wd-40",
                MessageBoxButtons.OK, MessageBoxIcon.Information);
            return;
        }
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.Run(new MainForm());
    }
}
