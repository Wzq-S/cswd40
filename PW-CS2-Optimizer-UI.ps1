<#
    PW-CS2-Optimizer-UI.ps1

    图形化配置界面：填写路径、选择参数、保存到 config.json。
    由 cmd 或主脚本的 -ShowConfig 参数触发。
    纯 WinForms，无任何第三方依赖。
#>

param(
    [string]$ConfigPath = ''
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# 配置文件位置（默认与脚本同目录）
if ([string]::IsNullOrEmpty($ConfigPath)) {
    $ConfigPath = Join-Path $PSScriptRoot 'PW-CS2-Optimizer.config.json'
}

# ------------------------------------------------------------------
# 默认配置
# ------------------------------------------------------------------
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
    GameKillApps        = @()
    ClearLogAfterGame   = $true
    ShowMemoryHud       = $false
}

function New-DefaultConfig {
    $cfg = [ordered]@{}
    foreach ($k in $DefaultConfig.Keys) { $cfg[$k] = $DefaultConfig[$k] }
    return $cfg
}

function Load-Config {
    if (Test-Path -LiteralPath $ConfigPath) {
        try {
            $raw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
            $cfg = $raw | ConvertFrom-Json -AsHashtable
            # 合并默认值（新字段有兜底）
            $merged = New-DefaultConfig
            foreach ($k in $DefaultConfig.Keys) {
                if ($cfg.ContainsKey($k) -and $null -ne $cfg[$k]) {
                    $merged[$k] = $cfg[$k]
                }
            }
            return $merged
        } catch {
            return New-DefaultConfig
        }
    }
    return New-DefaultConfig
}

function Save-Config {
    param([hashtable]$Cfg)
    # PSCustomObject 比 Hashtable 序列化出来的 JSON 更干净
    $out = [ordered]@{}
    foreach ($k in $Cfg.Keys) { $out[$k] = $Cfg[$k] }
    $out | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
}

# ------------------------------------------------------------------
# 探测平台路径（复用主脚本的逻辑，精简版）
# ------------------------------------------------------------------
function Find-PlatformPathQuick {
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
    return ''
}

# ------------------------------------------------------------------
# 进程影响等级字典（关闭该进程对系统/游戏的影响）
#   safe   = 可安全关闭，不影响系统和游戏
#   warn   = 关闭有副作用，但通常不致命（关闭后需手动恢复/重启）
#   danger = 不建议关闭（系统关键 / 游戏依赖 / 反作弊）
# ------------------------------------------------------------------
$ImpactInfo = @{
    'msedge'= @('safe','Edge 浏览器'); 'chrome'=@('safe','Chrome 浏览器'); 'firefox'=@('safe','Firefox 浏览器')
    'msedgewebview2'=@('safe','网页内嵌组件'); 'iexplore'=@('safe','IE 浏览器')
    'excel'=@('safe','Excel（未保存内容会丢失）'); 'winword'=@('safe','Word（未保存内容会丢失）')
    'powerpnt'=@('safe','PowerPoint'); 'onenote'=@('safe','OneNote'); 'outlook'=@('safe','Outlook 邮件')
    'qq'=@('safe','QQ（关闭后需重新登录）'); 'wechat'=@('safe','微信（关闭后需重新登录）')
    'weixin'=@('safe','微信'); 'discord'=@('safe','Discord'); 'tim'=@('safe','TIM')
    'onedrive'=@('safe','OneDrive 同步（暂停同步）'); 'baidunetdisk'=@('safe','百度网盘')
    'potplayer'=@('safe','播放器'); 'wmplayer'=@('safe','媒体播放器'); 'vlc'=@('safe','VLC 播放器')
    'mspcmanagerservice'=@('safe','微软电脑管家服务'); 'msofficeplusservice'=@('safe','Office 增强服务')
    'trae'=@('warn','当前 IDE，关闭会丢失未保存内容'); 'code'=@('warn','VS Code，关闭会丢失未保存内容')
    'nvcontainer'=@('warn','NVIDIA 驱动组件（覆盖层/录制可能失效）'); 'nvsphelper64'=@('warn','NVIDIA 组件')
    'dwm'=@('warn','桌面窗口管理器，关闭会导致桌面黑屏'); 'explorer'=@('warn','桌面/任务栏，关闭后任务栏消失')
    'audiodg'=@('danger','Windows 音频引擎，关闭会没声音'); 'ctfmon'=@('warn','输入法，关闭无法切换输入法')
    'steam'=@('danger','Steam 客户端，CS2 依赖它运行'); 'steamwebhelper'=@('warn','Steam 内嵌组件（商店/好友可能异常）')
    'hipsdaemon'=@('warn','火绒安全主防，关闭后失去实时防护'); 'wsctrl'=@('warn','火绒安全组件')
    'system'=@('danger','系统进程，禁止关闭'); 'svchost'=@('danger','系统服务宿主，禁止关闭')
    'lsass'=@('danger','系统安全进程，禁止关闭'); 'csrss'=@('danger','系统进程，禁止关闭')
    'winlogon'=@('danger','系统进程，禁止关闭'); 'wininit'=@('danger','系统进程，禁止关闭')
    'smss'=@('danger','系统进程，禁止关闭'); 'services'=@('danger','服务控制管理器，禁止关闭')
    'spoolsv'=@('warn','打印服务，关闭后无法打印')
    'vgc'=@('danger','Vanguard 反作弊，关闭会被游戏踢出'); 'vgk'=@('danger','Vanguard 内核反作弊')
    'beservice'=@('danger','BattlEye 反作弊'); 'easyanticheat'=@('danger','EasyAntiCheat 反作弊')
}

