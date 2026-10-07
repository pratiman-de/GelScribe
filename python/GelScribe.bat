@echo off
rem GelScribe for Windows. Double-click to start, or drop an image on this file.
rem The first start picks the Python GelScribe runs from (gelscribe\bootstrap.py): one you already have, if it has
rem everything GelScribe needs, or else a small private one made in the .venv folder here. The choice is in python.txt.
rem With a command first it's the command-line tool, in this console: GelScribe render blot.gelscribe, GelScribe help.
setlocal
set "MODE=app"
for %%C in (new edit render detect presets verify help -h --help --version) do if /i "%~1"=="%%C" set "MODE=cli"
set "HERE=%~dp0"
rem pushd, not cd: it also works from a network folder (\\server\share\...), which cd can't enter
pushd "%HERE%" || goto nofolder
if not exist "gelscribe\bootstrap.py" goto incomplete
if not exist "python.txt" goto setup
rem after an update with new requirements, check again
fc /b "requirements.txt" "requirements.used" >nul 2>nul || goto setup
call :choice
if not exist "%PYW%" goto setup
if not exist "GelScribe.lnk" call :shortcuts
goto run

:setup
1>&2 echo Setting up GelScribe. It takes a moment, or a few minutes if Qt has to be downloaded.
1>&2 echo.
set "PY="
rem any Python 3.8 or newer can run the setup, which then checks every Python here
call :try py -3
if not defined PY call :try python
if not defined PY if defined CONDA_PREFIX call :try "%CONDA_PREFIX%\python.exe"
for %%D in ("%USERPROFILE%\miniconda3" "%USERPROFILE%\anaconda3" "%USERPROFILE%\miniforge3" "%USERPROFILE%\mambaforge" "%LOCALAPPDATA%\miniconda3" "%LOCALAPPDATA%\anaconda3" "%ProgramData%\miniconda3" "%ProgramData%\anaconda3" "%ProgramData%\miniforge3") do if not defined PY call :try "%%~D\python.exe"
if not defined PY goto nopython
rem its messages go to the console but not into a command's output (GelScribe detect gel.png > lanes.json)
%PY% -B "%HERE%gelscribe\bootstrap.py" 1>&2 || goto failed
call :choice
if not defined PYW goto failed
1>&2 echo.
if "%MODE%"=="app" echo Done. From now on, start GelScribe from the Start menu or the GelScribe shortcut in this folder.

:run
rem The app and the command-line tool both run in the folder the command was typed in, so GelScribe.bat blot.png finds
rem blot.png, with this folder on the module path. Safe path: a numpy.py or PIL folder there can't stand in for a library.
set "PP=%HERE%"
if defined PYTHONPATH set "PP=%HERE%;%PYTHONPATH%"
set "PYTHONPATH=%PP%"
set "PYTHONSAFEPATH=1"
popd
if "%MODE%"=="cli" goto cli
start "" "%PYW%" -m gelscribe %*
exit /b 0

:cli
rem the console python.exe next to pythonw.exe
for %%P in ("%PYW%") do set "PYC=%%~dpPpython.exe"
if not exist "%PYC%" set "PYC=%PYW%"
"%PYC%" -m gelscribe.cli %*
exit /b %ERRORLEVEL%

:choice
rem python.txt is plain ASCII, so every code page reads it the same. A Python inside this folder (the private .venv) is
rem written relative to it, which lets the folder have any name. Any other Python is written in full.
set "PYW="
set /p PYW=<"python.txt"
if not defined PYW exit /b 0
if not "%PYW:~1,1%"==":" if not "%PYW:~0,2%"=="\\" set "PYW=%HERE%%PYW%"
exit /b 0

:try
%* -B -c "import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)" >nul 2>nul && set "PY=%*"
exit /b 0

:nopython
1>&2 echo No Python was found (looked for python.org's py, python on PATH, and conda).
1>&2 echo GelScribe doesn't download Python. Get Python 3.13 from https://www.python.org/downloads/ and on the
1>&2 echo installer's first screen tick "Add python.exe to PATH". Python 3.11 to 3.14 work. Then double-click
1>&2 echo GelScribe.bat again.
popd
if "%MODE%"=="app" pause
exit /b 1

:failed
1>&2 echo.
1>&2 echo Setting up didn't finish (the reason is above). If a download failed, check the internet connection.
1>&2 echo Then double-click GelScribe.bat again.
popd
if "%MODE%"=="app" pause
exit /b 1

:incomplete
1>&2 echo GelScribe's files aren't all here (gelscribe\bootstrap.py is missing). If you opened GelScribe.bat inside the
1>&2 echo zip, close it, right-click the zip, choose Extract All, and open GelScribe.bat in the new folder.
popd
if "%MODE%"=="app" pause
exit /b 1

:nofolder
1>&2 echo GelScribe.bat can't open the folder it is in. If that is a network drive, check that it is connected.
if "%MODE%"=="app" pause
exit /b 1

:shortcuts
rem GelScribe.lnk here and in the Start menu, with the logo. Windows takes the taskbar icon from it.
for %%P in ("%PYW%") do "%%~dpPpython.exe" -B -m gelscribe.app.shortcuts >nul 2>nul
exit /b 0
