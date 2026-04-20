param(
    [switch]$Ensure,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$stateDir = Join-Path $root ".toolchain"
$downloadsDir = Join-Path $stateDir "downloads"
$managedOssCadRoot = Join-Path $stateDir "oss-cad-suite"
$managedBundleRoot = Join-Path $stateDir "openxc7-bundle"
$envFile = Join-Path $stateDir "env.bat"
$configPath = Join-Path $root "toolchain.local.json"
$legacyFpgaTools = "C:\Users\27mik\AppData\Local\fpga-tools"
$legacyOssCadRoot = "C:\fpga-tools\oss-cad-suite"
$legacyNextpnrExe = "C:\Users\27mik\nextpnr-xilinx-patched.exe"

function Get-ConfigValue {
    param(
        $Object,
        [string[]]$Path,
        $Default = $null
    )

    $current = $Object
    foreach ($segment in $Path) {
        if ($null -eq $current) {
            return $Default
        }

        $property = $current.PSObject.Properties[$segment]
        if (-not $property) {
            return $Default
        }

        $current = $property.Value
    }

    if ($null -eq $current) {
        return $Default
    }

    if ($current -is [string] -and [string]::IsNullOrWhiteSpace($current)) {
        return $Default
    }

    return $current
}

function Resolve-WorkspacePath {
    param([string]$PathValue)

    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        return $null
    }

    if ([System.IO.Path]::IsPathRooted($PathValue)) {
        return [System.IO.Path]::GetFullPath($PathValue)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $root $PathValue))
}

function Ensure-Directory {
    param([string]$PathValue)

    if (-not (Test-Path -LiteralPath $PathValue)) {
        New-Item -ItemType Directory -Path $PathValue | Out-Null
    }
}

function Invoke-DownloadFile {
    param(
        [string]$Url,
        [string]$Destination
    )

    Ensure-Directory -PathValue (Split-Path -Parent $Destination)
    Write-Host "Downloading $Url"
    Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing
}

function Expand-ZipArchive {
    param(
        [string]$ArchivePath,
        [string]$Destination
    )

    Ensure-Directory -PathValue $Destination
    Expand-Archive -Path $ArchivePath -DestinationPath $Destination -Force
}

function Get-LatestOssCadSuiteAsset {
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/YosysHQ/oss-cad-suite-build/releases/latest"
    $asset = $release.assets |
        Where-Object { $_.name -like "*windows-x64*" -and $_.name -like "*.zip" } |
        Select-Object -First 1

    if (-not $asset) {
        throw "Could not find a Windows zip asset in the latest OSS CAD Suite release."
    }

    return [pscustomobject]@{
        Name = $asset.name
        Url = $asset.browser_download_url
        Tag = $release.tag_name
    }
}

function Ensure-OssCadSuite {
    param($Config)

    $configuredRoot = Resolve-WorkspacePath (Get-ConfigValue -Object $Config -Path @("ossCadSuite", "root"))
    $autoDownload = [bool](Get-ConfigValue -Object $Config -Path @("autoDownload") -Default $true)
    $ossCadRoot = $null

    foreach ($candidate in @($configuredRoot, $managedOssCadRoot, $legacyOssCadRoot)) {
        if ($candidate -and (Test-Path -LiteralPath (Join-Path $candidate "environment.bat"))) {
            $ossCadRoot = $candidate
            break
        }
    }

    if ($ossCadRoot -and -not $Force) {
        return $ossCadRoot
    }

    if (-not $autoDownload) {
        return $configuredRoot
    }

    $asset = Get-LatestOssCadSuiteAsset
    $archivePath = Join-Path $downloadsDir $asset.Name

    Write-Host "Installing OSS CAD Suite $($asset.Tag) into $managedOssCadRoot"
    if (Test-Path -LiteralPath $managedOssCadRoot) {
        Remove-Item -LiteralPath $managedOssCadRoot -Recurse -Force
    }

    Invoke-DownloadFile -Url $asset.Url -Destination $archivePath
    Expand-ZipArchive -ArchivePath $archivePath -Destination $stateDir

    if (-not (Test-Path -LiteralPath (Join-Path $managedOssCadRoot "environment.bat"))) {
        throw "OSS CAD Suite was downloaded, but environment.bat was not found under $managedOssCadRoot"
    }

    return $managedOssCadRoot
}