function Get-Impact {
    param([string]$Name)
    $key = $Name.ToLower()
    if ($ImpactInfo.ContainsKey($key)) { return $ImpactInfo[$key] }
    return @('warn', '未知进程，关闭前请确认')
}

# 取当前内存占用排行（按工作集），返回分组：游戏/平台/其他 Top
function Get-MemoryBreakdown {
    param([string]$GameName)
    $all = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.WorkingSet64 -gt 0 }
    $groups = @{}
    foreach ($p in $all) {
        $n = $p.ProcessName.ToLower()
        if (-not $groups.ContainsKey($n)) { $groups[$n] = @{ Name = $p.ProcessName; Mb = 0; Count = 0 } }
        $groups[$n].Mb += [int]($p.WorkingSet64 / 1MB)
        $groups[$n].Count++
    }
    $items = $groups.Values | Sort-Object Mb -Descending
    $gameMb = 0; $platMb = 0; $platNames = 'perfectworldarena','pw','pwarena'
    $others = @()
    foreach ($it in $items) {
        if ($it.Name.ToLower() -eq $GameName) { $gameMb += $it.Mb }
        elseif ($platNames -contains $it.Name.ToLower()) { $platMb += $it.Mb }
        else { $others += $it }
    }
    return [pscustomobject]@{ Game = $gameMb; Plat = $platMb; Others = $others }
}

# ------------------------------------------------------------------
# 构建窗体
# ------------------------------------------------------------------
$cfg = Load-Config

$form = New-Object System.Windows.Forms.Form
$form.Text = 'PW / CS2 Optimizer - 配置向导'
$form.Size = New-Object System.Drawing.Size(640, 900)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.MinimizeBox = $false
$form.BackColor = [System.Drawing.Color]::FromArgb(245, 245, 250)
$font = New-Object System.Drawing.Font('Segoe UI', 9)
$form.Font = $font

# ---- 顶部系统信息面板 ----
$sysPanel = New-Object System.Windows.Forms.Panel
$sysPanel.Location = New-Object System.Drawing.Point(12, 12)
$sysPanel.Size = New-Object System.Drawing.Size(580, 68)
$sysPanel.BackColor = [System.Drawing.Color]::FromArgb(225, 235, 255)
$sysPanel.BorderStyle = 'FixedSingle'
$form.Controls.Add($sysPanel)

$osVer = [Environment]::OSVersion.Version
$osLabel = New-Object System.Windows.Forms.Label
$osLabel.Location = New-Object System.Drawing.Point(10, 8)
$osLabel.Size = New-Object System.Drawing.Size(560, 20)
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$adminStr = if ($isAdmin) { '✔ 已以管理员身份运行' } else { '⚠ 未以管理员运行（设置进程可能失败）' }
$ecoStatus = if ($osVer.Build -ge 19041) { '✔ 支持效率模式(EcoQoS)' } else { '⚠ Windows 版本过低，不支持效率模式' }
$osLabel.Text = "系统：Windows $($osVer.Major).$($osVer.Minor) Build $($osVer.Build) | 逻辑核心：$([Environment]::ProcessorCount) | $adminStr"
$osPanel2 = New-Object System.Windows.Forms.Label
$osPanel2.Location = New-Object System.Drawing.Point(10, 32)
$osPanel2.Size = New-Object System.Drawing.Size(560, 20)
$osPanel2.Text = $ecoStatus
$osPanel2.ForeColor = if ($osVer.Build -ge 19041) { [System.Drawing.Color]::DarkGreen } else { [System.Drawing.Color]::DarkOrange }
$sysPanel.Controls.Add($osLabel)
$sysPanel.Controls.Add($osPanel2)

