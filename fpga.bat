@echo off
setlocal EnableExtensions

if "%~1"=="" goto :usage

set "COMMAND=%~1"
shift

set "ROOT=%~dp0"
if "%ROOT:~-1%"=="\" set "ROOT=%ROOT:~0,-1%"
set "SETUP_SCRIPT=%ROOT%\setup.ps1"
set "ENV_FILE=%ROOT%\.toolchain\env.bat"

if /I "%COMMAND%"=="setup" goto :setup

call :ensure_toolchain || exit /b 1
call "%ENV_FILE%" || exit /b 1

if /I "%COMMAND%"=="build" goto :build
if /I "%COMMAND%"=="program" goto :program
if /I "%COMMAND%"=="prog" goto :program

echo Unknown command: %COMMAND%
goto :usage

:setup
powershell -ExecutionPolicy Bypass -File "%SETUP_SCRIPT%" -Ensure
exit /b %ERRORLEVEL%

:ensure_toolchain
if not exist "%SETUP_SCRIPT%" (
  echo Missing setup script: %SETUP_SCRIPT%
  exit /b 1
)

powershell -ExecutionPolicy Bypass -File "%SETUP_SCRIPT%" -Ensure
if errorlevel 1 exit /b %ERRORLEVEL%

if not exist "%ENV_FILE%" (
  echo Toolchain environment file not found: %ENV_FILE%
  exit /b 1
)

exit /b 0

:build
powershell -ExecutionPolicy Bypass -File "%ROOT%\build.ps1" "%~1" "%~2" "%~3"
exit /b %ERRORLEVEL%

:program
set "BIT=%~1"
if not defined BIT set "BIT=%ROOT%\build\your_design.bit"
if not exist "%BIT%" (
  echo Bitstream not found: %BIT%
  exit /b 1
)

echo Programming bitstream: %BIT%
echo Using programmer: %OPENFPGALOADER_EXE%
echo Cable: %OPENFPGALOADER_CABLE%
call "%OSS_CAD_ENV%" >nul 2>&1 || exit /b 1
rem Nexys A7 uses the Digilent FT2232 JTAG interface; generic FT2232 mode can fail to detect the JTAG chain.
"%OPENFPGALOADER_EXE%" -c "%OPENFPGALOADER_CABLE%" "%BIT%"
set "PROGRAM_EXIT=%ERRORLEVEL%"
if not "%PROGRAM_EXIT%"=="0" (
  echo Programming failed with exit code %PROGRAM_EXIT%.
  exit /b %PROGRAM_EXIT%
)

echo Programming completed.
exit /b 0

:usage
echo Usage:
echo   %~nx0 setup
echo   %~nx0 build ^<design.sv^> [top] [constraints.xdc]
echo   %~nx0 program [build\design.bit]
exit /b 1
