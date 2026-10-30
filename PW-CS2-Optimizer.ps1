<#
    PW-CS2-Optimizer.ps1  (v4)

    完美世界竞技平台 / CS2（及其他游戏）进程优化脚本

    功能：
      - 平台目录下所有进程 → 效率模式(EcoQoS) + BelowNormal + 内存Low + CPU0-CPU{N-1}
      - 游戏进程           → 优先级可调 + CPU 相关性可调（默认排除 CPU0/1）
      - 实时监控：进程被重置时自动补锁，新进程纳入
      - 平台+游戏都退出后自动停止
      - 单实例：已有实例时激活旧窗口
      - 日志轮转 + Win 版本检测 + 小核机器自动适配

    参数（所有参数都有默认值，也可以通过 config.json 配置）：
      -ConfigPath       配置文件路径（默认同目录 PW-CS2-Optimizer.config.json）
      -ShowConfig       弹出图形化配置界面
      -CheckOnly        内部：检查是否已有实例在运行
      -Dump             只打印进程归属诊断
      以下参数会覆盖 config.json 的同名字段：
      -PlatformExe      平台 exe 完整路径
      -GameProcessName  游戏进程名（不带 .exe），默认 cs2
      -Cs2Priority      AboveNormal(默认) / High / Normal
      -Cs2Affinity      Exclude01(默认) / All / Custom
      -CustomMask       十六进制相关性掩码（Cs2Affinity=Custom 时用）
      -PlatCoresCount   平台占用核数，默认 2
      -IntervalMs       巡检间隔 ms，默认 2000
      -NoLaunch         只监控，不启动平台
      -AutoLaunch       强制自动启动（覆盖 config 中的开关）
#>

param(
    [string]$ConfigPath = '',
    [switch]$ShowConfig,
    [switch]$CheckOnly,
    [switch]$Dump,
    [string]$PlatformExe = '',
    [string]$GameProcessName = '',
    [ValidateSet('High','AboveNormal','Normal')][string]$Cs2Priority = '',
    [ValidateSet('Exclude01','All','Custom')][string]$Cs2Affinity = '',
    [string]$CustomMask = '',
    [ValidateRange(1,8)][int]$PlatCoresCount = 0,
    [int]$IntervalMs = 0,
    [switch]$NoLaunch,
    [switch]$AutoLaunch
)

$ErrorActionPreference = 'SilentlyContinue'

# ------------------------------------------------------------------
# 配置加载：config.json 为基础，命令行参数覆盖
# ------------------------------------------------------------------
if ([string]::IsNullOrEmpty($ConfigPath)) {
    $ConfigPath = Join-Path $PSScriptRoot 'PW-CS2-Optimizer.config.json'
}

# 如果用户请求弹配置界面，直接启动 UI 然后退出
if ($ShowConfig) {
    & (Join-Path $PSScriptRoot 'PW-CS2-Optimizer-UI.ps1') -ConfigPath $ConfigPath
    exit 0
}

$DefaultConfig = [ordered]@{
    PlatformPath        = ''
    GameProcessName     = 'cs2'
    Cs2Affinity         = 'Exclude01'
    CustomMask          = ''
    Cs2Priority         = 'AboveNormal'
    PlatCoresCount      = 2
    IntervalMs          = 2000
    AutoLaunchPlatform  = $true
    LogMaxMb            = 10
    PlatNamesExtra      = @()
    SteamNamesExtra     = @()
}

function Load-OptimizerConfig {
    # [ordered]@{}.Clone() 在 PS5 里会返回空对象，手动逐键复制更安全
    $cfg = [ordered]@{}
    foreach ($k in $DefaultConfig.Keys) { $cfg[$k] = $DefaultConfig[$k] }
    if (Test-Path -LiteralPath $ConfigPath) {
        try {
            $raw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
            $disk = $raw | ConvertFrom-Json -AsHashtable
            foreach ($k in $DefaultConfig.Keys) {
                if ($disk.ContainsKey($k) -and $null -ne $disk[$k]) {
                    $cfg[$k] = $disk[$k]
                }
            }
        } catch { }
    }
    # 命令行参数覆盖（非空/非零值才覆盖）
    if (-not [string]::IsNullOrWhiteSpace($PlatformExe))      { $cfg['PlatformPath']       = $PlatformExe }
    if (-not [string]::IsNullOrWhiteSpace($GameProcessName))  { $cfg['GameProcessName']    = $GameProcessName.ToLower() }
    if (-not [string]::IsNullOrWhiteSpace($Cs2Priority))     { $cfg['Cs2Priority']        = $Cs2Priority }
    if (-not [string]::IsNullOrWhiteSpace($Cs2Affinity))     { $cfg['Cs2Affinity']        = $Cs2Affinity }
    if (-not [string]::IsNullOrWhiteSpace($CustomMask))      { $cfg['CustomMask']         = $CustomMask.ToUpper() }
    if ($PlatCoresCount -gt 0)                               { $cfg['PlatCoresCount']     = $PlatCoresCount }
    if ($IntervalMs -gt 0)                                   { $cfg['IntervalMs']         = $IntervalMs }
    if ($NoLaunch)                                           { $cfg['AutoLaunchPlatform'] = $false }
    if ($AutoLaunch)                                         { $cfg['AutoLaunchPlatform'] = $true }
    return $cfg
}

