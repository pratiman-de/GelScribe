@echo off
rem Builds GelScribe-Windows.zip (GelScribe.exe, the app, and gelscribe-cli.exe, the command-line tool) on Windows,
rem and GelScribe-Setup.exe, an installer, when Inno Setup 6 is installed.
rem Double-click it. It gets its own Python and never touches any other Python on the PC (Anaconda can't build the
rem .exe: its copies of Windows DLLs clash with Qt's). On the first run it downloads python.org's official Python 3.13
rem (the NuGet package, about 30 MB) into build\python, installs what GelScribe needs plus PyInstaller into it, runs
rem PyInstaller with build\GelScribe.spec, and zips the result into dist\GelScribe-Windows.zip.
rem Then, if Inno Setup 6 (free, https://jrsoftware.org/isdl.php) is installed, it makes dist\GelScribe-Setup.exe with build\GelScribe.iss.
rem The first build downloads Python, Qt and PyInstaller and takes a few minutes; later builds reuse build\python.
setlocal
set "PIP_USER=0"
set "PIP_DISABLE_PIP_VERSION_CHECK=1"
set "PIP_REQUIRE_VIRTUALENV="
set "PYTHONNOUSERSITE=1"
set "PYTHONSAFEPATH=1"
set "PYTHONUTF8=1"
set "SETUP="
rem pushd, not cd: it also works from a network folder, and from a folder with spaces or non-ASCII letters in its name
pushd "%~dp0" || goto nofolder
if not exist "gelscribe\__init__.py" goto incomplete
if not exist "requirements.txt" goto incomplete
if not exist "build\GelScribe.spec" goto incomplete

echo Building GelScribe for Windows. The first time takes a few minutes.
echo.

rem the build Python is python.org's official Python from NuGet, in build\python: no venv, no other Python on the PC is used
set "VPY=build\python\tools\python.exe"
if exist "build\venv" echo build\venv is no longer used by this script and can be deleted.
if exist "%VPY%" echo [1/5] Python is already in build\python.
if not exist "%VPY%" call :getpython
if not exist "%VPY%" goto nopython

echo [2/5] Installing GelScribe's requirements and PyInstaller into build\python only.
"%VPY%" -m pip --version >nul 2>nul
if errorlevel 1 "%VPY%" -m ensurepip --upgrade >nul
"%VPY%" -m pip --version >nul 2>nul
if errorlevel 1 goto failed
"%VPY%" -m pip install --upgrade pip >nul 2>nul
"%VPY%" -m pip install -r "requirements.txt" pyinstaller || goto failed

echo.
echo [3/5] Building with PyInstaller.
if exist "dist\GelScribe" rmdir /s /q "dist\GelScribe"
"%VPY%" -m PyInstaller --noconfirm --clean --workpath "build\work" --distpath "dist" "build\GelScribe.spec" || goto failed
if not exist "dist\GelScribe\GelScribe.exe" goto failed
if not exist "dist\GelScribe\gelscribe-cli.exe" goto failed
"dist\GelScribe\gelscribe-cli.exe" --version || goto failed

echo.
echo [4/5] Zipping.
if exist "dist\GelScribe-Windows.zip" del /q "dist\GelScribe-Windows.zip"
powershell -NoProfile -ExecutionPolicy Bypass -Command "Compress-Archive -Path 'dist\GelScribe' -DestinationPath 'dist\GelScribe-Windows.zip' -Force" || goto failed
if not exist "dist\GelScribe-Windows.zip" goto failed

echo.
echo [5/5] Making the installer.
call :installer

echo.
echo Done. The zip is here:
echo   %CD%\dist\GelScribe-Windows.zip
if defined SETUP echo The installer is here:
if defined SETUP echo   %SETUP%
echo The unzipped program is in %CD%\dist\GelScribe: run GelScribe.exe from there to try it.
echo To share it, upload the installer and the zip to the GitHub release.
popd
call :pause %*
exit /b 0

:installer
rem Inno Setup 6 is only read, never changed. Without it, or if it fails, the zip is still made and this build still succeeds.
set "ISCC="
if exist "%ProgramFiles(x86)%\Inno Setup 6\ISCC.exe" set "ISCC=%ProgramFiles(x86)%\Inno Setup 6\ISCC.exe"
if not defined ISCC if exist "%ProgramFiles%\Inno Setup 6\ISCC.exe" set "ISCC=%ProgramFiles%\Inno Setup 6\ISCC.exe"
if not defined ISCC if exist "%LOCALAPPDATA%\Programs\Inno Setup 6\ISCC.exe" set "ISCC=%LOCALAPPDATA%\Programs\Inno Setup 6\ISCC.exe"
if not defined ISCC goto noinno
if not exist "build\GelScribe.iss" goto noiss
rem the version, read from gelscribe\__init__.py by the build Python (a file, not for /f, to avoid cmd's quote rules)
set "VER="
if not exist "build\work" mkdir "build\work"
"%VPY%" -c "import sys; sys.path.insert(0, '.'); from gelscribe import __version__; print(__version__)" >"build\work\version.txt" 2>nul
if not errorlevel 1 set /p VER=<"build\work\version.txt"
if not defined VER goto nover
if exist "dist\GelScribe-Setup.exe" del /q "dist\GelScribe-Setup.exe"
"%ISCC%" /Qp "/DMyAppVersion=%VER%" "build\GelScribe.iss"
if errorlevel 1 goto isccfailed
if not exist "dist\GelScribe-Setup.exe" goto isccfailed
set "SETUP=%CD%\dist\GelScribe-Setup.exe"
exit /b 0

:noinno
echo To make GelScribe-Setup.exe, install Inno Setup 6 (free, https://jrsoftware.org/isdl.php) and run this again. The zip was made anyway.
exit /b 0

:noiss
echo build\GelScribe.iss is missing, so there is no installer. The zip was made anyway.
exit /b 0

:nover
echo Couldn't read the version from gelscribe\__init__.py, so there is no installer. The zip was made anyway.
exit /b 0

:isccfailed
echo Inno Setup didn't make GelScribe-Setup.exe (the reason is above). The zip was made anyway.
exit /b 0

:getpython
rem downloads python.org's official Python once; a half-finished earlier try is removed first
if exist "build\python.zip" del /q "build\python.zip"
if exist "build\python" rmdir /s /q "build\python"
powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; $ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'; try { $v = (Invoke-RestMethod -UseBasicParsing 'https://api.nuget.org/v3-flatcontainer/python/index.json').versions | Where-Object { $_ -notmatch '-' -and $_ -match '^3\.13\.[0-9.]+$' } | Sort-Object { [version]$_ } | Select-Object -Last 1; if (-not $v) { throw 'no stable Python 3.13 version found on NuGet' }; Write-Host ('[1/5] Getting Python ' + $v + ' from python.org''s NuGet package into build\python (once).'); Invoke-WebRequest -UseBasicParsing ('https://api.nuget.org/v3-flatcontainer/python/' + $v + '/python.' + $v + '.nupkg') -OutFile 'build\python.zip'; Expand-Archive -Path 'build\python.zip' -DestinationPath 'build\python' -Force; Remove-Item 'build\python.zip' -Force } catch { Write-Host ('Download failed: ' + $_.Exception.Message); exit 1 }"
if errorlevel 1 exit /b 1
if exist "build\python.zip" del /q "build\python.zip"
exit /b 0

:pause
rem build-exe.bat /nopause skips the wait, for running it from a script
if /i not "%~1"=="/nopause" pause
exit /b 0

:nopython
echo.
echo Couldn't get Python from python.org (the reason is above). Is the PC connected to the internet?
echo A firewall or proxy may be blocking api.nuget.org. Check the connection and double-click build-exe.bat again.
echo No other Python on the PC is used, so nothing else is needed. If python.exe is missing in build\python\tools,
echo delete the python\build\python folder and try again.
goto stop

:failed
echo.
echo The build didn't finish (the reason is above). If a download failed, check the internet connection.
echo For a clean start, delete the python\build\python and python\build\work folders and try again.
goto stop

:incomplete
echo The build files aren't all here (gelscribe, requirements.txt or build\GelScribe.spec is missing).
echo If you opened build-exe.bat inside a zip, close it, right-click the zip, choose Extract All, and open it in the new folder.
goto stop

:nofolder
echo build-exe.bat can't open the folder it is in. If that is a network drive, check that it is connected.
call :pause %*
exit /b 1

:stop
popd
call :pause %*
exit /b 1
