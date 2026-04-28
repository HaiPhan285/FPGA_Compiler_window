param(
    [switch]$Ensure,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$stateDir = Join-Path $root ".toolchain"
$envFile = Join-Path $stateDir "env.bat"

Write-Host "====== FPGA Toolchain Setup ======"
Write-Host ""

# Check for required tools in PATH
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
        $missingTools += $tool
    }
}

if ($missingTools.Count -gt 0) {
    Write-Host ""
    Write-Host "ERROR: Missing required tools: $($missingTools -join ', ')" -ForegroundColor Red
    Write-Host ""
    Write-Host "How to fix:"
    Write-Host "  1. Download OSS CAD Suite from: https://github.com/YosysHQ/oss-cad-suite"
    Write-Host "  2. Extract it to any directory"
    Write-Host "  3. Add the 'bin' directory to your Windows PATH environment variable"
    Write-Host "  4. Restart PowerShell or Command Prompt"
    Write-Host "  5. Run setup again"
    Write-Host ""
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
Write-Host "SUCCESS: Toolchain configured"
Write-Host "  Environment: $envFile"
Write-Host ""
Write-Host "Next: Run '.\fpga.bat build' to compile your design"
Write-Host ""