# -Dump 和 -ShowConfig 是独立的诊断/配置入口，不需要配置文件
if ($Dump) {
    # Dump 模式先尝试加载配置，没有就用默认值 + 命令行 PlatformExe
    $C = Load-OptimizerConfig
} elseif (-not (Test-Path -LiteralPath $ConfigPath) -and [string]::IsNullOrWhiteSpace($PlatformExe)) {
    Write-Host ''
    Write-Host '  ⚠ 未找到配置文件。将打开配置向导，请先设置你的平台路径。' -ForegroundColor Yellow
    Write-Host ''
    & (Join-Path $PSScriptRoot 'PW-CS2-Optimizer-UI.ps1') -ConfigPath $ConfigPath
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        Write-Host '  配置未保存，脚本退出。' -ForegroundColor Red
        exit 1
    }
    $C = Load-OptimizerConfig
} else {
    $C = Load-OptimizerConfig
}

# ------------------------------------------------------------------
# 日志 + 日志轮转
# ------------------------------------------------------------------
$script:LogFile = Join-Path ([Environment]::GetFolderPath('Desktop')) 'PW-CS2-Optimizer.log'
$script:LogMaxBytes = [int64]$C.LogMaxMb * 1MB

function Rotate-Log {
    if (-not (Test-Path -LiteralPath $script:LogFile)) { return }
    $item = Get-Item -LiteralPath $script:LogFile -ErrorAction SilentlyContinue
    if ($item -and $item.Length -gt $script:LogMaxBytes) {
        try {
            $bak = $script:LogFile -replace '\.log$', '.bak.log'
            if (Test-Path -LiteralPath $bak) { Remove-Item -LiteralPath $bak -Force -ErrorAction SilentlyContinue }
            Move-Item -LiteralPath $script:LogFile -Destination $bak -Force -ErrorAction SilentlyContinue
        } catch { }
    }
}

