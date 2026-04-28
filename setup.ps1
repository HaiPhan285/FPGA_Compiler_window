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

if (-not ($tools | Where-Object { $_ -eq "python" } | ForEach-Object { Get-Command $_ -ErrorAction SilentlyContinue })) {
    Write-Host "  [WARN] python : Not found (optional)" -ForegroundColor Yellow
}

if ($missingTools.Count -gt 0) {
    Write-Host ""
    Write-Host "Missing tools: $($missingTools -join ', ')" -ForegroundColor Red
    Write-Host ""
    
    # Check if OSS CAD Suite is already locally placed
    if (Test-Path (Join-Path $localOSSCAD "bin")) {
        Write-Host "Found local OSS CAD Suite!" -ForegroundColor Green
    }
    else {
        Write-Host "OSS CAD Suite not found." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Two ways to fix this:" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "Option 1: Use download helper (recommended for first-time)"
        Write-Host "  Run: download-tools.bat"
        Write-Host "  Then: fpga.bat setup"
        Write-Host ""
        Write-Host "Option 2: Manual download"
        Write-Host "  1. Visit: https://github.com/YosysHQ/oss-cad-suite-releases/releases"
        Write-Host "  2. Download: oss-cad-suite-*-windows.zip"
        Write-Host "  3. Extract to: $localOSSCAD"
        Write-Host "  4. Run: fpga.bat setup"
        Write-Host ""
        exit 1
    }
    
    # Add OSS CAD Suite to PATH
    $binPath = Join-Path $localOSSCAD "bin"
    if (Test-Path $binPath) {
        Write-Host ""
        Write-Host "Adding OSS CAD Suite to PATH..."
        $env:PATH = "$binPath;$env:PATH"
        Write-Host "  PATH updated" -ForegroundColor Green
    }
    else {
        Write-Host ""
        Write-Host "ERROR: bin directory not found in OSS CAD Suite" -ForegroundColor Red
        Write-Host "  Expected: $binPath"
        Write-Host ""
        Write-Host "Verify the extraction:"
        Write-Host "  Should contain: $localOSSCAD\bin\"
        Write-Host ""
        exit 1
    }
}

# Verify tools again after adding to PATH
Write-Host ""
Write-Host "Verifying tools..."
$toolsVerified = $true
foreach ($tool in @("yosys", "nextpnr-xilinx")) {
    try {
        $cmd = Get-Command $tool -ErrorAction SilentlyContinue
        if ($cmd) {
            Write-Host "  [OK] $tool"
        }
        else {
            Write-Host "  [MISS] $tool : NOT FOUND" -ForegroundColor Red
            $toolsVerified = $false
        }
    }
    catch {
        Write-Host "  [ERROR] $tool" -ForegroundColor Red
        $toolsVerified = $false
    }
}

if (-not $toolsVerified) {
    Write-Host ""
    Write-Host "ERROR: Tools still not accessible" -ForegroundColor Red
    Write-Host "Troubleshooting:" -ForegroundColor Yellow
    Write-Host "  1. Check OSS CAD Suite extraction"
    Write-Host "  2. Verify 'bin' folder exists at: $binPath"
    Write-Host "  3. Restart terminal and try again"
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

$chipdb = Get-ChildItem -Path $root -Recurse -Filter "*xc7a100t*.bin" -ErrorAction SilentlyContinue | Select-Object -First 1
$partYaml = Get-ChildItem -Path $root -Recurse -Filter "part.yaml" -ErrorAction SilentlyContinue | Where-Object { $_.FullName -like "*xc7a100tcsg324-1*" } | Select-Object -First 1
$xc7frames2bit = Get-ChildItem -Path $root -Recurse -Filter "xc7frames2bit.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
$ossCadEnv = Get-ChildItem -Path $root -Recurse -Filter "environment.bat" -ErrorAction SilentlyContinue | Select-Object -First 1

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
Write-Host "  OSS CAD Suite: $localOSSCAD"
Write-Host ""
Write-Host "Next: fpga.bat build src\my_design.sv"
Write-Host ""