# ---- 分组 1：平台设置 ----
$grpPlat = New-Object System.Windows.Forms.GroupBox
$grpPlat.Text = '① 完美世界竞技平台'
$grpPlat.Location = New-Object System.Drawing.Point(12, 92)
$grpPlat.Size = New-Object System.Drawing.Size(580, 110)
$form.Controls.Add($grpPlat)

$lblPlatPath = New-Object System.Windows.Forms.Label
$lblPlatPath.Location = New-Object System.Drawing.Point(12, 24)
$lblPlatPath.Size = New-Object System.Drawing.Size(100, 20)
$lblPlatPath.Text = '平台 exe 路径：'
$grpPlat.Controls.Add($lblPlatPath)

$txtPlatPath = New-Object System.Windows.Forms.TextBox
$txtPlatPath.Location = New-Object System.Drawing.Point(112, 21)
$txtPlatPath.Size = New-Object System.Drawing.Size(380, 23)
$txtPlatPath.Text = $cfg.PlatformPath
$grpPlat.Controls.Add($txtPlatPath)

$btnBrowsePlat = New-Object System.Windows.Forms.Button
$btnBrowsePlat.Location = New-Object System.Drawing.Point(495, 19)
$btnBrowsePlat.Size = New-Object System.Drawing.Size(72, 27)
$btnBrowsePlat.Text = '浏览...'
$btnBrowsePlat.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = '可执行文件 (*.exe)|*.exe|所有文件 (*.*)|*.*'
    $dlg.Title = '选择完美世界竞技平台的 exe 文件'
    if ($dlg.ShowDialog() -eq 'OK') { $txtPlatPath.Text = $dlg.FileName }
})
$grpPlat.Controls.Add($btnBrowsePlat)

$btnDetect = New-Object System.Windows.Forms.Button
$btnDetect.Location = New-Object System.Drawing.Point(495, 50)
$btnDetect.Size = New-Object System.Drawing.Size(72, 27)
$btnDetect.Text = '自动探测'
$btnDetect.Add_Click({
    $found = Find-PlatformPathQuick
    if ($found) {
        $txtPlatPath.Text = $found
        [System.Windows.Forms.MessageBox]::Show("探测成功：`n$found", '已找到', 'OK', 'Information')
    } else {
        [System.Windows.Forms.MessageBox]::Show('未能自动探测到平台路径，请手动浏览选择。', '未找到', 'OK', 'Warning')
    }
})
$grpPlat.Controls.Add($btnDetect)

$chkAutoLaunch = New-Object System.Windows.Forms.CheckBox
$chkAutoLaunch.Location = New-Object System.Drawing.Point(112, 56)
$chkAutoLaunch.Size = New-Object System.Drawing.Size(300, 20)
$chkAutoLaunch.Text = '启动优化器时自动打开平台'
$chkAutoLaunch.Checked = $cfg.AutoLaunchPlatform
$grpPlat.Controls.Add($chkAutoLaunch)

$lblPlatNote = New-Object System.Windows.Forms.Label
$lblPlatNote.Location = New-Object System.Drawing.Point(112, 80)
$lblPlatNote.Size = New-Object System.Drawing.Size(455, 18)
$lblPlatNote.Text = '平台进程将被设置为：效率模式 + 优先级 BelowNormal + 占用 CPU0-CPU{N-1}'
$lblPlatNote.ForeColor = [System.Drawing.Color]::Gray
$grpPlat.Controls.Add($lblPlatNote)

# ---- 分组 2：游戏设置 ----
$grpGame = New-Object System.Windows.Forms.GroupBox
$grpGame.Text = '② 游戏进程（默认 CS2）'
$grpGame.Location = New-Object System.Drawing.Point(12, 212)
$grpGame.Size = New-Object System.Drawing.Size(580, 135)
$form.Controls.Add($grpGame)

$lblGameName = New-Object System.Windows.Forms.Label
$lblGameName.Location = New-Object System.Drawing.Point(12, 28)
$lblGameName.Size = New-Object System.Drawing.Size(110, 20)
$lblGameName.Text = '游戏进程名：'
$grpGame.Controls.Add($lblGameName)

