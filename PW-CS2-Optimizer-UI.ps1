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
}

function Load-Config {
    if (Test-Path -LiteralPath $ConfigPath) {
        try {
            $raw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
            $cfg = $raw | ConvertFrom-Json -AsHashtable
            # 合并默认值（新字段有兜底）
            $merged = [ordered]@{}
            foreach ($k in $DefaultConfig.Keys) {
                if ($cfg.ContainsKey($k) -and $null -ne $cfg[$k]) {
                    $merged[$k] = $cfg[$k]
                } else {
                    $merged[$k] = $DefaultConfig[$k]
                }
            }
            return $merged
        } catch {
            return $DefaultConfig.Clone()
        }
    }
    return $DefaultConfig.Clone()
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
# 构建窗体
# ------------------------------------------------------------------
$cfg = Load-Config

$form = New-Object System.Windows.Forms.Form
$form.Text = 'PW / CS2 Optimizer - 配置向导'
$form.Size = New-Object System.Drawing.Size(620, 680)
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

# ---- 分组 3：高级设置 ----
$grpAdv = New-Object System.Windows.Forms.GroupBox
$grpAdv.Text = '③ 高级设置'
$grpAdv.Location = New-Object System.Drawing.Point(12, 362)
$grpAdv.Size = New-Object System.Drawing.Size(580, 130)
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
$btnSave.Location = New-Object System.Drawing.Point(340, 510)
$btnSave.Size = New-Object System.Drawing.Size(100, 34)
$btnSave.Text = '💾 保存并启动'
$btnSave.BackColor = [System.Drawing.Color]::FromArgb(76, 175, 80)
$btnSave.ForeColor = [System.Drawing.Color]::White
$btnSave.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($btnSave)

$btnCancel = New-Object System.Windows.Forms.Button
$btnCancel.Location = New-Object System.Drawing.Point(455, 510)
$btnCancel.Size = New-Object System.Drawing.Size(100, 34)
$btnCancel.Text = '取消'
$form.Controls.Add($btnCancel)

$btnDefaults = New-Object System.Windows.Forms.Button
$btnDefaults.Location = New-Object System.Drawing.Point(20, 510)
$btnDefaults.Size = New-Object System.Drawing.Size(100, 34)
$btnDefaults.Text = '恢复默认'
$form.Controls.Add($btnDefaults)

$btnOpenFolder = New-Object System.Windows.Forms.Button
$btnOpenFolder.Location = New-Object System.Drawing.Point(135, 510)
$btnOpenFolder.Size = New-Object System.Drawing.Size(100, 34)
$btnOpenFolder.Text = '打开脚本目录'
$form.Controls.Add($btnOpenFolder)

# ---- 底部链接/帮助 ----
$lblFooter = New-Object System.Windows.Forms.Label
$lblFooter.Location = New-Object System.Drawing.Point(12, 555)
$lblFooter.Size = New-Object System.Drawing.Size(580, 20)
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
        $cfg = $DefaultConfig.Clone()
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
[void]$form.ShowDialog()

if ($script:SaveResult -and $script:SavedConfig) {
    # 把配置作为输出返回（供主脚本调用时使用）
    $script:SavedConfig
}
