@echo off
rem Builds GelScribe-Windows.zip (GelScribe.exe, the app, and gelscribe-cli.exe, the command-line tool) on Windows.
rem Double-click it. It never touches the Pythons you have: it makes its own Python in build\venv, installs what
rem GelScribe needs there, runs PyInstaller with build\GelScribe.spec, and zips the result into dist\GelScribe-Windows.zip.
rem The first build downloads Qt and PyInstaller and takes a few minutes; later builds reuse build\venv.
setlocal
set "PIP_USER=0"
set "PIP_DISABLE_PIP_VERSION_CHECK=1"
set "PIP_REQUIRE_VIRTUALENV="
set "PYTHONSAFEPATH=1"
set "PYTHONUTF8=1"
set "PY="
rem pushd, not cd: it also works from a network folder, and from a folder with spaces or non-ASCII letters in its name
pushd "%~dp0" || goto nofolder
if not exist "gelscribe\__init__.py" goto incomplete
if not exist "requirements.txt" goto incomplete
if not exist "build\GelScribe.spec" goto incomplete

echo Building GelScribe for Windows. The first time takes a few minutes.
echo.

rem a private Python for the build, made from Python 3.11 to 3.14 (what GelScribe supports)
if exist "build\venv\Scripts\python.exe" call :checkvenv
if exist "build\venv\Scripts\python.exe" goto havevenv
call :findpython
if not defined PY goto nopython
echo [1/4] Making a private build Python in python\build\venv, from: %PY%
%PY% -m venv "build\venv" || goto failed
:havevenv
set "VPY=build\venv\Scripts\python.exe"

echo [2/4] Installing GelScribe's requirements and PyInstaller into build\venv only.
"%VPY%" -m pip install --upgrade pip >nul 2>nul
"%VPY%" -m pip install -r "requirements.txt" pyinstaller || goto failed

echo.
echo [3/4] Building with PyInstaller.
if exist "dist\GelScribe" rmdir /s /q "dist\GelScribe"
"%VPY%" -m PyInstaller --noconfirm --clean --workpath "build\work" --distpath "dist" "build\GelScribe.spec" || goto failed
if not exist "dist\GelScribe\GelScribe.exe" goto failed
if not exist "dist\GelScribe\gelscribe-cli.exe" goto failed
"dist\GelScribe\gelscribe-cli.exe" --version || goto failed

echo.
echo [4/4] Zipping.
if exist "dist\GelScribe-Windows.zip" del /q "dist\GelScribe-Windows.zip"
powershell -NoProfile -ExecutionPolicy Bypass -Command "Compress-Archive -Path 'dist\GelScribe' -DestinationPath 'dist\GelScribe-Windows.zip' -Force" || goto failed
if not exist "dist\GelScribe-Windows.zip" goto failed

echo.
echo Done. The zip is here:
echo   %CD%\dist\GelScribe-Windows.zip
echo The unzipped program is in %CD%\dist\GelScribe: run GelScribe.exe from there to try it.
echo To share it, upload the zip to the GitHub release.
popd
call :pause %*
exit /b 0

:findpython
rem the first Python 3.11 to 3.14 found: python.org's py launcher (newest wanted first), PATH, then conda
call :try py -3.13
call :try py -3.12
call :try py -3.14
call :try py -3.11
call :try py -3
call :try python
call :try python3
if defined CONDA_PREFIX call :try "%CONDA_PREFIX%\python.exe"
for %%D in ("%USERPROFILE%\miniconda3" "%USERPROFILE%\anaconda3" "%USERPROFILE%\miniforge3" "%LOCALAPPDATA%\miniconda3" "%ProgramData%\miniconda3") do call :try "%%~D\python.exe"
exit /b 0

:try
if defined PY exit /b 0
%* -c "import sys; sys.exit(0 if (3, 11) <= sys.version_info[:2] <= (3, 14) else 1)" >nul 2>nul && set "PY=%*"
exit /b 0

:checkvenv
rem a build\venv that no longer runs (its Python was uninstalled) or is too old or new is made again
"build\venv\Scripts\python.exe" -c "import sys; sys.exit(0 if (3, 11) <= sys.version_info[:2] <= (3, 14) else 1)" >nul 2>nul && exit /b 0
echo The Python in build\venv doesn't work any more, making it again.
rmdir /s /q "build\venv"
exit /b 0

:pause
rem build-exe.bat /nopause skips the wait, for running it from a script
if /i not "%~1"=="/nopause" pause
exit /b 0

:nopython
echo No Python 3.11 to 3.14 was found (looked for python.org's py launcher, python on PATH, and conda).
echo Get Python 3.13 from https://www.python.org/downloads/ and on the installer's first screen tick
echo "Add python.exe to PATH". Your own Pythons are only read, never changed. Then double-click build-exe.bat again.
goto stop

:failed
echo.
echo The build didn't finish (the reason is above). If a download failed, check the internet connection.
echo For a clean start, delete the python\build\venv and python\build\work folders and try again.
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