$txtGameName = New-Object System.Windows.Forms.TextBox
$txtGameName.Location = New-Object System.Drawing.Point(125, 25)
$txtGameName.Size = New-Object System.Drawing.Size(120, 23)
$txtGameName.Text = $cfg.GameProcessName
$grpGame.Controls.Add($txtGameName)

$lblGameNameHint = New-Object System.Windows.Forms.Label
$lblGameNameHint.Location = New-Object System.Drawing.Point(250, 28)
$lblGameNameHint.Size = New-Object System.Drawing.Size(200, 18)
$lblGameNameHint.Text = '（不带 .exe，如 cs2、dota2）'
$lblGameNameHint.ForeColor = [System.Drawing.Color]::Gray
$grpGame.Controls.Add($lblGameNameHint)

$lblAffinity = New-Object System.Windows.Forms.Label
$lblAffinity.Location = New-Object System.Drawing.Point(12, 60)
$lblAffinity.Size = New-Object System.Drawing.Size(110, 20)
$lblAffinity.Text = 'CPU 相关性：'
$grpGame.Controls.Add($lblAffinity)

$cmbAffinity = New-Object System.Windows.Forms.ComboBox
$cmbAffinity.Location = New-Object System.Drawing.Point(125, 57)
$cmbAffinity.Size = New-Object System.Drawing.Size(200, 23)
$cmbAffinity.DropDownStyle = 'DropDownList'
$cmbAffinity.Items.AddRange(@(
    'Exclude01 - 排除 CPU0/1（推荐）',
    'All - 使用全部核心',
    'Custom - 自定义掩码'
))
$cmbAffinity.SelectedIndex = switch ($cfg.Cs2Affinity) {
    'Exclude01' { 0 }
    'All'       { 1 }
    'Custom'    { 2 }
    default     { 0 }
}
$grpGame.Controls.Add($cmbAffinity)

$lblCustomMask = New-Object System.Windows.Forms.Label
$lblCustomMask.Location = New-Object System.Drawing.Point(335, 60)
$lblCustomMask.Size = New-Object System.Drawing.Size(100, 20)
$lblCustomMask.Text = '自定义掩码：'
$grpGame.Controls.Add($lblCustomMask)

$txtCustomMask = New-Object System.Windows.Forms.TextBox
$txtCustomMask.Location = New-Object System.Drawing.Point(440, 57)
$txtCustomMask.Size = New-Object System.Drawing.Size(127, 23)
$txtCustomMask.Text = $cfg.CustomMask
$txtCustomMask.Enabled = ($cfg.Cs2Affinity -eq 'Custom')
$grpGame.Controls.Add($txtCustomMask)

$cmbAffinity.Add_SelectedIndexChanged({
    $txtCustomMask.Enabled = ($cmbAffinity.SelectedIndex -eq 2)
})

$lblPriority = New-Object System.Windows.Forms.Label
$lblPriority.Location = New-Object System.Drawing.Point(12, 92)
$lblPriority.Size = New-Object System.Drawing.Size(110, 20)
$lblPriority.Text = '进程优先级：'
$grpGame.Controls.Add($lblPriority)

$cmbPriority = New-Object System.Windows.Forms.ComboBox
$cmbPriority.Location = New-Object System.Drawing.Point(125, 89)
$cmbPriority.Size = New-Object System.Drawing.Size(200, 23)
$cmbPriority.DropDownStyle = 'DropDownList'
$cmbPriority.Items.AddRange(@(
    'AboveNormal - 高于正常（推荐）',
    'High - 高（可能饿死驱动）',
    'Normal - 正常'
))
$cmbPriority.SelectedIndex = switch ($cfg.Cs2Priority) {
    'AboveNormal' { 0 }
    'High'        { 1 }
    'Normal'      { 2 }
    default       { 0 }
}
$grpGame.Controls.Add($cmbPriority)

$lblGameNote = New-Object System.Windows.Forms.Label
$lblGameNote.Location = New-Object System.Drawing.Point(12, 115)
$lblGameNote.Size = New-Object System.Drawing.Size(555, 18)
$lblGameNote.Text = '游戏进程不启用效率模式，以保证最流畅的响应。'
$lblGameNote.ForeColor = [System.Drawing.Color]::Gray
$grpGame.Controls.Add($lblGameNote)

