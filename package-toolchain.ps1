param(
    [string]$OutputPath = "",
    [switch]$Force,
    [switch]$SkipChipDb
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$setupScript = Join-Path $root "setup.ps1"
$envFile = Join-Path $root ".toolchain\env.bat"

function Ensure-Directory {
    param([string]$PathValue)

    if (-not (Test-Path -LiteralPath $PathValue)) {
        New-Item -ItemType Directory -Path $PathValue | Out-Null
    }
}

function Remove-DirectoryIfExists {
    param([string]$PathValue)

    if ($PathValue -and (Test-Path -LiteralPath $PathValue)) {
        Remove-Item -LiteralPath $PathValue -Recurse -Force
    }
}

function New-TemporaryDirectory {
    $pathValue = Join-Path ([System.IO.Path]::GetTempPath()) ("fpga-bundle-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $pathValue | Out-Null
    return $pathValue
}

function Get-BatchEnvironmentValues {
    param([string]$FilePath)

    $values = @{}
    foreach ($line in Get-Content -LiteralPath $FilePath) {
        if ($line -match '^set "(?<name>[^=]+)=(?<value>.*)"$') {
            $values[$matches.name] = $matches.value
        }
    }

    return $values
}

function Resolve-ExistingPath {
    param([string]$PathValue)

    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        return $null
    }

    if (-not (Test-Path -LiteralPath $PathValue)) {
        return $null
    }

    return [System.IO.Path]::GetFullPath($PathValue)
}

function Get-CommonAncestor {
    param([string[]]$Paths)

    $normalizedPaths = @($Paths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object {
        ([System.IO.Path]::GetFullPath($_).TrimEnd('\'))
    })

    if ($normalizedPaths.Count -eq 0) {
        return $null
    }

    if ($normalizedPaths.Count -eq 1) {
        return $normalizedPaths[0]
    }

    $common = $normalizedPaths[0]
    foreach ($pathValue in $normalizedPaths[1..($normalizedPaths.Count - 1)]) {
        while ($common -and -not $pathValue.StartsWith($common, [System.StringComparison]::OrdinalIgnoreCase)) {
            $common = Split-Path -Parent $common
        }
    }

    return $common
}

function Get-RelativePath {
    param(
        [string]$BasePath,
        [string]$PathValue
    )

    $baseFull = [System.IO.Path]::GetFullPath($BasePath).TrimEnd('\', '/')
    $pathFull = [System.IO.Path]::GetFullPath($PathValue).TrimEnd('\', '/')

    if ($pathFull.Equals($baseFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        return "."
    }

    $basePrefix = $baseFull + [System.IO.Path]::DirectorySeparatorChar
    if (-not $pathFull.StartsWith($basePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Path '$pathFull' is not under base path '$baseFull'"
    }

    return $pathFull.Substring($basePrefix.Length)
}

function Get-BundleRuntimeRelativePath {
    param(
        [string]$PathValue,
        [string]$CommonRoot
    )

    $pathFull = [System.IO.Path]::GetFullPath($PathValue).TrimEnd('\', '/')
    $parts = $pathFull -split '[\\/]'
    for ($i = 0; $i -lt $parts.Count; $i++) {
        if ($parts[$i].Equals("msys64", [System.StringComparison]::OrdinalIgnoreCase)) {
            return ($parts[$i..($parts.Count - 1)] -join [System.IO.Path]::DirectorySeparatorChar)
        }
    }

    return Get-RelativePath -BasePath $CommonRoot -PathValue $PathValue
}

function Copy-DirectoryContents {
    param(
        [string]$SourceDirectory,
        [string]$DestinationDirectory
    )

    Ensure-Directory -PathValue $DestinationDirectory
    Copy-Item -LiteralPath (Join-Path $SourceDirectory "*") -Destination $DestinationDirectory -Recurse -Force
}

function New-ZipArchiveFromDirectory {
    param(
        [string]$SourceDirectory,
        [string]$DestinationArchive
    )

    $tarCommand = Get-Command "tar.exe" -ErrorAction SilentlyContinue
    if ($tarCommand) {
        & $tarCommand.Source -a -cf $DestinationArchive -C $SourceDirectory .
        if ($LASTEXITCODE -ne 0) {
            throw "tar.exe failed with exit code $LASTEXITCODE while creating $DestinationArchive"
        }
        return
    }

    $sourceSize = (Get-ChildItem -LiteralPath $SourceDirectory -Recurse -File | Measure-Object -Property Length -Sum).Sum
    if ($sourceSize -gt 2GB) {
        throw "tar.exe was not found, and Compress-Archive is not safe here because Microsoft documents a 2GB ZipArchive limit."
    }

    Compress-Archive -Path (Join-Path $SourceDirectory "*") -DestinationPath $DestinationArchive -CompressionLevel Fastest -Force
}

if (-not (Test-Path -LiteralPath $setupScript)) {
    throw "Missing setup script: $setupScript"
}

& powershell -ExecutionPolicy Bypass -File $setupScript -Ensure
if ($LASTEXITCODE -ne 0) {
    throw "Toolchain setup failed with exit code $LASTEXITCODE"
}

if (-not (Test-Path -LiteralPath $envFile)) {
    throw "Toolchain environment file not found: $envFile"
}

$envValues = Get-BatchEnvironmentValues -FilePath $envFile

$ossCadRoot = Resolve-ExistingPath $envValues.OSS_CAD
$nextpnrExe = Resolve-ExistingPath $envValues.NEXTPNR_EXE
$prjxrayUtils = Resolve-ExistingPath $envValues.PRJXRAY_UTILS
$xrayDbRoot = Resolve-ExistingPath $envValues.XRAY_DB_ROOT
$xc7frames2bitExe = Resolve-ExistingPath $envValues.XC7FRAMES2BIT_EXE
$chipdbPath = if ($SkipChipDb) { $null } else { Resolve-ExistingPath $envValues.CHIPDB }

if (-not $ossCadRoot) { throw "OSS_CAD was not resolved from $envFile" }
if (-not $nextpnrExe) { throw "NEXTPNR_EXE was not resolved from $envFile" }
if (-not $prjxrayUtils) { throw "PRJXRAY_UTILS was not resolved from $envFile" }
if (-not $xrayDbRoot) { throw "XRAY_DB_ROOT was not resolved from $envFile" }
if (-not $xc7frames2bitExe) { throw "XC7FRAMES2BIT_EXE was not resolved from $envFile" }

$prjxrayRoot = if ((Split-Path -Leaf $prjxrayUtils).Equals("utils", [System.StringComparison]::OrdinalIgnoreCase)) {
    Split-Path -Parent $prjxrayUtils
} else {
    $prjxrayUtils
}
$prjxrayRoot = Resolve-ExistingPath $prjxrayRoot
if (-not $prjxrayRoot) {
    throw "Could not infer Project X-Ray root from PRJXRAY_UTILS=$prjxrayUtils"
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $root "dist\nexys-a7-100t-toolchain-windows.zip"
}

$outputFullPath = if ([System.IO.Path]::IsPathRooted($OutputPath)) {
    [System.IO.Path]::GetFullPath($OutputPath)
} else {
    [System.IO.Path]::GetFullPath((Join-Path $root $OutputPath))
}
$outputDirectory = Split-Path -Parent $outputFullPath
Ensure-Directory -PathValue $outputDirectory

if ((Test-Path -LiteralPath $outputFullPath) -and -not $Force) {
    throw "Output archive already exists: $outputFullPath. Re-run with -Force to overwrite it."
}

$stagingRoot = New-TemporaryDirectory
$bundleRoot = Join-Path $stagingRoot "toolchain"

try {
    Ensure-Directory -PathValue $bundleRoot

    Write-Host "Copying OSS CAD Suite from $ossCadRoot"
    Copy-Item -LiteralPath $ossCadRoot -Destination (Join-Path $bundleRoot "oss-cad-suite") -Recurse -Force

    Write-Host "Copying nextpnr-xilinx from $nextpnrExe"
    Copy-Item -LiteralPath $nextpnrExe -Destination (Join-Path $bundleRoot "nextpnr-xilinx.exe") -Force

    Write-Host "Copying Project X-Ray from $prjxrayRoot"
    Ensure-Directory -PathValue (Join-Path $bundleRoot "src")
    Copy-Item -LiteralPath $prjxrayRoot -Destination (Join-Path $bundleRoot "src\prjxray") -Recurse -Force

    Write-Host "Copying Project X-Ray database from $xrayDbRoot"
    Ensure-Directory -PathValue (Join-Path $bundleRoot "src\prjxray-db")
    Copy-Item -LiteralPath $xrayDbRoot -Destination (Join-Path $bundleRoot "src\prjxray-db\artix7") -Recurse -Force

    Write-Host "Copying xc7frames2bit from $xc7frames2bitExe"
    Ensure-Directory -PathValue (Join-Path $bundleRoot "build\prjxray\tools")
    Copy-Item -LiteralPath $xc7frames2bitExe -Destination (Join-Path $bundleRoot "build\prjxray\tools\xc7frames2bit.exe") -Force

    if ($chipdbPath) {
        Write-Host "Copying chipdb from $chipdbPath"
        Ensure-Directory -PathValue (Join-Path $bundleRoot "tools")
        Copy-Item -LiteralPath $chipdbPath -Destination (Join-Path $bundleRoot "tools\xc7a100t.bin") -Force
    }

    $pathExtras = @()
    if ($envValues.PATH) {
        foreach ($pathEntry in ($envValues.PATH -split ';')) {
            if ([string]::IsNullOrWhiteSpace($pathEntry) -or $pathEntry -eq "%PATH%") {
                continue
            }

            $resolvedEntry = Resolve-ExistingPath $pathEntry
            if (-not $resolvedEntry) {
                continue
            }

            if ($resolvedEntry.StartsWith($ossCadRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                continue
            }

            if (-not $pathExtras.Contains($resolvedEntry)) {
                $pathExtras += $resolvedEntry
            }
        }
    }

    if ($pathExtras.Count -gt 0) {
        $commonRoot = Get-CommonAncestor -Paths $pathExtras
        if ($commonRoot) {
            foreach ($pathEntry in $pathExtras) {
                $relativePath = Get-BundleRuntimeRelativePath -PathValue $pathEntry -CommonRoot $commonRoot
                $destinationPath = Join-Path $bundleRoot $relativePath
                Write-Host "Copying runtime path $pathEntry"
                Copy-Item -LiteralPath $pathEntry -Destination $destinationPath -Recurse -Force
            }
        }
    }

    $manifestPath = Join-Path $bundleRoot "bundle-manifest.txt"
    @(
        "Created: $(Get-Date -Format s)"
        "OSS CAD Suite: $ossCadRoot"
        "nextpnr-xilinx: $nextpnrExe"
        "Project X-Ray: $prjxrayRoot"
        "Project X-Ray DB: $xrayDbRoot"
        "xc7frames2bit: $xc7frames2bitExe"
        "chipdb: $chipdbPath"
    ) | Set-Content -LiteralPath $manifestPath -Encoding ASCII

    if (Test-Path -LiteralPath $outputFullPath) {
        Remove-Item -LiteralPath $outputFullPath -Force
    }

    Write-Host "Creating bundle archive $outputFullPath"
    New-ZipArchiveFromDirectory -SourceDirectory $bundleRoot -DestinationArchive $outputFullPath
    Write-Host "Bundle ready: $outputFullPath"
} finally {
    Remove-DirectoryIfExists -PathValue $stagingRoot
}
