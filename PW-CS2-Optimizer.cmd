@echo off
setlocal
title PW / Game Optimizer

set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "SCRIPT=%~dp0PW-CS2-Optimizer.ps1"
set "CONFIG=%~dp0PW-CS2-Optimizer.config.json"
set "UI=%~dp0PW-CS2-Optimizer-UI.ps1"

rem ============================================================
rem 双击行为：
rem   - 如果 config.json 存在 → 直接启动优化器（管理员）
rem   - 如果 config.json 不存在 → 弹配置向导，保存后启动
rem   - 如果用户按住 SHIFT 双击 → 强制弹配置向导
rem ============================================================

rem Shift 键检测（通过 PowerShell）
"%PS%" -NoProfile -Command "if ([System.Windows.Forms.Control]::ModifierKeys -band [System.Windows.Forms.Keys]::Shift) { exit 42 } else { exit 0 }"
if %errorlevel%==42 goto show_config

rem 单实例检查（不提权，能发现旧实例就激活窗口）
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -CheckOnly
if %errorlevel%==42 (
    echo 已有脚本在运行，已切换到该窗口。
    timeout /t 2 >nul
    exit /b
)

rem 如果没有配置文件，先弹配置向导
if not exist "%CONFIG%" goto show_config
goto ensure_admin

:show_config
echo.
echo  ============================================
echo    PW / Game Optimizer - 配置向导
echo  ============================================
echo.
"%PS%" -NoProfile -ExecutionPolicy Bypass -STA -File "%UI%" -ConfigPath "%CONFIG%"
if not exist "%CONFIG%" (
    echo.
    echo 配置未保存，脚本退出。
    pause
    exit /b
)
echo.
echo 配置已保存，即将启动优化器...
echo.

:ensure_admin
net session >nul 2>&1
if %errorlevel%==0 goto run
echo Requesting administrator privileges...
"%PS%" -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
exit /b

:run
cd /d "%~dp0"
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
if errorlevel 1 pause
exit /b
