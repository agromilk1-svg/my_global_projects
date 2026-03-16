@echo off
setlocal

:: === ECWDA Clean Start (Windows) ===
echo Cleaning proxy environment variables...

set "http_proxy="
set "https_proxy="
set "all_proxy="
set "HTTP_PROXY="
set "HTTPS_PROXY="
set "ALL_PROXY="

:: 设置 no_proxy (Windows 下 requests 也遵循此变量)
set "no_proxy=localhost,127.0.0.1,::1,user.ecmain.site"
set "NO_PROXY=localhost,127.0.0.1,::1,user.ecmain.site"

echo Current Proxy Env (Should be empty or clean):
echo no_proxy=%no_proxy%
echo ----------------------

echo Starting Control Center...
python control_center.py

endlocal
pause
