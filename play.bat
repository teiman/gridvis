@echo off
rem Opens the test map in ironwail with the gridvis mod.
rem   play.bat [vis|grid] [static]    (default grid)
rem   static: monsters are static entities (culled by the client, not the server)
rem Video: a normal 1280x720 window (screen recorders can capture it).
rem   set GV_VIDEO=borderless   -> a borderless window the size of the screen (best for capturing)
rem   set GV_SIZE=2560 1440     -> its size, if the screen is not 1920x1080
rem Run compile.bat and mod\build.bat first.
setlocal
set QUAKE=D:\quake
set GAME=gridvis
set VARIANT=%~1
if "%VARIANT%"=="" set VARIANT=grid
set STATIC=0
if /i "%~2"=="static" set STATIC=1

set VIDEO=+vid_fullscreen 0 +vid_desktopfullscreen 0 +vid_borderless 0 +vid_width 1280 +vid_height 720 +vid_restart
if not defined GV_SIZE set GV_SIZE=1920 1080
for /f "tokens=1,2" %%a in ("%GV_SIZE%") do (
    if /i "%GV_VIDEO%"=="borderless" set VIDEO=+vid_fullscreen 0 +vid_desktopfullscreen 0 +vid_borderless 1 +vid_width %%a +vid_height %%b +vid_restart
)

if not exist "%QUAKE%\%GAME%\maps\gridtest_%VARIANT%.bsp" (
    echo Missing %QUAKE%\%GAME%\maps\gridtest_%VARIANT%.bsp: run compile.bat
    exit /b 1
)

cd /d "%QUAKE%"
start "" "%QUAKE%\ironwail.exe" -basedir "%QUAKE%" -game %GAME% %VIDEO% +scratch2 %STATIC% +scratch3 0 +scratch4 0 +map gridtest_%VARIANT%