function Write-Log {
    param([string]$Tag, [string]$Text)
    $color = 'Gray'
    switch ($Tag) {
        '+' { $color = 'Green' }
        '!' { $color = 'Yellow' }
        'x' { $color = 'Red' }
        'i' { $color = 'DarkGray' }
    }
    Write-Host ('[{0}] {1} {2}' -f (Get-Date -Format 'HH:mm:ss'), $Tag, $Text) -ForegroundColor $color
    try {
        Rotate-Log
        Add-Content -Path $script:LogFile -Value ('[{0}] {1} {2}' -f (Get-Date -Format 'MM-dd HH:mm:ss'), $Tag, $Text) -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch { }
}

function Get-ErrText {
    param([int]$Code)
    switch ($Code) {
        5 { return '拒绝访问（该进程权限比脚本高 / 被系统或反作弊保护）' }
        87 { return '参数无效' }
        0 { return '未知原因' }
        default { return ('Win32 错误 {0}' -f $Code) }
    }
}

# ------------------------------------------------------------------
# 窗口辅助：查找并激活已运行实例的控制台窗口
# ------------------------------------------------------------------
Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;

public static class WinHelper
{
    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")]
    private static extern bool ShowWindow(IntPtr hWnd, int cmd);
    [DllImport("user32.dll")]
    private static extern bool IsIconic(IntPtr hWnd);

    public static IntPtr FindByTitlePrefix(string prefix)
    {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate(IntPtr h, IntPtr l)
        {
            if (!IsWindowVisible(h)) return true;
            StringBuilder sb = new StringBuilder(512);
            if (GetWindowText(h, sb, sb.Capacity) > 0 && sb.ToString().StartsWith(prefix, StringComparison.Ordinal))
            {
                found = h;
                return false;
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    public static void Activate(IntPtr h)
    {
        if (IsIconic(h)) ShowWindow(h, 9);   // SW_RESTORE
        else ShowWindow(h, 5);               // SW_SHOW
        SetForegroundWindow(h);
    }
}
'@

$MUTEX_NAME = 'Local\PW-CS2-Optimizer'

# 仅检查模式：由 cmd 调用，查互斥体并激活旧窗口
if ($CheckOnly) {
    $exists = $false
    try {
        $existing = [System.Threading.Mutex]::OpenExisting($MUTEX_NAME)
        $exists = $true
        $existing.Dispose()
    } catch { }

    if ($exists) {
        $hwnd = [WinHelper]::FindByTitlePrefix('PW-CS2-Optimizer [')
        if ($hwnd -ne [IntPtr]::Zero) { [WinHelper]::Activate($hwnd) }
        exit 42
    }
    exit 0
}

# 单实例守卫（-Dump 只读模式不参与）
if (-not $Dump) {
    $createdNew = $false
    try {
        $global:OptimizerMutex = New-Object System.Threading.Mutex($true, $MUTEX_NAME, [ref]$createdNew)
    } catch {
        $createdNew = $true
    }
    if (-not $createdNew) {
        Write-Host '已有脚本在运行，正在切换到该窗口...' -ForegroundColor Yellow
        $hwnd = [WinHelper]::FindByTitlePrefix('PW-CS2-Optimizer [')
        if ($hwnd -ne [IntPtr]::Zero) { [WinHelper]::Activate($hwnd) }
        Start-Sleep -Milliseconds 800
        exit 0
    }
    try { $Host.UI.RawUI.WindowTitle = "PW-CS2-Optimizer [$PID]" } catch { }
}

# ------------------------------------------------------------------
# ProcTuner：P/Invoke 封装（与 v3 完全一致）
# ------------------------------------------------------------------
Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class ProcTuner
{
    [StructLayout(LayoutKind.Sequential)]
    private struct PTS { public uint Version; public uint ControlMask; public uint StateMask; }

    [StructLayout(LayoutKind.Sequential)]
    private struct MEMPRIO { public uint MemoryPriority; }

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    private struct LUID { public uint Low; public int High; }

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    private struct LUID_AND_ATTRIBUTES { public LUID Luid; public uint Attributes; }

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    private struct TOKEN_PRIVILEGES { public uint Count; public LUID_AND_ATTRIBUTES Priv; }

    private const int ProcessMemoryPriority = 0;
    private const int ProcessPowerThrottling = 4;
    private const uint ExecutionSpeed = 0x1;
    private const uint Access = 0x0200 | 0x0400 | 0x1000; // SET_INFORMATION | QUERY_INFORMATION | QUERY_LIMITED
    private const uint BelowNormalPriorityClass = 0x00004000;
    private const uint HighPriorityClass = 0x00000080;
    private const uint MemoryPriorityLow = 2;

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetProcessInformation(IntPtr h, int cls, ref PTS info, uint size);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetProcessInformation(IntPtr h, int cls, ref PTS info, uint size);
    [DllImport("kernel32.dll", EntryPoint = "SetProcessInformation", SetLastError = true)]
    private static extern bool SetProcessInfoMem(IntPtr h, int cls, ref MEMPRIO info, uint size);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetPriorityClass(IntPtr h, uint cls);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetProcessAffinityMask(IntPtr h, UIntPtr mask);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetProcessAffinityMask(IntPtr h, out UIntPtr procMask, out UIntPtr sysMask);
    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool OpenProcessToken(IntPtr p, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool LookupPrivilegeValue(string system, string name, out LUID luid);
    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool AdjustTokenPrivileges(IntPtr token, bool disableAll, ref TOKEN_PRIVILEGES newState, uint len, IntPtr prev, IntPtr retLen);
    [DllImport("kernel32.dll")]
    private static extern IntPtr GetCurrentProcess();

    public class TuneResult
    {
        public bool EcoOn;
        public bool PriorityOk;
        public bool MemoryOk;
        public bool AffinityOk;
        public int Error;
        public bool Ok { get { return EcoOn && PriorityOk && AffinityOk; } }
    }

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
            tp.Priv.Attributes = 0x00000002; // SE_PRIVILEGE_ENABLED
            return AdjustTokenPrivileges(token, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
        }
        finally { CloseHandle(token); }
    }

    public static TuneResult ApplyPlatform(int pid, ulong mask)
    {
        TuneResult r = new TuneResult();
        IntPtr h = OpenProcess(Access, false, pid);
        if (h == IntPtr.Zero) { r.Error = Marshal.GetLastWin32Error(); return r; }
        try
        {
            PTS s = new PTS();
            s.Version = 1;
            s.ControlMask = ExecutionSpeed;
            s.StateMask = ExecutionSpeed;
            r.EcoOn = SetProcessInformation(h, ProcessPowerThrottling, ref s, (uint)Marshal.SizeOf(typeof(PTS)));
            if (!r.EcoOn) r.Error = Marshal.GetLastWin32Error();

            r.PriorityOk = SetPriorityClass(h, BelowNormalPriorityClass);
            if (!r.PriorityOk && r.Error == 0) r.Error = Marshal.GetLastWin32Error();

            MEMPRIO m = new MEMPRIO();
            m.MemoryPriority = MemoryPriorityLow;
            r.MemoryOk = SetProcessInfoMem(h, ProcessMemoryPriority, ref m, 4);

            r.AffinityOk = SetProcessAffinityMask(h, new UIntPtr(mask));
            if (!r.AffinityOk && r.Error == 0) r.Error = Marshal.GetLastWin32Error();
            return r;
        }
        finally { CloseHandle(h); }
    }

    public static TuneResult ApplyGame(int pid, ulong mask, uint prioClass)
    {
        TuneResult r = new TuneResult();
        IntPtr h = OpenProcess(Access, false, pid);
        if (h == IntPtr.Zero) { r.Error = Marshal.GetLastWin32Error(); return r; }
        try
        {
            r.PriorityOk = SetPriorityClass(h, prioClass);
            if (!r.PriorityOk) r.Error = Marshal.GetLastWin32Error();

            r.AffinityOk = SetProcessAffinityMask(h, new UIntPtr(mask));
            if (!r.AffinityOk && r.Error == 0) r.Error = Marshal.GetLastWin32Error();
            r.EcoOn = true;
            r.MemoryOk = true;
            return r;
        }
        finally { CloseHandle(h); }
    }

    public static int GetEfficiency(int pid)
    {
        IntPtr h = OpenProcess(Access, false, pid);
        if (h == IntPtr.Zero) return -1;
        try
        {
            PTS s = new PTS();
            s.Version = 1;
            if (!GetProcessInformation(h, ProcessPowerThrottling, ref s, (uint)Marshal.SizeOf(typeof(PTS)))) return -1;
            return (s.StateMask & ExecutionSpeed) != 0 ? 1 : 0;
        }
        finally { CloseHandle(h); }
    }

    public static ulong GetAffinity(int pid)
    {
        IntPtr h = OpenProcess(Access, false, pid);
        if (h == IntPtr.Zero) return 0;
        try
        {
            UIntPtr procMask, sysMask;
            if (!GetProcessAffinityMask(h, out procMask, out sysMask)) return 0;
            return procMask.ToUInt64();
        }
        finally { CloseHandle(h); }
    }

    // 可用物理内存（MB）。P/Invoke GlobalMemoryStatusEx，比 WMI 快三个数量级
    [StructLayout(LayoutKind.Sequential)]
    private struct MEMSTATUS
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

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GlobalMemoryStatusEx(ref MEMSTATUS lpBuffer);

    public static ulong MemAvailMb()
    {
        MEMSTATUS m = new MEMSTATUS();
        m.dwLength = (uint)Marshal.SizeOf(typeof(MEMSTATUS));
        if (!GlobalMemoryStatusEx(ref m)) return 0;
        return m.ullAvailPhys / 1048576UL;
    }
}
'@

# ------------------------------------------------------------------
# 平台路径自动探测
# ------------------------------------------------------------------
function Find-PlatformExe {
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($root in $roots) {
        $hits = Get-ItemProperty -Path $root -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayIcon -like '*perfectworldarena*' }
        foreach ($hit in $hits) {
            $exe = ($hit.DisplayIcon -split ',')[0].Trim()
            if ($exe -and (Test-Path -LiteralPath $exe)) { return $exe }
        }
    }

    $searchRoots = @(
        (Join-Path $env:USERPROFILE 'Desktop'),
        (Join-Path $env:USERPROFILE 'Downloads'),
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)},
        $env:LOCALAPPDATA
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }

    foreach ($root in $searchRoots) {
        $dir = Get-ChildItem -LiteralPath $root -Directory -Filter 'perfectworldarena' -Recurse -Depth 2 -ErrorAction SilentlyContinue |
               Select-Object -First 1
        if ($dir) {
            $exe = Get-ChildItem -LiteralPath $dir.FullName -Filter '*.exe' -File -ErrorAction SilentlyContinue |
                   Where-Object { $_.Name -notmatch '^(Uninstall|uninst)' } |
                   Sort-Object Length -Descending | Select-Object -First 1
            if ($exe) { return $exe.FullName }
        }
    }
    return $null
}

# ---------------- 基础信息 ----------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$hasDebugPriv = [ProcTuner]::EnablePrivilege('SeDebugPrivilege')
[void][ProcTuner]::EnablePrivilege('SeIncreaseBasePriorityPrivilege')

$osVer = [Environment]::OSVersion.Version
$supportsEcoQoS = ($osVer.Build -ge 19041)  # Win10 2004 / Win11+

# 平台路径：config 优先，命令行参数已在 Load-OptimizerConfig 中合并进 $C
if (-not [string]::IsNullOrWhiteSpace($C.PlatformPath) -and (Test-Path -LiteralPath $C.PlatformPath)) {
    $platformExePath = (Resolve-Path -LiteralPath $C.PlatformPath).Path
} else {
    $platformExePath = Find-PlatformExe
}

if (-not $platformExePath -or -not (Test-Path -LiteralPath $platformExePath)) {
    Write-Host ''
    Write-Host '  ❌ 未找到完美世界竞技平台。' -ForegroundColor Red
    Write-Host '  请运行配置向导：双击 .cmd 文件或执行 -ShowConfig。' -ForegroundColor Red
    Write-Host '  也可以用命令行：-PlatformExe "完整路径"' -ForegroundColor Red
    Write-Host ''
    Read-Host '按回车退出'
    exit 1
}

$platformDir = Split-Path -Parent $platformExePath
if (-not $platformDir.EndsWith('\')) { $platformDir += '\' }

# ---------------- 进程归属识别 ----------------
$GameNameLower = $C.GameProcessName.ToLower()

$platNames = @(
    'perfectworldarena', 'perfectworld', 'pwplatform', 'pwclient', 'pwautil64',
    'pwhelper', 'pwlauncher', 'pwupdate', 'dota2assist', 'pwahelper'
)
# 合并用户在 config 里加的额外平台进程名
foreach ($n in @($C.PlatNamesExtra)) {
    if ($n -and $platNames -notcontains $n.ToLower()) { $platNames += $n.ToLower() }
}

$steamNames = @('steam', 'steamwebhelper', 'steamservice', 'gameoverlayui', 'steamerrorreporter')
foreach ($n in @($C.SteamNamesExtra)) {
    if ($n -and $steamNames -notcontains $n.ToLower()) { $steamNames += $n.ToLower() }
}

$platRoots = New-Object System.Collections.Generic.List[string]
[void]$platRoots.Add($platformDir)
$platParent = Split-Path -Parent $platformDir.TrimEnd('\')
if ($platParent -and (Split-Path -Leaf $platParent) -match '完美|perfect|wmpvp') {
    if (-not $platParent.EndsWith('\')) { $platParent += '\' }
    [void]$platRoots.Add($platParent)
}

function Test-PlatPath {
    param([string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return $false }
    foreach ($r in $platRoots) {
        if ($Path.StartsWith($r, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Test-PlatName {
    param([string]$Name)
    if ([string]::IsNullOrEmpty($Name)) { return $false }
    $n = $Name.ToLower()
    if ($steamNames -contains $n) { return $false }
    if ($n -like 'pw*' -or $n -like 'pwa*') { return $true }
    return ($platNames -contains $n)
}

function Test-SteamName {
    param([string]$Name)
    if ([string]::IsNullOrEmpty($Name)) { return $false }
    return ($steamNames -contains $Name.ToLower()) -or ($Name -like 'steam*')
}

$script:PpidMap = @{}
function Update-PpidMap {
    $map = @{}
    foreach ($r in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
        $map[[int]$r.ProcessId] = @{
            ParentId = [int]$r.ParentProcessId
            Name     = [IO.Path]::GetFileNameWithoutExtension([string]$r.Name)
            Path     = [string]$r.ExecutablePath
        }
    }
    $script:PpidMap = $map
}

function Test-PlatByParent {
    param([int]$Id)
    $cur = $Id
    for ($i = 0; $i -lt 10; $i++) {
        if (-not $script:PpidMap.ContainsKey($cur)) { return $false }
        $e = $script:PpidMap[$cur]
        if (Test-SteamName $e.Name) { return $false }
        if (Test-PlatPath $e.Path) { return $true }
        if (Test-PlatName $e.Name) { return $true }
        $cur = [int]$e.ParentId
        if ($cur -le 4) { return $false }
    }
    return $false
}

# ---------------- -Dump 诊断 ----------------
if ($Dump) {
    Update-PpidMap
    Write-Host ''
    Write-Host ('  诊断：平台目录 {0}' -f $platformDir) -ForegroundColor Cyan
    Write-Host ('  游戏进程名：{0}' -f $GameNameLower) -ForegroundColor Cyan
    Write-Host ('  识别根目录：{0}' -f ($platRoots -join ' | ')) -ForegroundColor DarkGray
    Write-Host ''
    Write-Host ('  {0,-7} {1,-7} {2,-32} {3,-9} {4}' -f 'PID', 'PPID', '进程名', '判定', '路径') -ForegroundColor Cyan
    $nPlat = 0; $nGame = 0; $suspect = @()
    foreach ($r in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Sort-Object ProcessId)) {
        $nm = [IO.Path]::GetFileNameWithoutExtension([string]$r.Name)
        $path = [string]$r.ExecutablePath
        $kind = ''
        if ($nm -ieq $GameNameLower) { $kind = '游戏'; $nGame++ }
        elseif ((Test-PlatPath $path) -or (Test-PlatName $nm)) { $kind = '平台'; $nPlat++ }
        elseif (Test-PlatByParent ([int]$r.ProcessId)) { $kind = '平台(父子)'; $nPlat++ }
        else {
            $kind = '其他'
            if ($nm -match 'pw|perfect|arena|cef|dota|crashpad|anticheat|ace') { $suspect += ('{0}(PID {1})' -f $r.Name, $r.ProcessId) }
        }
        $p = if ($path) { $path } else { '<路径不可读>' }
        $color = if ($kind -like '平台*') { 'Green' } elseif ($kind -eq '游戏') { 'Cyan' } else { 'DarkGray' }
        Write-Host ('  {0,-7} {1,-7} {2,-32} {3,-9} {4}' -f $r.ProcessId, $r.ParentProcessId, $r.Name, $kind, $p) -ForegroundColor $color
    }
    Write-Host ''
    Write-Host ('  汇总：平台 {0} 个，游戏({1}) {2} 个' -f $nPlat, $GameNameLower, $nGame) -ForegroundColor Yellow
    if ($suspect.Count -gt 0) {
        Write-Host ('  未被识别但名字可疑：{0}' -f ($suspect -join ', ')) -ForegroundColor Yellow
    }
    Write-Host ''
    exit 0
}

# ---------------- CPU 掩码（带小核边界保护）----------------
$coreCount = [Math]::Min([Environment]::ProcessorCount, 63)
# 小核保护：平台核数不能 >= 总核数，至少留 2 核给游戏
$safePlatCores = $C.PlatCoresCount
if ($coreCount -le 2) {
    $safePlatCores = 1
    Write-Host "  [注意] 只有 $coreCount 核，平台核数自动降为 1。" -ForegroundColor Yellow
} elseif ($safePlatCores -ge ($coreCount - 1)) {
    $safePlatCores = [Math]::Max(1, $coreCount - 2)
    Write-Host "  [注意] $coreCount 核机器上平台核数设为 $($C.PlatCoresCount) 会把游戏挤没，自动降为 $safePlatCores。" -ForegroundColor Yellow
}

$platMask  = [uint64]((([uint64]1 -shl $safePlatCores) - 1))
$allMask   = [uint64]((([uint64]1 -shl $coreCount) - 1))

# 游戏相关性掩码
switch ($C.Cs2Affinity) {
    'Exclude01' { $gameMask = [uint64]($allMask -bxor $platMask) }
    'All'       { $gameMask = $allMask }
    'Custom' {
        if ([string]::IsNullOrWhiteSpace($C.CustomMask)) {
            Write-Host '  [警告] Custom 模式未填掩码，降级为 Exclude01。' -ForegroundColor Yellow
            $C.Cs2Affinity = 'Exclude01'
            $gameMask = [uint64]($allMask -bxor $platMask)
        } else {
            try {
                $gameMask = [Convert]::ToUInt64($C.CustomMask, 16)
                if ($gameMask -eq 0) { throw 'zero' }
            } catch {
                Write-Host "  [警告] 自定义掩码 '$($C.CustomMask)' 无效，降级为 Exclude01。" -ForegroundColor Yellow
                $C.Cs2Affinity = 'Exclude01'
                $gameMask = [uint64]($allMask -bxor $platMask)
            }
        }
    }
    default { $gameMask = [uint64]($allMask -bxor $platMask) }
}

$cs2PrioClass = switch ($C.Cs2Priority) { 'High' { 0x00000080 } 'AboveNormal' { 0x00008000 } default { 0x00000020 } }
$cs2PrioEnum  = [System.Diagnostics.ProcessPriorityClass]$(switch ($C.Cs2Priority) { 'High' { 'High' } 'AboveNormal' { 'AboveNormal' } default { 'Normal' } })

$platDesc = 'CPU0-CPU{0}' -f ($safePlatCores - 1)
$gameDesc = if ($C.Cs2Affinity -eq 'All') { "CPU0-CPU$($coreCount-1)（全部核心）" } `
            elseif ($C.Cs2Affinity -eq 'Custom') { '自定义掩码 0x{0:X}' -f $gameMask } `
            else { 'CPU{0}-CPU{1}' -f $safePlatCores, ($coreCount - 1) }

# ---------------- 启动信息 ----------------
Write-Host ''
Write-Host '  PW / Game Optimizer v4.0' -ForegroundColor Cyan
Write-Host ('  平台路径 : {0}' -f $platformExePath) -ForegroundColor DarkGray
Write-Host ('  平台进程 : 效率模式 + BelowNormal + 内存Low + 相关性 {0}' -f $platDesc) -ForegroundColor DarkGray
if (-not $supportsEcoQoS) {
    Write-Host '  [警告] 当前 Windows 版本不支持效率模式(EcoQoS)，该项将静默跳过。建议升级到 Win10 2004+ 或 Win11。' -ForegroundColor Yellow
}
Write-Host ('  游戏({0})  : 优先级{1} + 相关性 {2}' -f $GameNameLower, $C.Cs2Priority, $gameDesc) -ForegroundColor DarkGray
Write-Host ('  逻辑处理器 {0} 个，巡检间隔 {1} ms' -f [Environment]::ProcessorCount, $C.IntervalMs) -ForegroundColor DarkGray
Write-Host ('  配置文件  : {0}' -f $ConfigPath) -ForegroundColor DarkGray
Write-Host ('  日志文件  : {0}（上限 {1} MB）' -f $script:LogFile, $C.LogMaxMb) -ForegroundColor DarkGray
if (-not $isAdmin) {
    Write-Host '  [警告] 当前不是管理员权限，多数进程将无法修改，请双击 .cmd 文件启动。' -ForegroundColor Yellow
}
if (-not $hasDebugPriv) {
    Write-Host '  [提示] 未能启用 SeDebugPrivilege（非管理员时正常），系统级进程会跳过。' -ForegroundColor Yellow
}
Write-Host ''

function Test-Zombie {
    param($Proc)
    try { return ($Proc.Threads.Count -eq 0) } catch { return $false }
}

# ---------------- 启动平台 ----------------
$doLaunch = $C.AutoLaunchPlatform -and -not $NoLaunch

if ($doLaunch) {
    $running = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessName -ine $GameNameLower -and ((Test-PlatPath $_.Path) -or (Test-PlatName $_.ProcessName)) -and -not (Test-Zombie $_)
    })
    # 关键：只看「有窗口」的平台进程
    $uiProcs = @($running | Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero })

    if ($uiProcs.Count -eq 0) {
        if ($running.Count -gt 0) {
            Write-Log 'i' ('检测到 {0} 个平台后台残留进程但没有窗口，重新启动平台界面...' -f $running.Count)
        } else {
            Write-Log 'i' '正在启动完美世界竞技平台...'
        }
        $beforeIds = @($running | ForEach-Object { $_.Id })
        $started = $true
        try {
            Start-Process -FilePath $platformExePath -WorkingDirectory (Split-Path -Parent $platformExePath) -ErrorAction Stop
        } catch {
            $started = $false
            Write-Log 'x' ('启动失败：{0}' -f $_.Exception.Message)
            Write-Host '  若被安全软件（火绒等）拦截，请手动打开一次平台，脚本会继续监控。' -ForegroundColor Yellow
        }
        if ($started) {
            $seen = $false
            for ($i = 0; $i -lt 40; $i++) {
                Start-Sleep -Milliseconds 500
                $now = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
                    $_.ProcessName -ine $GameNameLower -and ((Test-PlatPath $_.Path) -or (Test-PlatName $_.ProcessName)) -and -not (Test-Zombie $_)
                })
                if (@($now | Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero }).Count -gt 0) { $seen = $true; break }
                if ($i -ge 10 -and @($now | Where-Object { $beforeIds -notcontains $_.Id }).Count -gt 0) { $seen = $true; break }
            }
            if ($seen) { Write-Log '+' '完美世界竞技平台已启动。' }
            else {
                Write-Log '!' '已发出启动请求，但 20 秒内没有窗口、也没有存活的新进程，可能被拦截。'
            }
        }
    } else {
        Write-Log 'i' ('完美世界竞技平台已在运行（{0} 个窗口进程），不重复启动。' -f $uiProcs.Count)
        $win = $uiProcs | Select-Object -First 1
        [WinHelper]::Activate($win.MainWindowHandle)
        Write-Log 'i' '已把平台窗口切到前台。'
    }
} else {
    Write-Log 'i' '自动启动已关闭，等待平台进程出现...'
}

# ---------------- 监控循环 ----------------
$State = @{}
$tick = 0
$everSeen = $false
$emptyTicks = 0
$prevCpu = @{}
$prevCpuTime = $null
$pathCache = @{}
$kindCache = @{}
Write-Log 'i' '开始监控（关闭本窗口或按 Ctrl+C 结束）'
Write-Host ''

while ($true) {
    $tick++
    $loopStart = Get-Date
    $alive = New-Object 'System.Collections.Generic.HashSet[int]'

    if ($tick -eq 1 -or ($tick % 15) -eq 0) { Update-PpidMap }

    $platTotal = 0; $platOk = 0; $platFail = 0
    $gameState = '未运行'
    $gameAlive = $false
    $failNames = @()
    $curCpu = @{}
    $seen = New-Object 'System.Collections.Generic.HashSet[int]'
    $platIds = New-Object 'System.Collections.Generic.HashSet[int]'
    $gameIds = New-Object 'System.Collections.Generic.HashSet[int]'

    foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
        [void]$seen.Add($p.Id)
        # 路径按 PID 缓存
        $path = $pathCache[$p.Id]
        if ($null -eq $path) {
            try { $path = $p.Path } catch { $path = $null }
            if ([string]::IsNullOrEmpty($path)) { $path = '' }
            $pathCache[$p.Id] = $path
        }
        $cpuSec = 0
        try { $cpuSec = $p.TotalProcessorTime.TotalSeconds } catch { }
        $wsMb = 0
        try { $wsMb = $p.WorkingSet64 / 1MB } catch { }
        $curCpu[$p.Id] = @{ n = $p.ProcessName; t = $cpuSec; m = $wsMb }

        # 归属判定按 PID 缓存
        $kind = $kindCache[$p.Id]
        if ($null -eq $kind) {
            if ($p.ProcessName.ToLower() -eq $GameNameLower) {
                $kind = 'game'
            } elseif ((Test-PlatPath $path) -or (Test-PlatName $p.ProcessName) -or (Test-PlatByParent $p.Id)) {
                $kind = 'plat'
            } else {
                $kind = ''
            }
            $kindCache[$p.Id] = $kind
        }
        if ($kind -eq '') { continue }
        if (Test-Zombie $p) { continue }

        [void]$alive.Add($p.Id)
        if ($kind -eq 'game') { [void]$gameIds.Add($p.Id) } else { [void]$platIds.Add($p.Id) }

        $rec = $State[$p.Id]
        if ($null -eq $rec) {
            $rec = @{ Ok = $false; Notified = $false; FailLogged = $false }
            $State[$p.Id] = $rec
        }

        $mask = if ($kind -eq 'game') { $gameMask } else { $platMask }

        if ($kind -eq 'game') {
            $aff = [ProcTuner]::GetAffinity($p.Id)
            $gamePrioNow = $null
            try { $gamePrioNow = $p.PriorityClass } catch { }
            $res = $null
            if ($aff -ne $mask -or $gamePrioNow -ne $cs2PrioEnum -or -not $rec.Notified) { $res = [ProcTuner]::ApplyGame($p.Id, $mask, $cs2PrioClass) }
            $okNow = (($aff -eq $mask) -and ($gamePrioNow -eq $cs2PrioEnum)) -or ($null -ne $res -and $res.PriorityOk -and $res.AffinityOk)

            $gameState = if ($okNow) { '已在监控' } else { '设置失败' }
            $gameAlive = $true

            if (-not $rec.Notified) {
                $rec.Notified = $true
                Write-Log '+' ('检测到 {0}.exe (PID {1}) → 优先级{2} + 相关性 {3}' -f $GameNameLower, $p.Id, $C.Cs2Priority, $gameDesc)
            }
            if ($rec.Ok -and -not $okNow) {
                Write-Log '!' ('{0} (PID {1}) 设置被重置，已尝试恢复' -f $p.ProcessName, $p.Id)
            }
            if (-not $okNow -and -not $rec.FailLogged) {
                $code = if ($null -ne $res) { $res.Error } else { 0 }
                Write-Log 'x' ('{0} (PID {1}) 设置失败：{2}' -f $p.ProcessName, $p.Id, (Get-ErrText $code))
                $rec.FailLogged = $true
            }
            $rec.Ok = $okNow
        }
        else {
            $platTotal++
            $eco = [ProcTuner]::GetEfficiency($p.Id)
            $aff = [ProcTuner]::GetAffinity($p.Id)
            $prio = $null
            try { $prio = $p.PriorityClass } catch { }
            $prioOk = ($prio -eq [System.Diagnostics.ProcessPriorityClass]::BelowNormal)
            $res = $null

            if ($eco -ne 1 -or $aff -ne $mask -or -not $prioOk -or -not $rec.Notified) { $res = [ProcTuner]::ApplyPlatform($p.Id, $mask) }

            if ($null -ne $res) {
                $ecoOk = $res.EcoOn
                $affOk = $res.AffinityOk
                $prioOk = $res.PriorityOk
            } else {
                $ecoOk = ($eco -eq 1)
                $affOk = ($aff -eq $mask)
            }
            # 不支持 EcoQoS 时，ecoOk 不影响 okNow 判定
            if (-not $supportsEcoQoS) { $ecoOk = $true }
            $okNow = $ecoOk -and $affOk -and $prioOk

            if ($okNow) { $platOk++ } else { $platFail++; $failNames += ('{0}(PID {1})' -f $p.ProcessName, $p.Id) }

            if (-not $rec.Notified) {
                $rec.Notified = $true
                Write-Log '+' ('新进程 {0} (PID {1}) → {2}' -f $p.ProcessName, $p.Id, $platDesc)
            }
            if ($rec.Ok -and -not $okNow) {
                $drift = @()
                if (-not $ecoOk -and $supportsEcoQoS) { $drift += '效率模式' }
                if (-not $affOk) { $drift += '相关性' }
                if (-not $prioOk) { $drift += '优先级' }
                Write-Log '!' ('{0} (PID {1}) {2}被重置，已重新锁定' -f $p.ProcessName, $p.Id, ($drift -join '/'))
                $rec.FailLogged = $false
            }
            if (-not $okNow -and -not $rec.FailLogged) {
                $code = if ($null -ne $res) { $res.Error } else { 0 }
                $what = if (-not $ecoOk -and $supportsEcoQoS) { '效率模式' } else { '相关性' }
                Write-Log 'x' ('{0} (PID {1}) {2}设置失败：{3}' -f $p.ProcessName, $p.Id, $what, (Get-ErrText $code))
                $rec.FailLogged = $true
            }
            $rec.Ok = $okNow
        }
    }

    foreach ($key in @($State.Keys)) {
        if (-not $alive.Contains([int]$key)) { $State.Remove($key) }
    }
    foreach ($key in @($pathCache.Keys)) {
        if (-not $seen.Contains([int]$key)) { $pathCache.Remove($key) }
    }
    foreach ($key in @($kindCache.Keys)) {
        if (-not $seen.Contains([int]$key)) { $kindCache.Remove($key) }
    }

    # ---- CPU 占用采样 ----
    if ($gameAlive -and $null -ne $prevCpuTime -and ($tick % 30) -eq 0) {
        $secs = ((Get-Date) - $prevCpuTime).TotalSeconds * [Environment]::ProcessorCount
        if ($secs -gt 0) {
            $report = @()
            foreach ($kv in $curCpu.GetEnumerator()) {
                $old = $prevCpu[$kv.Key]
                if ($null -eq $old) { continue }
                $pct = [Math]::Round(100 * ($kv.Value.t - $old.t) / $secs, 1)
                if ($pct -gt 0.5) { $report += [pscustomobject]@{ Name = $kv.Value.n; Pid = $kv.Key; Pct = $pct } }
            }
            $gamePct = [Math]::Round((($report | Where-Object { $gameIds.Contains($_.Pid) } | Measure-Object Pct -Sum).Sum), 1)
            $platPct = [Math]::Round((($report | Where-Object { $platIds.Contains($_.Pid) } | Measure-Object Pct -Sum).Sum), 1)
            $others  = $report | Where-Object { -not $gameIds.Contains($_.Pid) -and -not $platIds.Contains($_.Pid) } | Sort-Object Pct -Descending | Select-Object -First 3
            $otherTxt = if ($others) { ($others | ForEach-Object { '{0} {1}%' -f $_.Name, $_.Pct }) -join ', ' } else { '无' }
            $availMb = [ProcTuner]::MemAvailMb()
            $gameMemMb = 0
            foreach ($id in $gameIds) { $gameMemMb += [int]($curCpu[$id].m) }
            Write-Log 'i' ('占用 | {0} {1}% | 平台合计 {2}% | 可用内存 {3} MB | {0} 内存 {4} MB | 其他Top: {5}' -f $GameNameLower, $gamePct, $platPct, $availMb, $gameMemMb, $otherTxt)
        }
    }
    $prevCpu = $curCpu
    $prevCpuTime = Get-Date

    # 全部退出 → 连续 4 次巡检后自动停止
    if ($platTotal -gt 0 -or $gameAlive) {
        $everSeen = $true
        $emptyTicks = 0
    } elseif ($everSeen) {
        $emptyTicks++
        if ($emptyTicks -ge 4) {
            Write-Host ''
            Write-Log 'i' '完美世界竞技平台与游戏均已退出，脚本自动停止。'
            Start-Sleep -Seconds 2
            break
        }
    }

    # 每 5 次巡检打印一次状态
    if ($tick % 5 -eq 0) {
        Write-Log 'i' ('状态 | 平台进程 {0} 个（正常 {1} / 失败 {2}）| {3}：{4}' -f $platTotal, $platOk, $platFail, $GameNameLower, $gameState)
        if ($failNames.Count -gt 0) {
            Write-Log '!' ('设置未生效：{0}' -f ($failNames -join ', '))
        }
    }

    # 游戏进行中加密巡检
    $sleep = if ($gameAlive) { [Math]::Min($C.IntervalMs, 1000) } else { $C.IntervalMs }
    Start-Sleep -Milliseconds $sleep

    # 巡检超时 = 系统级卡顿
    $elapsed = ((Get-Date) - $loopStart).TotalMilliseconds
    if ($elapsed -gt ($sleep + 1500)) {
        Write-Log '!' ('系统响应变慢：本次巡检耗时 {0} ms（正常约 {1} ms），可能发生磁盘/内存/驱动级卡顿' -f [int]$elapsed, $sleep)
    }
}

if ($global:OptimizerMutex) {
    try { $global:OptimizerMutex.ReleaseMutex() } catch { }
}