# ---- 分组 3：内存与后台应用 ----
$grpMem = New-Object System.Windows.Forms.GroupBox
$grpMem.Text = '③ 内存占用与后台应用（游戏时自动关闭）'
$grpMem.Location = New-Object System.Drawing.Point(12, 358)
$grpMem.Size = New-Object System.Drawing.Size(600, 200)
$form.Controls.Add($grpMem)

$lblMemHint = New-Object System.Windows.Forms.Label
$lblMemHint.Location = New-Object System.Drawing.Point(12, 22)
$lblMemHint.Size = New-Object System.Drawing.Size(575, 18)
$lblMemHint.Text = '勾选要在游戏开始时自动关闭的应用。绿色=安全，黄色=有副作用，红色=不建议关闭。'
$lblMemHint.ForeColor = [System.Drawing.Color]::Gray
$grpMem.Controls.Add($lblMemHint)

$panelDonut = New-Object System.Windows.Forms.Panel
$panelDonut.Location = New-Object System.Drawing.Point(12, 46)
$panelDonut.Size = New-Object System.Drawing.Size(170, 150)
$panelDonut.BackColor = [System.Drawing.Color]::White
$panelDonut.BorderStyle = 'FixedSingle'
$grpMem.Controls.Add($panelDonut)

$gridMem = New-Object System.Windows.Forms.DataGridView
$gridMem.Location = New-Object System.Drawing.Point(190, 46)
$gridMem.Size = New-Object System.Drawing.Size(340, 120)
$gridMem.AllowUserToAddRows = $false
$gridMem.AllowUserToDeleteRows = $false
$gridMem.RowHeadersVisible = $false
$gridMem.SelectionMode = 'FullRowSelect'
$gridMem.AutoSizeColumnsMode = 'Fill'
$colClose = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
$colClose.HeaderText = '关闭'; $colClose.Name = 'colClose'; $colClose.Width = 40
$colName = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colName.HeaderText = '进程名'; $colName.Name = 'colName'; $colName.ReadOnly = $true
$colMb = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colMb.HeaderText = '内存MB'; $colMb.Name = 'colMb'; $colMb.ReadOnly = $true
$colImpact = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colImpact.HeaderText = '影响'; $colImpact.Name = 'colImpact'; $colImpact.ReadOnly = $true
[void]$gridMem.Columns.AddRange(@($colClose, $colName, $colMb, $colImpact))
$gridMem.AutoSizeColumnsMode = 'None'
$gridMem.Columns['colClose'].Width = 45
$gridMem.Columns['colName'].Width = 130
$gridMem.Columns['colMb'].Width = 70
$gridMem.Columns['colImpact'].AutoSizeMode = 'Fill'
$grpMem.Controls.Add($gridMem)

$btnRefreshMem = New-Object System.Windows.Forms.Button
$btnRefreshMem.Location = New-Object System.Drawing.Point(190, 170)
$btnRefreshMem.Size = New-Object System.Drawing.Size(90, 25)
$btnRefreshMem.Text = '🔄 刷新进程'
$grpMem.Controls.Add($btnRefreshMem)

$chkClearLog = New-Object System.Windows.Forms.CheckBox
$chkClearLog.Location = New-Object System.Drawing.Point(290, 172)
$chkClearLog.Size = New-Object System.Drawing.Size(160, 20)
$chkClearLog.Text = '游戏结束后自动清理日志'
$chkClearLog.Checked = $cfg.ClearLogAfterGame
$grpMem.Controls.Add($chkClearLog)

$script:MemSegments = @()
$gameNameForMem = if ($cfg.GameProcessName) { $cfg.GameProcessName } else { 'cs2' }

