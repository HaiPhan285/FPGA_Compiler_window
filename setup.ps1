param(
    [switch]$Ensure,
    [switch]$Force,
    [switch]$SkipDownload
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$stateDir = Join-Path $root ".toolchain"
$envFile = Join-Path $stateDir "env.bat"
$toolsDir = Join-Path $stateDir "tools"
$localOSSCAD = Join-Path $toolsDir "oss-cad-suite"

Write-Host "====== FPGA Toolchain Setup ======"
Write-Host ""

# Check for required tools in PATH or locally
$tools = "yosys", "nextpnr-xilinx", "python"
$missingTools = @()

Write-Host "Checking for required tools..."
foreach ($tool in $tools) {
    $found = $null
    try {
        $found = Get-Command $tool -ErrorAction SilentlyContinue
    }
    catch { }
    
    if ($found) {
        Write-Host "  [OK] $tool : $($found.Source)"
    }
    else {
        Write-Host "  [MISS] $tool : NOT FOUND" -ForegroundColor Yellow
        if ($tool -ne "python") {
            $missingTools += $tool
        }
    }
}

# Python is special - let's check it more carefully
if (-not ($tools | Where-Object { $_ -eq "python" } | ForEach-Object { Get-Command $_ -ErrorAction SilentlyContinue })) {
    Write-Host "  [WARN] python : Consider installing Python 3.x" -ForegroundColor Yellow
}

if ($missingTools.Count -gt 0) {
    Write-Host ""
    Write-Host "Missing tools: $($missingTools -join ', ')" -ForegroundColor Red
    Write-Host ""
    
    # Check if OSS CAD Suite is already locally placed
    if (Test-Path (Join-Path $localOSSCAD "bin")) {
        Write-Host "Found local OSS CAD Suite at: $localOSSCAD" -ForegroundColor Green
        Write-Host "Adding to PATH..."
        $binPath = Join-Path $localOSSCAD "bin"
        $env:PATH = "$binPath;$env:PATH"
    }
    else {
        Write-Host "Solution:" -ForegroundColor Cyan
        Write-Host "1. Download OSS CAD Suite from:"
        Write-Host "   https://github.com/YosysHQ/oss-cad-suite/releases"
        Write-Host ""
        Write-Host "2. Extract to one of these locations:"
        Write-Host "   a) $localOSSCAD"
        Write-Host "      (Automatic extraction location)"
        Write-Host ""
        Write-Host "   b) Add to Windows PATH:"
        Write-Host "      - Win + X > System"
        Write-Host "      - Advanced system settings > Environment Variables"
        Write-Host "      - User variables > New"
        Write-Host "      - Name: PATH"
        Write-Host "      - Value: C:\oss-cad-suite\bin"
        Write-Host "      - Restart terminal"
        Write-Host ""
        Write-Host "3. Run again:"
        Write-Host "   fpga.bat setup"
        Write-Host ""
        exit 1
    }
}

# Verify tools again after adding to PATH
Write-Host ""
Write-Host "Verifying toolchain..."
$toolsVerified = $true
foreach ($tool in @("yosys", "nextpnr-xilinx")) {
    try {
        $cmd = Get-Command $tool -ErrorAction SilentlyContinue
        if ($cmd) {
            Write-Host "  [OK] $tool : $($cmd.Source)"
        }
        else {
            Write-Host "  [MISS] $tool : STILL NOT FOUND" -ForegroundColor Red
            $toolsVerified = $false
        }
    }
    catch {
        Write-Host "  [ERROR] $tool : ERROR" -ForegroundColor Red
        $toolsVerified = $false
    }
}

if (-not $toolsVerified) {
    Write-Host ""
    Write-Host "ERROR: Required tools still not found after setup" -ForegroundColor Red
    exit 1
}

# Create toolchain directory
if (-not (Test-Path $stateDir)) {
    New-Item -ItemType Directory -Path $stateDir | Out-Null
}

# Find tools and resource files
$yosysCmd = Get-Command yosys -ErrorAction SilentlyContinue
$pythonCmd = Get-Command python -ErrorAction SilentlyContinue
$nextpnrCmd = Get-Command nextpnr-xilinx -ErrorAction SilentlyContinue

$yosysExe = if ($yosysCmd) { $yosysCmd.Source } else { "" }
$pythonExe = if ($pythonCmd) { $pythonCmd.Source } else { "" }
$nextpnrExe = if ($nextpnrCmd) { $nextpnrCmd.Source } else { "" }

# Find resource files (chipdb, databases, tools)
$chipdb = Get-ChildItem -Path $root -Recurse -Filter "*xc7a100t*.bin" -ErrorAction SilentlyContinue | Select-Object -First 1
$partYaml = Get-ChildItem -Path $root -Recurse -Filter "part.yaml" -ErrorAction SilentlyContinue | Where-Object { $_.FullName -like "*xc7a100tcsg324-1*" } | Select-Object -First 1
$xc7frames2bit = Get-ChildItem -Path $root -Recurse -Filter "xc7frames2bit.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
$ossCadEnv = Get-ChildItem -Path $root -Recurse -Filter "environment.bat" -ErrorAction SilentlyContinue | Select-Object -First 1

# Build env.bat content
$envLines = @("@echo off")
$envLines += "set `"PART=xc7a100tcsg324-1`""
$envLines += "set `"YOSYS_EXE=$yosysExe`""
$envLines += "set `"PYTHON_EXE=$pythonExe`""
$envLines += "set `"NEXTPNR_EXE=$nextpnrExe`""

if ($chipdb) {
    $envLines += "set `"CHIPDB=$($chipdb.FullName)`""
}

if ($partYaml) {
    $xrayDbRoot = Split-Path -Parent (Split-Path -Parent $partYaml.FullName)
    $envLines += "set `"XRAY_DB_ROOT=$xrayDbRoot`""
    $envLines += "set `"PART_FILE=$($partYaml.FullName)`""
    
    $prjxrayUtils = Join-Path $xrayDbRoot "prjxray\utils"
    if (Test-Path $prjxrayUtils) {
        $envLines += "set `"PRJXRAY_UTILS=$prjxrayUtils`""
    }
}

if ($xc7frames2bit) {
    $envLines += "set `"XC7FRAMES2BIT_EXE=$($xc7frames2bit.FullName)`""
}

if ($ossCadEnv) {
    $envLines += "set `"OSS_CAD_ENV=$($ossCadEnv.FullName)`""
}

$envContent = ($envLines -join "`r`n") + "`r`n"
Set-Content -LiteralPath $envFile -Value $envContent -Encoding ASCII

Write-Host ""
Write-Host "SUCCESS: Toolchain configured" -ForegroundColor Green
Write-Host "  Environment: $envFile"
Write-Host ""
Write-Host "Next: Run 'fpga.bat build src\my_design.sv' to compile your design"
Write-Host ""
