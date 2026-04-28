@echo off
setlocal EnableDelayedExpansion

set "SCRIPT_DIR=%~dp0"
set "COMMAND=%~1"
if "%COMMAND%"=="" goto help
shift /1
set "ARGS="

:collect_args
if "%~1"=="" goto dispatch
if defined ARGS (
  set "ARGS=%ARGS% "%~1""
) else (
  set "ARGS="%~1""
)
shift /1
goto collect_args

:dispatch
if /I "%COMMAND%"=="setup" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%setup.ps1" %ARGS%
  exit /b !ERRORLEVEL!
)

if /I "%COMMAND%"=="build" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%build.ps1" %ARGS%
  exit /b !ERRORLEVEL!
)

if /I "%COMMAND%"=="flash" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%build.ps1" -Flash %ARGS%
  exit /b !ERRORLEVEL!
)

:help
echo FPGA Compiler for native Windows
echo.
echo Usage:
echo   fpga.bat setup
echo   fpga.bat build
echo   fpga.bat build -Project blink_led
echo   fpga.bat flash
echo   fpga.bat flash -Project blink_led
echo   fpga.bat flash -Bitstream build\blink_led\blink_led.bit
echo.
exit /b 1
