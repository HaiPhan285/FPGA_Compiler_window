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

function Download-OSSCADSuite {
    Write-Host "Downloading OSS CAD Suite..." -ForegroundColor Cyan
    
    try {
        New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null
        
        Write-Host "  Fetching latest release from GitHub..."
        $releasesUrl = "https://api.github.com/repos/YosysHQ/oss-cad-suite-releases/releases/latest"
        
        $headers = @{
            "Accept" = "application/vnd.github.v3+json"
        }
        
        try {
            $release = Invoke-RestMethod -Uri $releasesUrl -Headers $headers -TimeoutSec 10 -ErrorAction Stop
            $asset = $release.assets | Where-Object { $_.name -match "windows.*\.zip$" -and $_.name -notmatch "macos|linux|arm" } | Select-Object -First 1
            
            if ($asset) {
                $downloadUrl = $asset.browser_download_url
                $assetName = $asset.name
                Write-Host "  Found: $assetName"
            }
        }
        catch {
            Write-Host "  API call failed, trying fallback method..."
            $releasesPage = Invoke-WebRequest -Uri "https://github.com/YosysHQ/oss-cad-suite-releases/releases/latest" -TimeoutSec 10 -ErrorAction Stop
            
            $matches = [regex]::Matches($releasesPage.Content, 'href="([^"]*oss-cad-suite[^"]*windows[^"]*\.zip)"')
            if ($matches.Count -eq 0) {
                throw "Could not find Windows release download link"
            }
            
            $downloadPath = $matches[0].Groups[1].Value
            if (-not $downloadPath.StartsWith("http")) {
                $downloadPath = "https://github.com" + $downloadPath
            }
            
            $downloadUrl = $downloadPath
            $assetName = Split-Path -Leaf $downloadUrl
        }
        
        $zipPath = Join-Path $toolsDir $assetName
        
        Write-Host "  Downloading OSS CAD Suite (may take 5-10 minutes)..."
        Invoke-WebRequest -Uri $downloadUrl -OutFile $zipPath -TimeoutSec 600 -ErrorAction Stop
        
        Write-Host "  Extracting to $localOSSCAD..."
        
        if (Test-Path $localOSSCAD) {
            Remove-Item -LiteralPath $localOSSCAD -Recurse -Force
        }
        
        $tempExtract = Join-Path $toolsDir "oss-cad-suite-temp"
        if (Test-Path $tempExtract) {
            Remove-Item -LiteralPath $tempExtract -Recurse -Force
        }
        
        Expand-Archive -LiteralPath $zipPath -DestinationPath $tempExtract -Force
        Remove-Item -LiteralPath $zipPath -Force
        
        $dirs = @(Get-ChildItem -LiteralPath $tempExtract -Directory)
        $ossCadDir = $null
        
        foreach ($dir in $dirs) {
            $binPath = Join-Path $dir.FullName "bin"
            if (Test-Path $binPath) {
                $ossCadDir = $dir.FullName
                break
            }
        }
        
        if (-not $ossCadDir -and $dirs.Count -eq 1) {
            $ossCadDir = $dirs[0].FullName
        }
        
        if ($ossCadDir) {
            Move-Item -LiteralPath $ossCadDir -Destination $localOSSCAD -Force
        } else {
            Move-Item -LiteralPath $tempExtract -Destination $localOSSCAD -Force
        }
        
        if (Test-Path $tempExtract) {
            Remove-Item -LiteralPath $tempExtract -Recurse -Force
        }
        
        Write-Host "  Download complete" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Host "  Download failed: $_" -ForegroundColor Red
        return $false
    }
}

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
    
    if (Test-Path (Join-Path $localOSSCAD "bin")) {
        Write-Host "Found local OSS CAD Suite at: $localOSSCAD" -ForegroundColor Green
    }
    else {
        Write-Host "Downloading OSS CAD Suite automatically..." -ForegroundColor Cyan
        Write-Host ""
        
        $downloadSuccess = Download-OSSCADSuite
        
        if (-not $downloadSuccess) {
            Write-Host ""
            Write-Host "Could not auto-download. Manual setup:" -ForegroundColor Yellow
            Write-Host "1. Download from: https://github.com/YosysHQ/oss-cad-suite-releases/releases"
            Write-Host "2. Extract to: $localOSSCAD"
            Write-Host "3. Run: fpga.bat setup"
            Write-Host ""
            exit 1
        }
    }
    
    $binPath = Join-Path $localOSSCAD "bin"
    if (Test-Path $binPath) {
        Write-Host ""
        Write-Host "Adding OSS CAD Suite to PATH..."
        $env:PATH = "$binPath;$env:PATH"
        Write-Host "  PATH updated" -ForegroundColor Green
    }
    else {
        Write-Host ""
        Write-Host "ERROR: Could not find bin directory in OSS CAD Suite" -ForegroundColor Red
        exit 1
    }
}

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
            Write-Host "  [MISS] $tool : NOT FOUND" -ForegroundColor Red
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
    Write-Host "ERROR: Verification failed" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $stateDir)) {
    New-Item -ItemType Directory -Path $stateDir | Out-Null
}

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
Write-Host "Ready to build! Next steps:"
Write-Host "  1. Create a Verilog design in src/"
Write-Host "  2. Run: fpga.bat build src\my_design.sv"
Write-Host ""