function Ensure-OptionalBundle {
    param($Config)

    $configuredRoot = Resolve-WorkspacePath (Get-ConfigValue -Object $Config -Path @("toolchainBundle", "root"))
    $downloadUrl = Get-ConfigValue -Object $Config -Path @("toolchainBundle", "downloadUrl")
    $archiveName = Get-ConfigValue -Object $Config -Path @("toolchainBundle", "archiveName") -Default "openxc7-bundle.zip"
    $bundleRoot = if ($configuredRoot) { $configuredRoot } else { $managedBundleRoot }

    if ((Test-Path -LiteralPath $bundleRoot) -and -not $Force) {
        return $bundleRoot
    }

    if (-not $downloadUrl) {
        return $configuredRoot
    }

    $archivePath = Join-Path $downloadsDir $archiveName
    Write-Host "Installing OpenXC7 bundle into $bundleRoot"

    if (Test-Path -LiteralPath $bundleRoot) {
        Remove-Item -LiteralPath $bundleRoot -Recurse -Force
    }

    Ensure-Directory -PathValue $bundleRoot
    Invoke-DownloadFile -Url $downloadUrl -Destination $archivePath
    Expand-ZipArchive -ArchivePath $archivePath -Destination $bundleRoot

    return $bundleRoot
}

function Resolve-FirstExistingPath {
    param([string[]]$Candidates)

    foreach ($candidate in $Candidates) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate)) {
            return [System.IO.Path]::GetFullPath($candidate)
        }
    }

    return $null
}

function Resolve-RelativeToRoot {
    param(
        [string]$BasePath,
        [string]$RelativePath
    )

    if (-not $BasePath -or [string]::IsNullOrWhiteSpace($RelativePath)) {
        return $null
    }

    return [System.IO.Path]::GetFullPath((Join-Path $BasePath $RelativePath))
}

function Get-PathList {
    param(
        $Config,
        [string[]]$Path
    )

    $value = Get-ConfigValue -Object $Config -Path $Path
    if ($null -eq $value) {
        return @()
    }

    if ($value -is [System.Array]) {
        return @($value)
    }

    return @($value)
}

