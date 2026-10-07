@echo off
rem Builds the test map twice from the same .map and copies both to the game dir:
rem   testmap\gridtest_vis.bsp   qbsp + light + vis
rem   testmap\gridtest_grid.bsp  qbsp + light + gridvis
rem Both share the same qbsp output, so the leafs are identical and only the visdata differs.
rem   compile.bat
rem   set GRIDVIS_ARGS=-rectx 3328 -recty 1536 -offsety 464 -margin 128   (footprint, see gridvis.md)
rem   set MAP_ARGS=--size 4000 --grid 512                                (tools\makemap.py options)
setlocal
set ROOT=%~dp0
set T=%ROOT%ericw-tools\build-windows
set DEST=D:\quake\gridvis
set MAP=gridtest
if not defined GRIDVIS_ARGS set GRIDVIS_ARGS=-rectx 3328 -recty 1536 -offsety 464 -margin 128

cd /d "%ROOT%testmap" || exit /b 1
set ERICW_BENCH=1

echo [compile] makemap %MAP_ARGS%
python "%ROOT%tools\makemap.py" %MAP%.map %MAP_ARGS% || exit /b 1

echo [compile] qbsp
"%T%\qbsp\Release\qbsp.exe" -nocolor -bsp2 %MAP% >qbsp_last.txt || (type qbsp_last.txt & exit /b 1)

echo [compile] light
"%T%\light\Release\vklight.exe" -nocolor %MAP% >light_last.txt || (type light_last.txt & exit /b 1)

for %%V in (vis grid) do (
    copy /y %MAP%.bsp %MAP%_%%V.bsp >nul
    if exist %MAP%.lit (copy /y %MAP%.lit %MAP%_%%V.lit >nul) else (del /q %MAP%_%%V.lit 2>nul)
)
copy /y %MAP%.prt %MAP%_vis.prt >nul

echo [compile] vis
"%T%\vis\Release\vis.exe" -nocolor %MAP%_vis >vis_last.txt || (type vis_last.txt & exit /b 1)
findstr /c:"average leafs visible" vis_last.txt

echo [compile] gridvis %GRIDVIS_ARGS%
"%T%\gridvis\Release\gridvis.exe" -nocolor -stats %GRIDVIS_ARGS% %MAP%_grid >gridvis_last.txt || (type gridvis_last.txt & exit /b 1)
findstr /c:"average leafs visible" /c:"WARNING" gridvis_last.txt

if not exist "%DEST%\maps" mkdir "%DEST%\maps"
for %%V in (vis grid) do (
    copy /y %MAP%_%%V.bsp "%DEST%\maps\" >nul
    if exist %MAP%_%%V.lit (copy /y %MAP%_%%V.lit "%DEST%\maps\" >nul) else (del /q "%DEST%\maps\%MAP%_%%V.lit" 2>nul)
)
echo [compile] OK -^> %DEST%\maps\%MAP%_vis.bsp, %MAP%_grid.bsp