function Refresh-MemoryView {
    $bd = Get-MemoryBreakdown -GameName $gameNameForMem
    $segs = @()
    if ($bd.Game -gt 0) { $segs += [pscustomobject]@{ Name = "$gameNameForMem(游戏)"; Mb = $bd.Game; Proc = $gameNameForMem } }
    if ($bd.Plat -gt 0) { $segs += [pscustomobject]@{ Name = '完美世界平台'; Mb = $bd.Plat; Proc = '' } }
    $topOthers = $bd.Others | Select-Object -First 5
    foreach ($o in $topOthers) { $segs += [pscustomobject]@{ Name = $o.Name; Mb = $o.Mb; Proc = $o.Name } }
    $topMb = ($topOthers | Measure-Object Mb -Sum).Sum
    $restMb = (($bd.Others | Measure-Object Mb -Sum).Sum) - $topMb
    if ($restMb -gt 0) { $segs += [pscustomobject]@{ Name = '其他'; Mb = $restMb; Proc = '' } }
    $script:MemSegments = $segs
    $panelDonut.Invalidate()

    $gridMem.Rows.Clear()
    $killSet = @{}
    if ($cfg.GameKillApps) { foreach ($n in $cfg.GameKillApps) { $killSet[$n.ToLower()] = $true } }
    foreach ($o in $bd.Others) {
        if ($o.Mb -lt 20) { continue }
        $impact = Get-Impact $o.Name
        $row = $gridMem.Rows.Add()
        $gridMem.Rows[$row].Cells['colClose'].Value = [bool]$killSet.ContainsKey($o.Name.ToLower())
        $gridMem.Rows[$row].Cells['colName'].Value = $o.Name
        $gridMem.Rows[$row].Cells['colMb'].Value = [int]$o.Mb
        $gridMem.Rows[$row].Cells['colImpact'].Value = switch ($impact[0]) { 'safe' { '安全' } 'warn' { '慎用' } 'danger' { '禁止' } default { '未知' } }
        $color = switch ($impact[0]) { 'safe' { [System.Drawing.Color]::DarkGreen } 'warn' { [System.Drawing.Color]::DarkOrange } 'danger' { [System.Drawing.Color]::DarkRed } default { [System.Drawing.Color]::Gray } }
        $gridMem.Rows[$row].Cells['colImpact'].Style.ForeColor = $color
    }
}

$panelDonut.Add_Paint({
    param($s, $e)
    $g = $e.Graphics
    $g.SmoothingMode = 'AntiAlias'
    $rect = New-Object System.Drawing.Rectangle(12, 10, 146, 146)
    $total = ($script:MemSegments | Measure-Object Mb -Sum).Sum
    if ($total -le 0 -or $null -eq $script:MemSegments -or $script:MemSegments.Count -eq 0) {
        $g.DrawString('点击「刷新进程」', $font, [System.Drawing.Brushes]::Gray, 25, 70)
        return
    }
    $colors = @(
        [System.Drawing.Color]::FromArgb(76,175,80),
        [System.Drawing.Color]::FromArgb(33,150,243),
        [System.Drawing.Color]::FromArgb(255,152,0),
        [System.Drawing.Color]::FromArgb(156,39,176),
        [System.Drawing.Color]::FromArgb(244,67,54),
        [System.Drawing.Color]::FromArgb(96,125,139)
    )
    $start = 0.0
    for ($i = 0; $i -lt $script:MemSegments.Count; $i++) {
        $seg = $script:MemSegments[$i]
        $angle = 360.0 * $seg.Mb / $total
        if ($angle -lt 1) { continue }
        $brush = New-Object System.Drawing.SolidBrush($colors[$i % $colors.Count])
        $g.FillPie($brush, $rect, [float]$start, [float]$angle)
        $brush.Dispose()
        $start += $angle
    }
    $g.FillEllipse([System.Drawing.Brushes]::White, 40, 38, 90, 90)
    $totalFont = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $g.DrawString(("{0:N0}" -f $total) + " MB", $totalFont, [System.Drawing.Brushes]::Black, 42, 68)
    $g.DrawString('已用内存', $font, [System.Drawing.Brushes]::Gray, 48, 90)
    $totalFont.Dispose()
})

$btnRefreshMem.Add_Click({ Refresh-MemoryView })

# ---- 分组 4：高级设置 ----
$grpAdv = New-Object System.Windows.Forms.GroupBox
$grpAdv.Text = '④ 高级设置'
$grpAdv.Location = New-Object System.Drawing.Point(12, 566)
$grpAdv.Size = New-Object System.Drawing.Size(600, 130)
$form.Controls.Add($grpAdv)

$lblPlatCores = New-Object System.Windows.Forms.Label
$lblPlatCores.Location = New-Object System.Drawing.Point(12, 28)
$lblPlatCores.Size = New-Object System.Drawing.Size(150, 20)
$lblPlatCores.Text = '平台占用核数：'
$grpAdv.Controls.Add($lblPlatCores)

$numPlatCores = New-Object System.Windows.Forms.NumericUpDown
$numPlatCores.Location = New-Object System.Drawing.Point(165, 25)
$numPlatCores.Size = New-Object System.Drawing.Size(60, 23)
$numPlatCores.Minimum = 1
$numPlatCores.Maximum = 4
$numPlatCores.Value = $cfg.PlatCoresCount
$grpAdv.Controls.Add($numPlatCores)

