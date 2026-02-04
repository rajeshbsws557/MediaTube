@echo off
echo ================================================
echo   MediaTube Java Server (NewPipe Extractor)
echo ================================================
echo.
echo Starting server on port 5000...
echo.

cd /d "%~dp0"
call jbang-0.116.0\bin\jbang.cmd run SimpleServer.java

pause