function Write-EnvFile {
    param(
        [string]$FilePath,
        [hashtable]$Values
    )

    Ensure-Directory -PathValue (Split-Path -Parent $FilePath)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("@echo off")

    foreach ($key in ($Values.Keys | Sort-Object)) {
        $value = $Values[$key]
        $lines.Add("set `"$key=$value`"")
    }

    $text = ($lines -join "`r`n") + "`r`n"
    Set-Content -LiteralPath $FilePath -Value $text -Encoding ASCII
}

$config = $null
if (Test-Path -LiteralPath $configPath) {
    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
}

$ossCadRoot = Ensure-OssCadSuite -Config $config
$bundleRoot = Ensure-OptionalBundle -Config $config

$prjxrayRelativeRoot = Get-ConfigValue -Object $config -Path @("toolchainBundle", "prjxrayRoot") -Default "src\prjxray"
$prjxrayDbRelativeRoot = Get-ConfigValue -Object $config -Path @("toolchainBundle", "prjxrayDbRoot") -Default "src\prjxray-db\artix7"
$nextpnrRelativeExe = Get-ConfigValue -Object $config -Path @("toolchainBundle", "nextpnrExe") -Default "nextpnr-xilinx.exe"
$xc7framesRelativeExe = Get-ConfigValue -Object $config -Path @("toolchainBundle", "xc7frames2bitExe") -Default "build\prjxray\tools\xc7frames2bit.exe"
$pathExtrasRelative = Get-PathList -Config $config -Path @("toolchainBundle", "pathExtras")

$prjxrayRoot = Resolve-FirstExistingPath @(
    (Resolve-WorkspacePath (Get-ConfigValue -Object $config -Path @("projectXray", "root"))),
    (Resolve-RelativeToRoot -BasePath $bundleRoot -RelativePath $prjxrayRelativeRoot),
    (Join-Path $legacyFpgaTools "source-build\src\prjxray")
)

$prjxrayUtilsFromRoot = if ($prjxrayRoot) { Join-Path $prjxrayRoot "utils" } else { $null }
$prjxrayFasmFromRoot = if ($prjxrayRoot) { Join-Path $prjxrayRoot "third_party\fasm" } else { $null }

$prjxrayUtils = Resolve-FirstExistingPath @(
    (Resolve-WorkspacePath (Get-ConfigValue -Object $config -Path @("projectXray", "utilsPath"))),
    $prjxrayUtilsFromRoot,
    (Join-Path $legacyFpgaTools "source-build\src\prjxray\utils")
)

$prjxrayFasm = Resolve-FirstExistingPath @(
    (Resolve-WorkspacePath (Get-ConfigValue -Object $config -Path @("projectXray", "fasmPath"))),
    $prjxrayFasmFromRoot,
    (Join-Path $legacyFpgaTools "source-build\src\prjxray\third_party\fasm")
)

$xrayDbRoot = Resolve-FirstExistingPath @(
    (Resolve-WorkspacePath (Get-ConfigValue -Object $config -Path @("projectXray", "dbRoot"))),
    (Resolve-RelativeToRoot -BasePath $bundleRoot -RelativePath $prjxrayDbRelativeRoot),
    (Join-Path $legacyFpgaTools "source-build\src\prjxray-db\artix7")
)

$nextpnrExe = Resolve-FirstExistingPath @(
    (Resolve-WorkspacePath (Get-ConfigValue -Object $config -Path @("nextpnrXilinx", "exePath"))),
    (Resolve-RelativeToRoot -BasePath $bundleRoot -RelativePath $nextpnrRelativeExe),
    $legacyNextpnrExe
)

$chipdb = Resolve-FirstExistingPath @(
    (Resolve-WorkspacePath (Get-ConfigValue -Object $config -Path @("chipdbPath"))),
    (Join-Path $root "tools\xc7a100t.bin")
)

$pythonExe = Resolve-FirstExistingPath @(
    (Resolve-WorkspacePath (Get-ConfigValue -Object $config -Path @("pythonExe"))),
    (Join-Path $ossCadRoot "lib\python3.exe"),
    (Join-Path $legacyFpgaTools "pyenv\bin\python.exe")
)

$xc7frames2bitExe = Resolve-FirstExistingPath @(
    (Resolve-WorkspacePath (Get-ConfigValue -Object $config -Path @("projectXray", "xc7frames2bitExe"))),
    (Resolve-RelativeToRoot -BasePath $bundleRoot -RelativePath $xc7framesRelativeExe),
    (Join-Path $legacyFpgaTools "source-build\build\prjxray\tools\xc7frames2bit.exe")
)

$extraPaths = New-Object System.Collections.Generic.List[string]
foreach ($pathEntry in @(
    (Join-Path $ossCadRoot "bin"),
    (Join-Path $ossCadRoot "lib"),
    (Join-Path $legacyFpgaTools "bin"),
    (Join-Path $legacyFpgaTools "msys64\ucrt64\bin"),
    (Join-Path $legacyFpgaTools "msys64\usr\bin")
)) {
    if ($pathEntry -and (Test-Path -LiteralPath $pathEntry) -and -not $extraPaths.Contains($pathEntry)) {
        $extraPaths.Add($pathEntry)
    }
}

foreach ($relativeExtra in $pathExtrasRelative) {
    $resolvedExtra = Resolve-RelativeToRoot -BasePath $bundleRoot -RelativePath $relativeExtra
    if ($resolvedExtra -and (Test-Path -LiteralPath $resolvedExtra) -and -not $extraPaths.Contains($resolvedExtra)) {
        $extraPaths.Add($resolvedExtra)
    }
}

$part = Get-ConfigValue -Object $config -Path @("part") -Default "xc7a100tcsg324-1"
$partFile = if ($xrayDbRoot) { Join-Path $xrayDbRoot "$part\part.yaml" } else { $null }
$openFpgaLoaderCable = Get-ConfigValue -Object $config -Path @("openFpgaLoader", "cable") -Default "digilent"
$openFpgaLoaderBoard = Get-ConfigValue -Object $config -Path @("openFpgaLoader", "board") -Default "nexys_a7_100"

$required = @(
    @{ Name = "OSS CAD Suite environment"; Path = if ($ossCadRoot) { Join-Path $ossCadRoot "environment.bat" } else { $null } },
    @{ Name = "yosys"; Path = if ($ossCadRoot) { Join-Path $ossCadRoot "bin\yosys.exe" } else { $null } },
    @{ Name = "openFPGALoader"; Path = if ($ossCadRoot) { Join-Path $ossCadRoot "bin\openFPGALoader.exe" } else { $null } },
    @{ Name = "Python"; Path = $pythonExe },
    @{ Name = "nextpnr-xilinx"; Path = $nextpnrExe },
    @{ Name = "xc7frames2bit"; Path = $xc7frames2bitExe },
    @{ Name = "Project X-Ray utils"; Path = $prjxrayUtils },
    @{ Name = "Project X-Ray database"; Path = $xrayDbRoot },
    @{ Name = "Project X-Ray part file"; Path = $partFile },
    @{ Name = "chipdb"; Path = $chipdb }
)

$missing = @($required | Where-Object { -not $_.Path -or -not (Test-Path -LiteralPath $_.Path) })
if ($missing.Count -gt 0) {
    Write-Host ""
    Write-Host "Toolchain setup is incomplete. Missing items:"
    foreach ($item in $missing) {
        Write-Host "  - $($item.Name): $($item.Path)"
    }
    Write-Host ""
    Write-Host "If you already have these tools, create toolchain.local.json and point the paths there."
    Write-Host "If you want automatic downloads, set toolchainBundle.downloadUrl for your prepacked OpenXC7 bundle."
    exit 1
}

$pythonPathParts = New-Object System.Collections.Generic.List[string]
foreach ($pythonPathEntry in @($prjxrayRoot, $prjxrayFasm)) {
    if ($pythonPathEntry -and (Test-Path -LiteralPath $pythonPathEntry) -and -not $pythonPathParts.Contains($pythonPathEntry)) {
        $pythonPathParts.Add($pythonPathEntry)
    }
}

$envValues = [ordered]@{
    CHIPDB = $chipdb
    NEXTPNR_EXE = $nextpnrExe
    OPENFPGALOADER_BOARD = $openFpgaLoaderBoard
    OPENFPGALOADER_CABLE = $openFpgaLoaderCable
    OPENFPGALOADER_EXE = Join-Path $ossCadRoot "bin\openFPGALoader.exe"
    OSS_CAD = $ossCadRoot
    OSS_CAD_ENV = Join-Path $ossCadRoot "environment.bat"
    PART = $part
    PART_FILE = $partFile
    PATH = (($extraPaths -join ";") + ";%PATH%")
    PYTHON_EXE = $pythonExe
    PYTHONPATH = if ($pythonPathParts.Count -gt 0) { ($pythonPathParts -join ";") } else { "%PYTHONPATH%" }
    PRJXRAY_UTILS = $prjxrayUtils
    XRAY_DB_ROOT = $xrayDbRoot
    XC7FRAMES2BIT_EXE = $xc7frames2bitExe
    YOSYS_EXE = Join-Path $ossCadRoot "bin\yosys.exe"
}

Write-EnvFile -FilePath $envFile -Values $envValues

Write-Host ""
Write-Host "Toolchain ready."
Write-Host "  OSS CAD Suite : $ossCadRoot"
Write-Host "  Yosys         : $($envValues.YOSYS_EXE)"
Write-Host "  nextpnr       : $nextpnrExe"
Write-Host "  xc7frames2bit : $xc7frames2bitExe"
Write-Host "  chipdb        : $chipdb"
Write-Host "  env file      : $envFile"
