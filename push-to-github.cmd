@echo off
rem ============================================================
rem  一键推送到 GitHub
rem  等网络通了（Clash 开系统代理 + TUN 模式），双击这个文件
rem ============================================================
setlocal
set "GIT=C:\Program Files\Git\cmd\git.exe"
set "DIR=%~dp0"

cd /d "%DIR%"

"%GIT%" remote -v | findstr "cswd40" >nul 2>&1
if errorlevel 1 (
    echo [首次推送] 设置远程仓库...
    "%GIT%" remote add origin https://github.com/Wzq-S/cswd40.git
) else (
    echo [检测到已有远程仓库配置]
)

echo.
echo 正在推送到 GitHub...
echo.
"%GIT%" push -u origin master

if errorlevel 1 (
    echo.
    echo [失败] 网络不通或需要认证。
    echo.
    echo 如果提示输入用户名/密码：
    echo   - 用户名填你的 GitHub 用户名
    echo   - 密码位置要用 Personal Access Token（不是 GitHub 登录密码！）
    echo   - 创建 Token: github.com -^> Settings -^> Developer settings -^> Personal access tokens -^> Tokens (classic)
    echo   - 权限选 "repo" 即可
    echo.
    echo 如果提示网络错误：
    echo   - 检查 Clash/v2rayN 是否开了 "TUN 模式" 或 "系统代理"
    echo   - 或者试试开启代理后再运行
    echo.
    pause
) else (
    echo.
    echo [成功!] 打开浏览器访问:
    echo   https://github.com/Wzq-S/cswd40
    echo.
    pause
)
