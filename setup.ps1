[CmdletBinding()]
param(
    [switch]$InstallPackages,
    [switch]$PersistPath
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$ToolRoot = Join-Path $RepoRoot ".toolchain\tools"
$ToolBin = Join-Path $ToolRoot "bin"
$BuildDir = Join-Path $RepoRoot "build"
$MsysRoot = "C:\msys64"
$MingwBin = Join-Path $MsysRoot "mingw64\bin"
$UsrBin = Join-Path $MsysRoot "usr\bin"

function Add-PathEntry {
    param([string]$PathEntry)
    if ((Test-Path $PathEntry) -and (($env:Path -split ';') -notcontains $PathEntry)) {
        $env:Path = "$PathEntry;$env:Path"
    }
}

function Find-Command {
    param([string[]]$Names)
    foreach ($Name in $Names) {
        $Command = Get-Command $Name -ErrorAction SilentlyContinue
        if ($Command) {
            return $Command.Source
        }
    }
    return $null
}

New-Item -ItemType Directory -Force -Path $ToolBin, $BuildDir | Out-Null
Add-PathEntry $ToolBin
Add-PathEntry $MingwBin
Add-PathEntry $UsrBin

Write-Host ""
Write-Host "====== FPGA Compiler Setup: native Windows ======"
Write-Host ""

if ($InstallPackages) {
    $Pacman = Join-Path $UsrBin "pacman.exe"
    if (-not (Test-Path $Pacman)) {
        throw "MSYS2 was not found at $MsysRoot. Install MSYS2 from https://www.msys2.org, then rerun setup."
    }

    Write-Host "Installing MSYS2 packages used by the open-source FPGA flow..."
    & $Pacman -S --noconfirm --needed `
        git base-devel make cmake python python-pip pkgconf `
        mingw-w64-x86_64-toolchain `
        mingw-w64-x86_64-cmake `
        mingw-w64-x86_64-python `
        mingw-w64-x86_64-boost `
        mingw-w64-x86_64-eigen3 `
        mingw-w64-x86_64-yosys `
        mingw-w64-x86_64-openFPGALoader
}

if ($PersistPath) {
    $UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
    foreach ($Entry in @($ToolBin, $MingwBin, $UsrBin)) {
        if ((Test-Path $Entry) -and (($UserPath -split ';') -notcontains $Entry)) {
            $UserPath = "$Entry;$UserPath"
        }
    }
    [Environment]::SetEnvironmentVariable("Path", $UserPath, "User")
    Write-Host "Updated user PATH. Open a new terminal for persistent PATH changes."
}

$Checks = [ordered]@{
    "yosys" = @(Find-Command @("yosys.exe", "yosys"))
    "nextpnr-xilinx" = @(Find-Command @("nextpnr-xilinx.exe", "nextpnr-xilinx"))
    "fasm2frames" = @(Find-Command @("fasm2frames.exe", "fasm2frames"))
    "xc7frames2bit" = @(Find-Command @("xc7frames2bit.exe", "xc7frames2bit"))
    "openFPGALoader" = @(Find-Command @("openFPGALoader.exe", "openFPGALoader"))
    "python" = @(Find-Command @("python.exe", "python", "python3.exe", "python3"))
}

$Missing = @()
foreach ($Item in $Checks.GetEnumerator()) {
    $Found = $Item.Value | Select-Object -First 1
    if ($Found) {
        Write-Host ("[OK]   {0}: {1}" -f $Item.Key, $Found)
    } else {
        Write-Host ("[MISS] {0}" -f $Item.Key)
        $Missing += $Item.Key
    }
}

Write-Host ""
if ($Missing.Count -eq 0) {
    Write-Host "Setup complete. Run: .\fpga.bat build"
    exit 0
}

Write-Host "Missing tools: $($Missing -join ', ')"
Write-Host ""
Write-Host "Windows-native target:"
Write-Host "  - Yosys can be installed from MSYS2 with: .\setup.ps1 -InstallPackages"
Write-Host "  - nextpnr-xilinx/prjxray are the hard part; use native openXC7/MSYS2-built binaries and put them on PATH or in .toolchain\tools\bin."
Write-Host "  - Vivado and WSL are not required by these scripts."
exit 1
