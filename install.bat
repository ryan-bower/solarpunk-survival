@echo off
rem Double-click launcher for install.py. It contains NO install logic of its own -- install.py
rem is still the one installer. All this does is find a Python that is new enough and, when
rem there isn't one, say so in words instead of failing with a syntax error.
rem
rem Anything you pass here is forwarded:  install.bat --status  /  install.bat --purge
setlocal
cd /d "%~dp0"

set "PY="
for %%C in ("py -3" "python" "python3") do (
  if not defined PY (
    %%~C -c "import sys; sys.exit(0 if sys.version_info >= (3,8) else 1)" >nul 2>&1 && set "PY=%%~C"
  )
)

if not defined PY (
  echo.
  echo   Solarpunk Survival needs Python 3.8 or newer, and none was found.
  echo.
  echo   Get it from https://www.python.org/downloads/ -- tick "Add python.exe to PATH"
  echo   during setup -- or install "Python 3" from the Microsoft Store. Then run this again.
  echo.
  echo   Nothing else needs downloading: UE4SS, the Visual C++ runtime and the content pak
  echo   all ship inside this folder.
  echo.
  pause
  exit /b 1
)

%PY% install.py %*
set "RC=%ERRORLEVEL%"
echo.
pause
exit /b %RC%
