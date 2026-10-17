@echo off
rem Starts Ascella with a console window: the launcher for when something is
rem wrong and you want to read what the program says. Ascella.exe beside this
rem file is the one to double-click otherwise.
rem
rem The data goes where Ascella.exe puts it, outside this folder, so that a
rem new version unzipped beside the old one finds it: see "Where your data
rem lives" in the README. ASCELLA_DATA, when it is set, is left alone.
setlocal
if "%ASCELLA_DATA%"=="" set ASCELLA_DATA=%LOCALAPPDATA%\AscellaData
if "%PORT%"=="" set PORT=4090
rem What the release writes when it starts goes beside the data, not in here.
if "%RELEASE_TMP%"=="" set RELEASE_TMP=%ASCELLA_DATA%\tmp
rem Erlang distribution off (see rel/env.bat.eex). `set
rem RELEASE_DISTRIBUTION=sname` before this file gives a node that
rem `bin\ascella.bat remote` can attach to, for one session.
if "%RELEASE_DISTRIBUTION%"=="" set RELEASE_DISTRIBUTION=none
echo Starting Ascella on http://localhost:%PORT%
echo Data: %ASCELLA_DATA%
echo Close this window to stop it. The programs it started keep running.
echo.
"%~dp0bin\ascella.bat" start
endlocal
