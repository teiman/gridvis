@echo off
rem Compiles the test mod (QuakeC, fteqcc) and copies progs.dat to the game dir.
rem   mod\build.bat
setlocal
set ROOT=%~dp0
set DEST=D:\quake\gridvis

cd /d "%ROOT%src" || exit /b 1
"%ROOT%bin\fteqcc64.exe" >"%ROOT%qcc_last.txt" 2>&1
if errorlevel 1 (
    type "%ROOT%qcc_last.txt"
    echo [mod] FAILED
    exit /b 1
)

if not exist "%DEST%" mkdir "%DEST%"
copy /y "%ROOT%progs.dat" "%DEST%\progs.dat" >nul
echo [mod] OK -^> %DEST%\progs.dat