$lblPlatCoresHint = New-Object System.Windows.Forms.Label
$lblPlatCoresHint.Location = New-Object System.Drawing.Point(235, 28)
$lblPlatCoresHint.Size = New-Object System.Drawing.Size(250, 18)
$lblPlatCoresHint.Text = '（游戏会用剩余的核）'
$lblPlatCoresHint.ForeColor = [System.Drawing.Color]::Gray
$grpAdv.Controls.Add($lblPlatCoresHint)

$lblInterval = New-Object System.Windows.Forms.Label
$lblInterval.Location = New-Object System.Drawing.Point(12, 58)
$lblInterval.Size = New-Object System.Drawing.Size(150, 20)
$lblInterval.Text = '巡检间隔(ms)：'
$grpAdv.Controls.Add($lblInterval)

$numInterval = New-Object System.Windows.Forms.NumericUpDown
$numInterval.Location = New-Object System.Drawing.Point(165, 55)
$numInterval.Size = New-Object System.Drawing.Size(80, 23)
$numInterval.Minimum = 500
$numInterval.Maximum = 10000
$numInterval.Increment = 500
$numInterval.Value = $cfg.IntervalMs
$grpAdv.Controls.Add($numInterval)

$lblLogMax = New-Object System.Windows.Forms.Label
$lblLogMax.Location = New-Object System.Drawing.Point(280, 58)
$lblLogMax.Size = New-Object System.Drawing.Size(110, 20)
$lblLogMax.Text = '日志上限(MB)：'
$grpAdv.Controls.Add($lblLogMax)

$numLogMax = New-Object System.Windows.Forms.NumericUpDown
$numLogMax.Location = New-Object System.Drawing.Point(393, 55)
$numLogMax.Size = New-Object System.Drawing.Size(70, 23)
$numLogMax.Minimum = 1
$numLogMax.Maximum = 200
$numLogMax.Value = $cfg.LogMaxMb
$grpAdv.Controls.Add($numLogMax)

$lblNote = New-Object System.Windows.Forms.Label
$lblNote.Location = New-Object System.Drawing.Point(12, 92)
$lblNote.Size = New-Object System.Drawing.Size(555, 30)
$lblNote.Text = '提示：如果你的电脑核数较少（≤4核），建议把平台核数设为 1，让游戏获得更多 CPU。'
$lblNote.ForeColor = [System.Drawing.Color]::FromArgb(180, 100, 0)
$lblNote.Font = New-Object System.Drawing.Font('Segoe UI', 8)
$grpAdv.Controls.Add($lblNote)

# ---- 底部按钮 ----
$btnSave = New-Object System.Windows.Forms.Button
$btnSave.Location = New-Object System.Drawing.Point(360, 712)
$btnSave.Size = New-Object System.Drawing.Size(110, 34)
$btnSave.Text = '💾 保存并启动'
$btnSave.BackColor = [System.Drawing.Color]::FromArgb(76, 175, 80)
$btnSave.ForeColor = [System.Drawing.Color]::White
$btnSave.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($btnSave)

$btnCancel = New-Object System.Windows.Forms.Button
$btnCancel.Location = New-Object System.Drawing.Point(480, 712)
$btnCancel.Size = New-Object System.Drawing.Size(100, 34)
$btnCancel.Text = '取消'
$form.Controls.Add($btnCancel)

$btnDefaults = New-Object System.Windows.Forms.Button
$btnDefaults.Location = New-Object System.Drawing.Point(20, 712)
$btnDefaults.Size = New-Object System.Drawing.Size(100, 34)
$btnDefaults.Text = '恢复默认'
$form.Controls.Add($btnDefaults)

$btnOpenFolder = New-Object System.Windows.Forms.Button
$btnOpenFolder.Location = New-Object System.Drawing.Point(130, 712)
$btnOpenFolder.Size = New-Object System.Drawing.Size(110, 34)
$btnOpenFolder.Text = '打开脚本目录'
$form.Controls.Add($btnOpenFolder)

# ---- 底部链接/帮助 ----
$lblFooter = New-Object System.Windows.Forms.Label
$lblFooter.Location = New-Object System.Drawing.Point(12, 758)
$lblFooter.Size = New-Object System.Drawing.Size(600, 20)
$lblFooter.Text = "配置文件保存在：$ConfigPath"
$lblFooter.ForeColor = [System.Drawing.Color]::Gray
$lblFooter.Font = New-Object System.Drawing.Font('Segoe UI', 8)
$form.Controls.Add($lblFooter)

