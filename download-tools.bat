@echo off
REM Download helper script for OSS CAD Suite
REM Usage: download-tools.bat

echo.
echo ====== OSS CAD Suite Download Helper ======
echo.
echo This script will download OSS CAD Suite to: .toolchain\tools\oss-cad-suite
echo.
echo Prerequisites:
echo   - curl or PowerShell (for downloading)
echo   - ~500MB free disk space
echo.

setlocal enabledelayedexpansion
set ROOT=%~dp0
if "%ROOT:~-1%"=="\" set "ROOT=%ROOT:~0,-1%"
set TOOLS_DIR=%ROOT%\.toolchain\tools
set OSS_CAD_DIR=%TOOLS_DIR%\oss-cad-suite

if not exist "%TOOLS_DIR%" mkdir "%TOOLS_DIR%"

echo Downloading OSS CAD Suite...
echo (This may take 10-15 minutes depending on your internet speed)
echo.

REM Try with PowerShell
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ProgressPreference = 'Continue'; " ^
  "$url = 'https://github.com/YosysHQ/oss-cad-suite-releases/releases/download/2024.12.01/oss-cad-suite-2024.12.01-windows.zip'; " ^
  "$out = '%TOOLS_DIR%\oss-cad-suite.zip'; " ^
  "try { " ^
    "Write-Host 'Downloading from: $url'; " ^
    "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; " ^
    "Invoke-WebRequest -Uri $url -OutFile $out -TimeoutSec 600; " ^
    "Write-Host 'Download complete!'; " ^
    "Write-Host 'Extracting...'; " ^
    "Expand-Archive -Path $out -DestinationPath '%TOOLS_DIR%\oss-cad-suite-temp' -Force; " ^
    "Remove-Item -Path $out; " ^
    "Get-ChildItem '%TOOLS_DIR%\oss-cad-suite-temp' | ForEach-Object { Move-Item -Path $_.FullName -Destination '%TOOLS_DIR%\oss-cad-suite' -Force }; " ^
    "Remove-Item -Path '%TOOLS_DIR%\oss-cad-suite-temp' -Recurse -Force; " ^
    "Write-Host 'Success!'; " ^
  "} catch { " ^
    "Write-Host 'Download failed: $($_.Exception.Message)' -ForegroundColor Red; " ^
    "exit 1; " ^
  "}"

if %ERRORLEVEL% EQU 0 (
  echo.
  echo SUCCESS: OSS CAD Suite downloaded and extracted
  echo Location: %OSS_CAD_DIR%
  echo.
  echo Next: Run 'fpga.bat setup'
  echo.
) else (
  echo.
  echo ERROR: Download failed
  echo.
  echo Manual download:
  echo 1. Visit: https://github.com/YosysHQ/oss-cad-suite-releases/releases
  echo 2. Download: oss-cad-suite-YYYY.MM.DD-windows.zip
  echo 3. Extract to: %OSS_CAD_DIR%
  echo 4. Run: fpga.bat setup
  echo.
  exit /b 1
)
