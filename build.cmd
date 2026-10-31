@echo off
chcp 65001 >nul
setlocal

set CSC=%SystemRoot%\Microsoft.NET\Framework64\v4.0.30319\csc.exe
if not exist "%CSC%" set CSC=%SystemRoot%\Microsoft.NET\Framework\v4.0.30319\csc.exe

if not exist "%CSC%" (
    echo [ERROR] csc.exe not found. .NET Framework 4.x is required.
    pause
    exit /b 1
)

echo Building cs2wd-40.exe ...
"%CSC%" /nologo /target:winexe /out:cs2wd-40.exe ^
  /win32manifest:src\app.manifest /win32icon:src\app.ico /optimize ^
  /r:System.dll /r:System.Core.dll /r:System.Windows.Forms.dll ^
  /r:System.Drawing.dll /r:System.Management.dll /r:System.Runtime.Serialization.dll ^
  src\PW-CS2-Optimizer.cs src\MainForm.cs src\SettingsForm.cs

if errorlevel 1 (
    echo.
    echo [FAILED] Build failed.
    pause
    exit /b 1
)

echo.
echo [OK] cs2wd-40.exe built successfully.
pause