# ------------------------------------------------------------------
# 按钮事件
# ------------------------------------------------------------------
$btnSave.Add_Click({
    # 校验
    if ([string]::IsNullOrWhiteSpace($txtPlatPath.Text)) {
        [System.Windows.Forms.MessageBox]::Show('请填写平台 exe 路径，或点击"自动探测"。', '缺少配置', 'OK', 'Warning')
        return
    }
    if (-not (Test-Path -LiteralPath $txtPlatPath.Text)) {
        [System.Windows.Forms.MessageBox]::Show("平台路径不存在：`n$($txtPlatPath.Text)", '路径错误', 'OK', 'Error')
        return
    }
    if ([string]::IsNullOrWhiteSpace($txtGameName.Text)) {
        [System.Windows.Forms.MessageBox]::Show('请填写游戏进程名。', '缺少配置', 'OK', 'Warning')
        return
    }
    if ($cmbAffinity.SelectedIndex -eq 2 -and [string]::IsNullOrWhiteSpace($txtCustomMask.Text)) {
        [System.Windows.Forms.MessageBox]::Show('自定义模式请填写十六进制掩码（如 FFFC）。', '缺少掩码', 'OK', 'Warning')
        return
    }

    $killApps = @()
    foreach ($row in $gridMem.Rows) {
        if ($row.Cells['colClose'].Value -eq $true -and $row.Cells['colName'].Value) {
            $killApps += [string]$row.Cells['colName'].Value
        }
    }

    $newCfg = [ordered]@{
        PlatformPath        = $txtPlatPath.Text.Trim()
        GameProcessName     = $txtGameName.Text.Trim().ToLower()
        Cs2Affinity         = switch ($cmbAffinity.SelectedIndex) { 0 { 'Exclude01' } 1 { 'All' } 2 { 'Custom' } }
        CustomMask          = $txtCustomMask.Text.Trim().ToUpper()
        Cs2Priority         = switch ($cmbPriority.SelectedIndex) { 0 { 'AboveNormal' } 1 { 'High' } 2 { 'Normal' } }
        PlatCoresCount      = [int]$numPlatCores.Value
        IntervalMs          = [int]$numInterval.Value
        AutoLaunchPlatform  = $chkAutoLaunch.Checked
        LogMaxMb            = [int]$numLogMax.Value
        PlatNamesExtra      = @()
        SteamNamesExtra     = @()
        GameKillApps        = $killApps
        ClearLogAfterGame   = $chkClearLog.Checked
        ShowMemoryHud       = $false
    }
    Save-Config -Cfg $newCfg

    $script:SaveResult = $true
    $script:SavedConfig = $newCfg
    $form.DialogResult = 'OK'
    $form.Close()
})

$btnCancel.Add_Click({
    $script:SaveResult = $false
    $form.DialogResult = 'Cancel'
    $form.Close()
})

$btnDefaults.Add_Click({
    if ([System.Windows.Forms.MessageBox]::Show('确定恢复所有默认值？', '恢复默认', 'YesNo', 'Question') -eq 'Yes') {
        $cfg = New-DefaultConfig
        $txtPlatPath.Text = ''
        $txtGameName.Text = $cfg.GameProcessName
        $cmbAffinity.SelectedIndex = 0
        $txtCustomMask.Text = ''
        $txtCustomMask.Enabled = $false
        $cmbPriority.SelectedIndex = 0
        $numPlatCores.Value = $cfg.PlatCoresCount
        $numInterval.Value = $cfg.IntervalMs
        $chkAutoLaunch.Checked = $cfg.AutoLaunchPlatform
        $numLogMax.Value = $cfg.LogMaxMb
        $chkClearLog.Checked = $cfg.ClearLogAfterGame
        $gridMem.Rows.Clear()
        $script:MemSegments = @()
        $panelDonut.Invalidate()
    }
})

$btnOpenFolder.Add_Click({
    Start-Process explorer.exe -ArgumentList '/select,"' + $ConfigPath + '"'
})

# ------------------------------------------------------------------
# 显示窗体
# ------------------------------------------------------------------
$script:SaveResult = $false
$script:SavedConfig = $null
$form.Add_Shown({ Refresh-MemoryView })
[void]$form.ShowDialog()

if ($script:SaveResult -and $script:SavedConfig) {
    # 把配置作为输出返回（供主脚本调用时使用）
    $script:SavedConfig
}
