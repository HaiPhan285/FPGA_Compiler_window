[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Command = "help",
    [string]$Project,
    [string]$SourceDir,
    [string]$Top,
    [string]$Constraints,
    [switch]$All,
    [string]$Bitstream,
    [switch]$InstallPackages,
    [switch]$PersistPath,
    [switch]$Ensure,
    [switch]$Force,
    [string]$OutputPath = "",
    [switch]$SkipChipDb,
    [switch]$SkipSetup,
    [switch]$DownloadFullToolchain,
    [switch]$RequireFullBuildTools,
    [string]$Device = "xc7a100t",
    [string]$Part = "xc7a100tcsg324-1"
)

$ErrorActionPreference = "Stop"
$ScriptPath = $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$ToolRoot = Join-Path $RepoRoot ".toolchain\tools"
$ToolBin = Join-Path $ToolRoot "bin"
$BuildRoot = Join-Path $RepoRoot "build"
$ConfigPath = Join-Path $RepoRoot "toolchain.json"
$OpenXc7Root = Join-Path $ToolRoot "openxc7"
$MsysRoot = "C:\msys64"
$MingwBin = Join-Path $MsysRoot "mingw64\bin"
$UsrBin = Join-Path $MsysRoot "usr\bin"
$AppRoot = Join-Path $RepoRoot "app"

function Add-PathEntry {
    param([string]$PathEntry)
    if ((Test-Path $PathEntry) -and (($env:Path -split ';') -notcontains $PathEntry)) {
        $env:Path = "$PathEntry;$env:Path"
    }
}

function Get-Xc7Frames2BitExePath {
    foreach ($Candidate in @(
        (Join-Path $OpenXc7Root "build\prjxray\tools\xc7frames2bit.exe"),
        (Join-Path $OpenXc7Root "src\prjxray\build\tools\xc7frames2bit.exe")
    )) {
        if (Test-Path -LiteralPath $Candidate) {
            return (Resolve-Path -LiteralPath $Candidate).Path
        }
    }
    return $null
}

function Get-ToolPathEntries {
    $Entries = @(
        $ToolBin,
        $OpenXc7Root,
        (Join-Path $OpenXc7Root "oss-cad-suite\bin"),
        (Join-Path $OpenXc7Root "build\prjxray\tools"),
        (Join-Path $OpenXc7Root "src\prjxray\build\tools")
    )
    return @($Entries | Where-Object { $_ })
}

function Get-ToolPathEntriesWithMsys2 {
    $Entries = @(
        $ToolBin,
        $OpenXc7Root,
        (Join-Path $OpenXc7Root "oss-cad-suite\bin"),
        (Join-Path $OpenXc7Root "build\prjxray\tools"),
        (Join-Path $OpenXc7Root "src\prjxray\build\tools"),
        $MingwBin,
        $UsrBin
    )
    return @($Entries | Where-Object { $_ })
}

foreach ($PathEntry in Get-ToolPathEntries) {
    Add-PathEntry $PathEntry
}

function Find-CommandPath {
    param([string[]]$Names, [switch]$Required)
    foreach ($Name in $Names) {
        $CommandInfo = Get-Command $Name -ErrorAction SilentlyContinue
        if ($CommandInfo) { return $CommandInfo.Source }
    }
    if ($Required) { throw "Required tool not found: $($Names -join ' or ')" }
    return $null
}

function Expand-ConfigPath {
    param([string]$PathValue)
    if ([string]::IsNullOrWhiteSpace($PathValue)) { return $null }
    $Expanded = [Environment]::ExpandEnvironmentVariables($PathValue)
    if ([System.IO.Path]::IsPathRooted($Expanded)) {
        return [System.IO.Path]::GetFullPath($Expanded)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $Expanded))
}

function Get-ToolchainConfig {
    if (-not (Test-Path -LiteralPath $ConfigPath)) { return $null }
    return Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json
}

function Get-SharedToolchainBundleRoot {
    $Config = Get-ToolchainConfig
    if (-not $Config) { return $null }

    $SharedRoot = Expand-ConfigPath $Config.sharedToolchainRoot
    if (-not $SharedRoot) { return $null }

    $BundleRoot = Join-Path $SharedRoot "openxc7-bundle"
    if (Test-Path -LiteralPath $BundleRoot) {
        return (Resolve-Path -LiteralPath $BundleRoot).Path
    }

    return $null
}

function Get-PrebuiltBitstreams {
    if (-not (Test-Path -LiteralPath $AppRoot)) { return @() }
    return @(Get-ChildItem -Path $AppRoot -Recurse -File -Filter *.bit -ErrorAction SilentlyContinue | Sort-Object FullName)
}

function Get-GitHubReleaseAsset {
    param($ReleaseConfig)
    if (-not $ReleaseConfig -or [string]::IsNullOrWhiteSpace($ReleaseConfig.repo)) { return $null }

    $Tag = if ([string]::IsNullOrWhiteSpace($ReleaseConfig.tag) -or $ReleaseConfig.tag -eq "latest") {
        "latest"
    } else {
        "tags/$($ReleaseConfig.tag)"
    }
    $Uri = "https://api.github.com/repos/$($ReleaseConfig.repo)/releases/$Tag"
    try {
        $Release = Invoke-RestMethod -Uri $Uri -Headers @{ "User-Agent" = "FPGA-Compiler-Setup" }
    } catch {
        $StatusCode = $_.Exception.Response.StatusCode.value__
        if ($StatusCode -eq 404) {
            throw "GitHub release not found for $($ReleaseConfig.repo) ($Tag). Publish a release asset or configure toolchainBundle.downloadUrl/toolchainBundle.root."
        }
        throw
    }
    $Patterns = @($ReleaseConfig.assetPatterns)
    if ($Patterns.Count -eq 0) { $Patterns = @("*.zip") }

    foreach ($Pattern in $Patterns) {
        $Asset = @($Release.assets | Where-Object { $_.name -like $Pattern } | Sort-Object name | Select-Object -First 1)
        if ($Asset.Count -gt 0) { return $Asset[0] }
    }

    throw "No release asset matched $($Patterns -join ', ') in $($ReleaseConfig.repo) ($Tag). Publish the bundle with one of those names or configure toolchainBundle.downloadUrl."
}

function Expand-ArchiveToOpenXc7Root {
    param([string]$ArchivePath)

    $ExtractRoot = Join-Path $ToolRoot "_openxc7_extract"
    if (Test-Path -LiteralPath $ExtractRoot) { Remove-Item -LiteralPath $ExtractRoot -Recurse -Force }
    Expand-Archive -LiteralPath $ArchivePath -DestinationPath $ExtractRoot -Force

    $CandidateRoots = @($ExtractRoot) + @(Get-ChildItem -Path $ExtractRoot -Directory -Recurse -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
    $DetectedRoot = $CandidateRoots | Where-Object { Test-Path (Join-Path $_ "nextpnr-xilinx.exe") } | Select-Object -First 1
    if (-not $DetectedRoot) { throw "Downloaded bundle did not contain nextpnr-xilinx.exe." }

    if (Test-Path -LiteralPath $OpenXc7Root) { Remove-Item -LiteralPath $OpenXc7Root -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $OpenXc7Root | Out-Null
    Copy-Item -Path (Join-Path $DetectedRoot "*") -Destination $OpenXc7Root -Recurse -Force
    Remove-Item -LiteralPath $ExtractRoot -Recurse -Force
}

function Install-OpenXc7Bundle {
    param([switch]$Force)
    $Config = Get-ToolchainConfig
    if (-not $Config -or -not ($Config.autoDownload -or $DownloadFullToolchain -or $Ensure -or $RequireFullBuildTools -or $Force)) { return }

    if ((Find-CommandPath @("nextpnr-xilinx.exe", "nextpnr-xilinx")) -and
        (Find-CommandPath @("fasm2frames.exe", "fasm2frames")) -and
        (Find-CommandPath @("xc7frames2bit.exe", "xc7frames2bit")) -and
        (Find-ChipDb $Device) -and
        (Find-PrjxrayDb)) {
        return
    }

    if ((Test-Path (Join-Path $OpenXc7Root "nextpnr-xilinx.exe")) -and
        (Get-Xc7Frames2BitExePath)) {
        return
    }

    $BundleRoot = Expand-ConfigPath $Config.toolchainBundle.root
    if ($BundleRoot -and (Test-Path -LiteralPath $BundleRoot)) {
        New-Item -ItemType Directory -Force -Path $OpenXc7Root | Out-Null
        Copy-Item -Path (Join-Path $BundleRoot "*") -Destination $OpenXc7Root -Recurse -Force
        return
    }

    $SharedBundleRoot = Get-SharedToolchainBundleRoot
    if ($SharedBundleRoot) {
        New-Item -ItemType Directory -Force -Path $OpenXc7Root | Out-Null
        Copy-Item -Path (Join-Path $SharedBundleRoot "*") -Destination $OpenXc7Root -Recurse -Force
        return
    }

    $BundleDownloadUrl = $Config.toolchainBundle.downloadUrl
    if (-not [string]::IsNullOrWhiteSpace($BundleDownloadUrl)) {
        New-Item -ItemType Directory -Force -Path $ToolRoot | Out-Null
        $ArchiveName = $Config.toolchainBundle.archiveName
        if ([string]::IsNullOrWhiteSpace($ArchiveName)) {
            try {
                $ArchiveName = [System.IO.Path]::GetFileName(([System.Uri]$BundleDownloadUrl).AbsolutePath)
            } catch {
                $ArchiveName = "openxc7-toolchain.zip"
            }
        }
        $ArchivePath = Join-Path $ToolRoot $ArchiveName
        Write-Host "Downloading openXC7 toolchain bundle: $BundleDownloadUrl"
        Invoke-WebRequest -Uri $BundleDownloadUrl -OutFile $ArchivePath
        Expand-ArchiveToOpenXc7Root -ArchivePath $ArchivePath
        return
    }

    $Asset = Get-GitHubReleaseAsset $Config.toolchainBundle.githubRelease
    New-Item -ItemType Directory -Force -Path $ToolRoot | Out-Null
    $ArchivePath = Join-Path $ToolRoot $Asset.name
    Write-Host "Downloading openXC7 toolchain bundle: $($Asset.name)"
    Invoke-WebRequest -Uri $Asset.browser_download_url -OutFile $ArchivePath
    Expand-ArchiveToOpenXc7Root -ArchivePath $ArchivePath
}

function Write-CommandShim {
    param([string]$Name, [string]$Target, [string]$Prefix = "")
    if (-not (Test-Path -LiteralPath $Target)) { return }
    $Shim = Join-Path $ToolBin "$Name.bat"
    $Lines = @(
        "@echo off",
        "$Prefix `"$Target`" %*"
    )
    Set-Content -LiteralPath $Shim -Value $Lines -Encoding ASCII
}

function Install-OpenXc7Shims {
    $Python = $null
    $PythonCandidates = @(
        (Join-Path $RepoRoot ".toolchain\prjxray-venv\bin\python.exe"),
        (Join-Path $MingwBin "python.exe"),
        (Join-Path $MingwBin "python3.exe"),
        (Join-Path $OpenXc7Root "oss-cad-suite\bin\python.exe"),
        (Join-Path $OpenXc7Root "oss-cad-suite\bin\python3.exe"),
        (Find-CommandPath @("python.exe", "python", "python3.exe", "python3"))
    ) | Where-Object { $_ }

    foreach ($Candidate in $PythonCandidates) {
        if (Test-Path -LiteralPath $Candidate) {
            $Python = (Resolve-Path -LiteralPath $Candidate).Path
            break
        }
    }

    Write-CommandShim -Name "nextpnr-xilinx" -Target (Join-Path $OpenXc7Root "nextpnr-xilinx.exe")
    Write-CommandShim -Name "xc7frames2bit" -Target (Get-Xc7Frames2BitExePath)

    $Fasm2FramesExe = Join-Path $OpenXc7Root "fasm2frames.exe"
    $Fasm2FramesPy = Join-Path $OpenXc7Root "src\prjxray\utils\fasm2frames.py"
    if (Test-Path -LiteralPath $Fasm2FramesExe) {
        Write-CommandShim -Name "fasm2frames" -Target $Fasm2FramesExe
    } elseif ($Python -and (Test-Path -LiteralPath $Fasm2FramesPy)) {
        $PrjxrayRoot = Get-PrjxrayRootPath
        $PythonPaths = @(
            $PrjxrayRoot,
            (Join-Path $PrjxrayRoot "utils"),
            (Join-Path $PrjxrayRoot "third_party\fasm")
        ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
        $Shim = Join-Path $ToolBin "fasm2frames.bat"
        $Lines = @(
            "@echo off",
            "set `"PYTHONPATH=$(($PythonPaths -join ';'));%PYTHONPATH%`"",
            "`"$Python`" `"$Fasm2FramesPy`" %*"
        )
        Set-Content -LiteralPath $Shim -Value $Lines -Encoding ASCII
    }
}

function Get-OssCadRoot {
    $Config = Get-ToolchainConfig
    $ConfiguredRoot = $null
    if ($Config -and $Config.ossCadSuite) {
        $ConfiguredRoot = Expand-ConfigPath $Config.ossCadSuite.root
    }

    foreach ($Candidate in @(
        $ConfiguredRoot,
        (Join-Path $OpenXc7Root "oss-cad-suite"),
        (Join-Path $ToolRoot "oss-cad-suite")
    ) | Where-Object { $_ }) {
        if (Test-Path -LiteralPath $Candidate) {
            return (Resolve-Path -LiteralPath $Candidate).Path
        }
    }

    return $null
}

function Get-PrjxrayRootPath {
    foreach ($Candidate in @(
        (Join-Path $OpenXc7Root "src\prjxray"),
        (Join-Path $RepoRoot "_openxc7_src\prjxray")
    )) {
        if (Test-Path -LiteralPath $Candidate) {
            return (Resolve-Path -LiteralPath $Candidate).Path
        }
    }

    return $null
}

function Write-ToolchainEnv {
    $EnvFile = Join-Path $RepoRoot ".toolchain\env.bat"
    $NextpnrExe = Find-CommandPath @("nextpnr-xilinx.exe", "nextpnr-xilinx")
    $Fasm2Frames = Find-CommandPath @("fasm2frames.exe", "fasm2frames")
    $Frames2Bit = Find-CommandPath @("xc7frames2bit.exe", "xc7frames2bit")
    $ChipDbPath = Find-ChipDb $Device
    $PrjxrayDbRoot = Find-PrjxrayDb
    $PrjxrayRoot = Get-PrjxrayRootPath
    $PrjxrayUtils = if ($PrjxrayRoot) { Join-Path $PrjxrayRoot "utils" } else { $null }

    $Values = [ordered]@{
        "OSS_CAD" = Get-OssCadRoot
        "NEXTPNR_EXE" = $NextpnrExe
        "PRJXRAY_UTILS" = $PrjxrayUtils
        "XRAY_DB_ROOT" = if ($PrjxrayDbRoot) { Join-Path $PrjxrayDbRoot "artix7" } else { $null }
        "XC7FRAMES2BIT_EXE" = $Frames2Bit
        "FASM2FRAMES_EXE" = $Fasm2Frames
        "CHIPDB" = $ChipDbPath
        "PATH" = (@(Get-ToolPathEntries | Where-Object { Test-Path $_ }) -join ';')
    }

    $Lines = @("@echo off")
    foreach ($Item in $Values.GetEnumerator()) {
        if (-not [string]::IsNullOrWhiteSpace($Item.Value)) {
            $Lines += "set `"$($Item.Key)=$($Item.Value)`""
        }
    }

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $EnvFile) | Out-Null
    Set-Content -LiteralPath $EnvFile -Value $Lines -Encoding ASCII
}

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
    $PathValue = Join-Path ([System.IO.Path]::GetTempPath()) ("fpga-bundle-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $PathValue | Out-Null
    return $PathValue
}

function Get-BatchEnvironmentValues {
    param([string]$FilePath)
    $Values = @{}
    foreach ($Line in Get-Content -LiteralPath $FilePath) {
        if ($Line -match '^set "(?<name>[^=]+)=(?<value>.*)"$') {
            $Values[$matches.name] = $matches.value
        }
    }
    return $Values
}

function Resolve-ExistingPath {
    param([string]$PathValue)
    if ([string]::IsNullOrWhiteSpace($PathValue)) { return $null }
    if (-not (Test-Path -LiteralPath $PathValue)) { return $null }
    return [System.IO.Path]::GetFullPath($PathValue)
}

function Get-CommonAncestor {
    param([string[]]$Paths)

    $NormalizedPaths = @($Paths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object {
        ([System.IO.Path]::GetFullPath($_).TrimEnd('\'))
    })
    if ($NormalizedPaths.Count -eq 0) { return $null }
    if ($NormalizedPaths.Count -eq 1) { return $NormalizedPaths[0] }

    $Common = $NormalizedPaths[0]
    foreach ($PathValue in $NormalizedPaths[1..($NormalizedPaths.Count - 1)]) {
        while ($Common -and -not $PathValue.StartsWith($Common, [System.StringComparison]::OrdinalIgnoreCase)) {
            $Common = Split-Path -Parent $Common
        }
    }
    return $Common
}

function Get-RelativePath {
    param([string]$BasePath, [string]$PathValue)

    $BaseFull = [System.IO.Path]::GetFullPath($BasePath).TrimEnd('\', '/')
    $PathFull = [System.IO.Path]::GetFullPath($PathValue).TrimEnd('\', '/')
    if ($PathFull.Equals($BaseFull, [System.StringComparison]::OrdinalIgnoreCase)) { return "." }

    $BasePrefix = $BaseFull + [System.IO.Path]::DirectorySeparatorChar
    if (-not $PathFull.StartsWith($BasePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Path '$PathFull' is not under base path '$BaseFull'"
    }
    return $PathFull.Substring($BasePrefix.Length)
}

function Get-BundleRuntimeRelativePath {
    param([string]$PathValue, [string]$CommonRoot)

    $PathFull = [System.IO.Path]::GetFullPath($PathValue).TrimEnd('\', '/')
    $Parts = $PathFull -split '[\\/]'
    for ($Index = 0; $Index -lt $Parts.Count; $Index++) {
        if ($Parts[$Index].Equals("msys64", [System.StringComparison]::OrdinalIgnoreCase)) {
            return ($Parts[$Index..($Parts.Count - 1)] -join [System.IO.Path]::DirectorySeparatorChar)
        }
    }

    return Get-RelativePath -BasePath $CommonRoot -PathValue $PathValue
}

function New-ZipArchiveFromDirectory {
    param([string]$SourceDirectory, [string]$DestinationArchive)

    $TarCommand = Get-Command "tar.exe" -ErrorAction SilentlyContinue
    if ($TarCommand) {
        & $TarCommand.Source -a -cf $DestinationArchive -C $SourceDirectory .
        if ($LASTEXITCODE -ne 0) {
            throw "tar.exe failed with exit code $LASTEXITCODE while creating $DestinationArchive"
        }
        return
    }

    $SourceSize = (Get-ChildItem -LiteralPath $SourceDirectory -Recurse -File | Measure-Object -Property Length -Sum).Sum
    if ($SourceSize -gt 2GB) {
        throw "tar.exe was not found, and Compress-Archive is not safe here because Microsoft documents a 2GB ZipArchive limit."
    }

    Compress-Archive -Path (Join-Path $SourceDirectory "*") -DestinationPath $DestinationArchive -CompressionLevel Fastest -Force
}

function Get-ToolStatus {
    $Checks = [ordered]@{
        "yosys" = @(Find-CommandPath @("yosys.exe", "yosys"))
        "nextpnr-xilinx" = @(Find-CommandPath @("nextpnr-xilinx.exe", "nextpnr-xilinx"))
        "fasm2frames" = @(Find-CommandPath @("fasm2frames.exe", "fasm2frames"))
        "xc7frames2bit" = @(Find-CommandPath @("xc7frames2bit.exe", "xc7frames2bit"))
        "openFPGALoader" = @(Find-CommandPath @("openFPGALoader.exe", "openFPGALoader"))
        "python" = @(Find-CommandPath @("python.exe", "python", "python3.exe", "python3"))
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

    $ChipDb = Find-ChipDb $Device
    if ($ChipDb) {
        Write-Host ("[OK]   chipdb-{0}.bin: {1}" -f $Device, $ChipDb)
    } else {
        Write-Host ("[MISS] chipdb-{0}.bin" -f $Device)
        $Missing += "chipdb-$Device.bin"
    }

    $PrjxrayDb = Find-PrjxrayDb
    if ($PrjxrayDb) {
        Write-Host ("[OK]   prjxray-db: {0}" -f $PrjxrayDb)
    } else {
        Write-Host "[MISS] prjxray-db"
        $Missing += "prjxray-db"
    }

    return @{
        Missing = $Missing
        HasYosys = $Missing -notcontains "yosys"
        HasOpenFpgaLoader = $Missing -notcontains "openFPGALoader"
        HasFullBuildTools = ($Missing -notcontains "nextpnr-xilinx") -and ($Missing -notcontains "fasm2frames") -and ($Missing -notcontains "xc7frames2bit") -and ($Missing -notcontains "chipdb-$Device.bin") -and ($Missing -notcontains "prjxray-db")
    }
}

function Get-ProjectDirs {
    if (-not (Test-Path $AppRoot)) { return @() }
    return @(Get-ChildItem -Path $AppRoot -Directory | Where-Object {
        @(Get-ChildItem -Path $_.FullName -File | Where-Object { $_.Extension -in @(".v", ".sv") }).Count -gt 0 -and
        @(Get-ChildItem -Path $_.FullName -File -Filter *.xdc).Count -gt 0
    })
}

function Select-FirstFile {
    param([string]$Dir, [string[]]$Names, [string[]]$Extensions)
    foreach ($Name in $Names) {
        foreach ($Ext in $Extensions) {
            $Candidate = Join-Path $Dir "$Name$Ext"
            if (Test-Path $Candidate) { return (Resolve-Path $Candidate).Path }
        }
    }
    $Files = @(Get-ChildItem -Path $Dir -File | Where-Object { $Extensions -contains $_.Extension } | Sort-Object Name)
    if ($Files.Count -ge 1) { return $Files[0].FullName }
    return $null
}

function Get-TopModule {
    param([string]$SourceFile)
    $Text = Get-Content -Raw -Path $SourceFile
    $Match = [regex]::Match($Text, '(?m)^\s*module\s+([A-Za-z_][A-Za-z0-9_]*)\b')
    if ($Match.Success) { return $Match.Groups[1].Value }
    return $null
}

function Invoke-Checked {
    param([string]$Exe, [string[]]$ArgsList, [string]$LogFile)
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $LogFile) | Out-Null
    $PreviousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & $Exe @ArgsList *> $LogFile
        $ExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $PreviousErrorActionPreference
    }
    if ($ExitCode -ne 0) {
        if (Test-Path -LiteralPath $LogFile) {
            Write-Host ""
            Write-Host "Last log lines from $LogFile"
            Get-Content -LiteralPath $LogFile -Tail 40 | ForEach-Object { Write-Host $_ }
            Write-Host ""
        }
        throw "Command failed: $Exe $($ArgsList -join ' '). See $LogFile"
    }
}

function Find-ChipDb {
    param([string]$DeviceName)
    $Candidates = @(
        (Join-Path $ToolBin "..\share\nextpnr\xilinx\chipdb-$DeviceName.bin"),
        (Join-Path $RepoRoot ".toolchain\tools\share\nextpnr\xilinx\chipdb-$DeviceName.bin"),
        (Join-Path $OpenXc7Root "share\nextpnr\xilinx\chipdb-$DeviceName.bin"),
        (Join-Path $OpenXc7Root "tools\chipdb-$DeviceName.bin"),
        (Join-Path $OpenXc7Root "tools\$DeviceName.bin"),
        "C:\msys64\mingw64\share\nextpnr\xilinx\chipdb-$DeviceName.bin",
        (Join-Path $env:LOCALAPPDATA "nextpnr\xilinx\chipdb-$DeviceName.bin")
    )
    foreach ($Candidate in $Candidates) {
        $Resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Candidate)
        if (Test-Path $Resolved) { return $Resolved }
    }
    return $null
}

function Find-PrjxrayDb {
    $Candidates = @(
        $env:PRJXRAY_DB_DIR,
        (Join-Path $RepoRoot ".toolchain\prjxray-db"),
        (Join-Path $OpenXc7Root "src\prjxray-db"),
        (Join-Path $RepoRoot "_openxc7_src\prjxray-db"),
        "C:\msys64\mingw64\share\prjxray-db"
    ) | Where-Object { $_ }
    foreach ($Candidate in $Candidates) {
        if (Test-Path $Candidate) { return (Resolve-Path $Candidate).Path }
    }
    return $null
}

function Resolve-BitstreamFile {
    param([string]$RequestedBitstream, [string]$ProjectName)

    $SearchRoots = @($AppRoot, $BuildRoot) | Where-Object { Test-Path $_ }

    if ($RequestedBitstream) {
        $Candidate = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RequestedBitstream)
        if (Test-Path -LiteralPath $Candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $Candidate).Path
        }

        $RequestedName = Split-Path -Leaf $RequestedBitstream
        $Matches = @($SearchRoots | ForEach-Object {
            Get-ChildItem -Path $_ -Recurse -File -Filter $RequestedName -ErrorAction SilentlyContinue
        } | Sort-Object FullName)

        $Hint = ""
        if ($Matches.Count -gt 0) {
            $Hint = "`nDid you mean: $($Matches[0].FullName)"
        }

        throw "Bitstream not found: $RequestedBitstream$Hint`nRun .\fpga.bat build -Project <name> and make sure it reaches '[OK] Bitstream complete'. If the build says '.bit generation skipped', install nextpnr-xilinx, fasm2frames, xc7frames2bit, and prjxray-db."
    }

    if ($ProjectName) {
        $ProjectBits = @(
            (Join-Path $AppRoot "$ProjectName\$ProjectName.bit"),
            (Join-Path $BuildRoot "$ProjectName\$ProjectName.bit")
        )
        foreach ($ProjectBit in $ProjectBits) {
            $Candidate = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ProjectBit)
            if (Test-Path -LiteralPath $Candidate -PathType Leaf) {
                return (Resolve-Path -LiteralPath $Candidate).Path
            }
        }

        $Matches = @($SearchRoots | ForEach-Object {
            Get-ChildItem -Path $_ -Recurse -File -Filter *.bit -ErrorAction SilentlyContinue | Where-Object {
                $_.Directory.Name -eq $ProjectName -or $_.BaseName -eq $ProjectName
            }
        } | Sort-Object @{ Expression = "LastWriteTime"; Descending = $true }, FullName)

        if ($Matches.Count -gt 0) {
            return $Matches[0].FullName
        }

        throw "No .bit file found for project '$ProjectName'. Expected app\$ProjectName\$ProjectName.bit or build\$ProjectName\$ProjectName.bit. Run .\fpga.bat build -Project $ProjectName and make sure it reaches '[OK] Bitstream complete', or add a prebuilt .bit to app\$ProjectName\."
    }

    $Bits = @($SearchRoots | ForEach-Object {
        Get-ChildItem -Path $_ -Recurse -File -Filter *.bit -ErrorAction SilentlyContinue
    } | Sort-Object @{ Expression = "LastWriteTime"; Descending = $true }, FullName)

    if ($Bits.Count -eq 0) {
        throw "No .bit files found under app\ or build\. Run .\fpga.bat build -Project <name> and make sure it reaches '[OK] Bitstream complete'. If the build says '.bit generation skipped', install nextpnr-xilinx, fasm2frames, xc7frames2bit, and prjxray-db."
    }

    return $Bits[0].FullName
}

function Build-OneProject {
    param([string]$ProjectDir)

    $ProjectName = if ($Project) { $Project } else { Split-Path -Leaf $ProjectDir }
    $SourceFile = Select-FirstFile -Dir $ProjectDir -Names @("top", $ProjectName, "main") -Extensions @(".sv", ".v")
    if (-not $SourceFile) { throw "No .v or .sv source file found in $ProjectDir" }

    $TopName = if ($Top) { $Top } else { Get-TopModule $SourceFile }
    if (-not $TopName) { throw "Could not detect a top module in $SourceFile" }

    $SourceBase = [System.IO.Path]::GetFileNameWithoutExtension($SourceFile)
    $XdcFile = if ($Constraints) { (Resolve-Path $Constraints).Path } else { Select-FirstFile -Dir $ProjectDir -Names @($SourceBase, $ProjectName, "constraints", "top") -Extensions @(".xdc") }
    if (-not $XdcFile) { throw "No .xdc constraints file found in $ProjectDir" }

    $Yosys = Find-CommandPath @("yosys.exe", "yosys") -Required
    $Nextpnr = Find-CommandPath @("nextpnr-xilinx.exe", "nextpnr-xilinx")
    $Fasm2Frames = Find-CommandPath @("fasm2frames.exe", "fasm2frames")
    $Frames2Bit = Find-CommandPath @("xc7frames2bit.exe", "xc7frames2bit")

    $ProjectBuild = Join-Path $BuildRoot $ProjectName
    New-Item -ItemType Directory -Force -Path $ProjectBuild | Out-Null
    $Json = Join-Path $ProjectBuild "$ProjectName.json"
    $Fasm = Join-Path $ProjectBuild "$ProjectName.fasm"
    $Frames = Join-Path $ProjectBuild "$ProjectName.frames"
    $Bit = Join-Path $ProjectBuild "$ProjectName.bit"

    Write-Host ""
    Write-Host "====== Building $ProjectName ======"
    Write-Host "Source     : $SourceFile"
    Write-Host "Top        : $TopName"
    Write-Host "Constraints: $XdcFile"
    Write-Host "Target     : Nexys A7-100T ($Part)"
    Write-Host "Logs       : $ProjectBuild"
    Write-Host ""

    $SourceArgs = @(Get-ChildItem -Path $ProjectDir -File | Where-Object { $_.Extension -in @(".v", ".sv") } | Sort-Object Name | ForEach-Object { '"' + $_.FullName + '"' })
    $YosysScript = "read_verilog -sv $($SourceArgs -join ' '); hierarchy -check -top $TopName; synth_xilinx -family xc7 -flatten -top $TopName -nocarry; write_json `"$Json`""
    Invoke-Checked $Yosys @("-p", $YosysScript) (Join-Path $ProjectBuild "yosys.log")

    if (-not $Nextpnr) {
        Write-Host "[OK] Synthesis complete: $Json"
        Write-Host "[SKIP] nextpnr-xilinx not found; bitstream generation skipped."
        return
    }

    $ChipDb = Find-ChipDb $Device
    if (-not $ChipDb) {
        Write-Host "[OK] Synthesis complete: $Json"
        Write-Host "[SKIP] chipdb-$Device.bin not found; place-and-route skipped."
        return
    }

    Invoke-Checked $Nextpnr @("--chipdb", $ChipDb, "--json", $Json, "--xdc", $XdcFile, "--fasm", $Fasm, "--verbose") (Join-Path $ProjectBuild "nextpnr.log")

    if (-not ($Fasm2Frames -and $Frames2Bit)) {
        Write-Host "[OK] Place-and-route complete: $Fasm"
        Write-Host "[SKIP] prjxray bitstream tools not found; .bit generation skipped."
        return
    }

    $PrjxrayDb = Find-PrjxrayDb
    if (-not $PrjxrayDb) {
        Write-Host "[OK] Place-and-route complete: $Fasm"
        Write-Host "[SKIP] prjxray-db not found; .bit generation skipped."
        return
    }

    $DbRoot = Join-Path $PrjxrayDb "artix7"
    $PartYaml = Join-Path $DbRoot "$Part\part.yaml"
    Invoke-Checked $Fasm2Frames @("--db-root", $DbRoot, "--part", $Part, $Fasm, $Frames) (Join-Path $ProjectBuild "fasm2frames.log")
    Invoke-Checked $Frames2Bit @("--part_file", $PartYaml, "--part_name", $Part, "--frm_file", $Frames, "--output_file", $Bit) (Join-Path $ProjectBuild "xc7frames2bit.log")

    Copy-Item -Force $Bit (Join-Path $ProjectDir "$ProjectName.bit")
    Write-Host "[OK] Bitstream complete: $Bit"
}

function Ensure-FullBuildToolchain {
    $MissingTools = @()
    foreach ($ToolName in @("nextpnr-xilinx", "fasm2frames", "xc7frames2bit")) {
        if (-not (Find-CommandPath @("$ToolName.exe", $ToolName))) {
            $MissingTools += $ToolName
        }
    }

    $MissingAssets = @()
    if (-not (Find-ChipDb $Device)) { $MissingAssets += "chipdb-$Device.bin" }
    if (-not (Find-PrjxrayDb)) { $MissingAssets += "prjxray-db" }

    if ($MissingTools.Count -eq 0 -and $MissingAssets.Count -eq 0) { return }

    Write-Host "Preparing full bitstream toolchain..."
    try {
        Install-OpenXc7Bundle -Force
        Install-OpenXc7Shims
    } catch {
        throw "Unable to prepare full bitstream toolchain automatically: $($_.Exception.Message)`nRun .\fpga.bat setup -DownloadFullToolchain and retry."
    }

    $StillMissing = @()
    foreach ($ToolName in @("nextpnr-xilinx", "fasm2frames", "xc7frames2bit")) {
        if (-not (Find-CommandPath @("$ToolName.exe", $ToolName))) {
            $StillMissing += $ToolName
        }
    }
    if (-not (Find-ChipDb $Device)) { $StillMissing += "chipdb-$Device.bin" }
    if (-not (Find-PrjxrayDb)) { $StillMissing += "prjxray-db" }

    if ($StillMissing.Count -gt 0) {
        throw "Bitstream generation requires the full toolchain, but these components are still missing: $($StillMissing -join ', ')`nRun .\fpga.bat setup -DownloadFullToolchain and retry."
    }
}

function Invoke-Setup {
    New-Item -ItemType Directory -Force -Path $ToolBin, $BuildRoot | Out-Null
    
    if ($InstallPackages) {
        $Pacman = Join-Path $UsrBin "pacman.exe"
        if (-not (Test-Path $Pacman)) {
            throw "MSYS2 was not found at $MsysRoot. Install MSYS2 from https://www.msys2.org, then rerun setup."
        }
        
        foreach ($PathEntry in Get-ToolPathEntriesWithMsys2) {
            Add-PathEntry $PathEntry
        }
    } else {
        foreach ($PathEntry in Get-ToolPathEntries) {
            Add-PathEntry $PathEntry
        }
    }

    Write-Host ""
    Write-Host "====== FPGA Setup ======"
    Write-Host ""

    if ($InstallPackages) {
        $Pacman = Join-Path $UsrBin "pacman.exe"
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

    $Config = Get-ToolchainConfig
    $ExpectFullBuildSetup = ($null -ne $Config -and $Config.autoDownload) -or $DownloadFullToolchain -or $Ensure -or $RequireFullBuildTools

    try {
        Install-OpenXc7Bundle
        Install-OpenXc7Shims
    } catch {
        if ($ExpectFullBuildSetup) { throw }
        Write-Host "openXC7 auto-install skipped: $($_.Exception.Message)"
    }

    if ($PersistPath) {
        $UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
        $PathEntries = if ($InstallPackages) { Get-ToolPathEntriesWithMsys2 } else { Get-ToolPathEntries }
        foreach ($Entry in $PathEntries) {
            if ((Test-Path $Entry) -and (($UserPath -split ';') -notcontains $Entry)) {
                $UserPath = "$Entry;$UserPath"
            }
        }
        [Environment]::SetEnvironmentVariable("Path", $UserPath, "User")
        Write-Host "Updated user PATH. Open a new terminal for persistent PATH changes."
    }

    $Status = Get-ToolStatus
    Write-ToolchainEnv
    $PrebuiltBitstreams = Get-PrebuiltBitstreams
    $LiteReady = $Status.HasOpenFpgaLoader -and $PrebuiltBitstreams.Count -gt 0

    Write-Host ""
    if ($Status.Missing.Count -eq 0) {
        Write-Host "Setup complete. Run: .\fpga.bat build"
        return
    }

    Write-Host "Missing tools: $($Status.Missing -join ', ')"
    Write-Host ""
    if (-not $Status.HasYosys -or -not $Status.HasFullBuildTools) {
        Write-Host "Setup did not finish with a complete bitstream build toolchain."
        Write-Host "Expected build tools: yosys, nextpnr-xilinx, fasm2frames, xc7frames2bit, chipdb, prjxray-db."
        exit 1
    }

    if ($LiteReady) {
        Write-Host "Build toolchain is ready."
        Write-Host "You can also flash a prebuilt project:"
        Write-Host "  .\fpga.bat flash -Project $($PrebuiltBitstreams[0].Directory.Name)"
        return
    }

    Write-Host "Build toolchain is ready."
}

function Invoke-Build {
    Ensure-FullBuildToolchain
    $Projects = @(Get-ProjectDirs)

    if ($All) {
        foreach ($Dir in $Projects) { Build-OneProject $Dir.FullName }
        return
    }

    if ($SourceDir) {
        Build-OneProject (Resolve-Path $SourceDir).Path
        return
    }

    if ($Project) {
        $Match = $Projects | Where-Object { $_.Name -eq $Project } | Select-Object -First 1
        if (-not $Match) { throw "Project not found under app\: $Project" }
        Build-OneProject $Match.FullName
        return
    }

    if ($Projects.Count -eq 0) { throw "No buildable projects found in app\" }
    if ($Projects.Count -eq 1) {
        Build-OneProject $Projects[0].FullName
        return
    }

    Write-Host "Available projects:"
    for ($Index = 0; $Index -lt $Projects.Count; $Index++) {
        Write-Host ("  [{0}] {1}" -f ($Index + 1), $Projects[$Index].Name)
    }
    $Choice = Read-Host "Select project number"
    if (-not ($Choice -as [int]) -or [int]$Choice -lt 1 -or [int]$Choice -gt $Projects.Count) {
        throw "Invalid project selection."
    }
    Build-OneProject $Projects[[int]$Choice - 1].FullName
}

function Invoke-Flash {
    $Loader = Find-CommandPath @("openFPGALoader.exe", "openFPGALoader") -Required
    $ResolvedBitstream = Resolve-BitstreamFile $Bitstream $Project
    Write-Host "Flashing bitstream: $ResolvedBitstream"
    Invoke-Checked $Loader @("-b", "nexys_a7_100", $ResolvedBitstream) (Join-Path $BuildRoot "flash.log")
}

function Show-Projects {
    $Projects = @(Get-ProjectDirs)
    if ($Projects.Count -eq 0) {
        Write-Host "No buildable projects found in app\"
        return
    }

    Write-Host "Projects:"
    foreach ($ProjectDir in $Projects) {
        $BitPath = Join-Path $ProjectDir.FullName "$($ProjectDir.Name).bit"
        $HasBit = if (Test-Path -LiteralPath $BitPath) { "prebuilt bitstream" } else { "source only" }
        Write-Host ("  - {0} ({1})" -f $ProjectDir.Name, $HasBit)
    }
}

function Invoke-Doctor {
    New-Item -ItemType Directory -Force -Path $ToolBin, $BuildRoot | Out-Null
    foreach ($PathEntry in Get-ToolPathEntries) {
        Add-PathEntry $PathEntry
    }

    Write-Host ""
    Write-Host "====== FPGA Doctor ======"
    Write-Host ""
    Write-Host "Repository : $RepoRoot"
    Write-Host "App Root   : $AppRoot"
    Write-Host "Build Root : $BuildRoot"
    Write-Host "Device     : $Device"
    Write-Host "Part       : $Part"
    Write-Host ""

    $Status = Get-ToolStatus
    Write-ToolchainEnv
    Write-Host ""
    if ($Status.Missing.Count -eq 0) {
        Write-Host "Status     : ready"
        Write-Host "Next step  : .\fpga.bat build -Project <name>"
        return
    }

    Write-Host "Status     : incomplete"
    Write-Host "Missing    : $($Status.Missing -join ', ')"
    Write-Host ""
    if (-not $Status.HasYosys) {
        Write-Host "Fix        : install Yosys with .\fpga.bat setup -InstallPackages or add yosys.exe to PATH."
    }
    if (-not $Status.HasFullBuildTools) {
        Write-Host "Fix        : publish or configure the Windows toolchain bundle, then rerun .\fpga.bat setup."
    }
    if (-not $Status.HasOpenFpgaLoader) {
        Write-Host "Optional   : install openFPGALoader if you want to flash from this machine."
    }
}

function Invoke-PackageToolchain {
    $EnvFile = Join-Path $RepoRoot ".toolchain\env.bat"

    if (-not $SkipSetup -and -not (Test-Path -LiteralPath $EnvFile)) {
        & powershell -ExecutionPolicy Bypass -File $ScriptPath setup -Ensure -DownloadFullToolchain
        if ($LASTEXITCODE -ne 0) {
            throw "Toolchain setup failed with exit code $LASTEXITCODE"
        }
    }

    if (-not (Test-Path -LiteralPath $EnvFile)) {
        throw "Toolchain environment file not found: $EnvFile. Run .\fpga.bat setup on a machine with the full toolchain installed, or rerun .\fpga.bat package without -SkipSetup."
    }

    $EnvValues = Get-BatchEnvironmentValues -FilePath $EnvFile
    $OssCadRoot = Resolve-ExistingPath $EnvValues.OSS_CAD
    $NextpnrExe = Resolve-ExistingPath $EnvValues.NEXTPNR_EXE
    $PrjxrayUtils = Resolve-ExistingPath $EnvValues.PRJXRAY_UTILS
    $XrayDbRoot = Resolve-ExistingPath $EnvValues.XRAY_DB_ROOT
    $Xc7frames2bitExe = Resolve-ExistingPath $EnvValues.XC7FRAMES2BIT_EXE
    $ChipDbPath = if ($SkipChipDb) { $null } else { Resolve-ExistingPath $EnvValues.CHIPDB }

    if (-not $OssCadRoot) { throw "OSS_CAD was not resolved from $EnvFile" }
    if (-not $NextpnrExe) { throw "NEXTPNR_EXE was not resolved from $EnvFile" }
    if (-not $PrjxrayUtils) { throw "PRJXRAY_UTILS was not resolved from $EnvFile" }
    if (-not $XrayDbRoot) { throw "XRAY_DB_ROOT was not resolved from $EnvFile" }
    if (-not $Xc7frames2bitExe) { throw "XC7FRAMES2BIT_EXE was not resolved from $EnvFile" }

    $PrjxrayRoot = if ((Split-Path -Leaf $PrjxrayUtils).Equals("utils", [System.StringComparison]::OrdinalIgnoreCase)) {
        Split-Path -Parent $PrjxrayUtils
    } else {
        $PrjxrayUtils
    }
    $PrjxrayRoot = Resolve-ExistingPath $PrjxrayRoot
    if (-not $PrjxrayRoot) {
        throw "Could not infer Project X-Ray root from PRJXRAY_UTILS=$PrjxrayUtils"
    }

    $ResolvedOutputPath = if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        Join-Path $RepoRoot "dist\nexys-a7-100t-toolchain-windows.zip"
    } elseif ([System.IO.Path]::IsPathRooted($OutputPath)) {
        [System.IO.Path]::GetFullPath($OutputPath)
    } else {
        [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $OutputPath))
    }
    Ensure-Directory -PathValue (Split-Path -Parent $ResolvedOutputPath)

    if ((Test-Path -LiteralPath $ResolvedOutputPath) -and -not $Force) {
        throw "Output archive already exists: $ResolvedOutputPath. Re-run with -Force to overwrite it."
    }

    $StagingRoot = New-TemporaryDirectory
    $BundleRoot = Join-Path $StagingRoot "toolchain"

    try {
        Ensure-Directory -PathValue $BundleRoot

        Write-Host "Copying OSS CAD Suite from $OssCadRoot"
        Copy-Item -LiteralPath $OssCadRoot -Destination (Join-Path $BundleRoot "oss-cad-suite") -Recurse -Force

        Write-Host "Copying nextpnr-xilinx from $NextpnrExe"
        Copy-Item -LiteralPath $NextpnrExe -Destination (Join-Path $BundleRoot "nextpnr-xilinx.exe") -Force

        Write-Host "Copying Project X-Ray from $PrjxrayRoot"
        Ensure-Directory -PathValue (Join-Path $BundleRoot "src")
        Copy-Item -LiteralPath $PrjxrayRoot -Destination (Join-Path $BundleRoot "src\prjxray") -Recurse -Force

        Write-Host "Copying Project X-Ray database from $XrayDbRoot"
        Ensure-Directory -PathValue (Join-Path $BundleRoot "src\prjxray-db")
        Copy-Item -LiteralPath $XrayDbRoot -Destination (Join-Path $BundleRoot "src\prjxray-db\artix7") -Recurse -Force

        Write-Host "Copying xc7frames2bit from $Xc7frames2bitExe"
        Ensure-Directory -PathValue (Join-Path $BundleRoot "build\prjxray\tools")
        Copy-Item -LiteralPath $Xc7frames2bitExe -Destination (Join-Path $BundleRoot "build\prjxray\tools\xc7frames2bit.exe") -Force

        if ($ChipDbPath) {
            Write-Host "Copying chipdb from $ChipDbPath"
            Ensure-Directory -PathValue (Join-Path $BundleRoot "tools")
            Copy-Item -LiteralPath $ChipDbPath -Destination (Join-Path $BundleRoot "tools\xc7a100t.bin") -Force
        }

        $PathExtras = @()
        if ($EnvValues.PATH) {
            foreach ($PathEntry in ($EnvValues.PATH -split ';')) {
                if ([string]::IsNullOrWhiteSpace($PathEntry) -or $PathEntry -eq "%PATH%") { continue }
                $ResolvedEntry = Resolve-ExistingPath $PathEntry
                if (-not $ResolvedEntry) { continue }
                if ($ResolvedEntry.StartsWith($OssCadRoot, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
                if (-not $PathExtras.Contains($ResolvedEntry)) { $PathExtras += $ResolvedEntry }
            }
        }

        if ($PathExtras.Count -gt 0) {
            $CommonRoot = Get-CommonAncestor -Paths $PathExtras
            if ($CommonRoot) {
                foreach ($PathEntry in $PathExtras) {
                    $RelativePath = Get-BundleRuntimeRelativePath -PathValue $PathEntry -CommonRoot $CommonRoot
                    $DestinationPath = Join-Path $BundleRoot $RelativePath
                    Write-Host "Copying runtime path $PathEntry"
                    Copy-Item -LiteralPath $PathEntry -Destination $DestinationPath -Recurse -Force
                }
            }
        }

        $ManifestPath = Join-Path $BundleRoot "bundle-manifest.txt"
        @(
            "Created: $(Get-Date -Format s)"
            "OSS CAD Suite: $OssCadRoot"
            "nextpnr-xilinx: $NextpnrExe"
            "Project X-Ray: $PrjxrayRoot"
            "Project X-Ray DB: $XrayDbRoot"
            "xc7frames2bit: $Xc7frames2bitExe"
            "chipdb: $ChipDbPath"
        ) | Set-Content -LiteralPath $ManifestPath -Encoding ASCII

        if (Test-Path -LiteralPath $ResolvedOutputPath) {
            Remove-Item -LiteralPath $ResolvedOutputPath -Force
        }

        Write-Host "Creating bundle archive $ResolvedOutputPath"
        New-ZipArchiveFromDirectory -SourceDirectory $BundleRoot -DestinationArchive $ResolvedOutputPath
        Write-Host "Bundle ready: $ResolvedOutputPath"
    } finally {
        Remove-DirectoryIfExists -PathValue $StagingRoot
    }
}

function Show-Help {
    Write-Host "FPGA Compiler for Native Windows"
    Write-Host ""
    Write-Host "Usage:"
    Write-Host "  .\fpga.bat setup"
    Write-Host "  .\fpga.bat install"
    Write-Host "  .\fpga.bat setup -InstallPackages"
    Write-Host "  .\fpga.bat setup -DownloadFullToolchain"
    Write-Host "  .\fpga.bat doctor"
    Write-Host "  .\fpga.bat package"
    Write-Host "  .\fpga.bat list"
    Write-Host "  .\fpga.bat build"
    Write-Host "  .\fpga.bat build -Project lab2"
    Write-Host "  .\fpga.bat flash"
    Write-Host "  .\fpga.bat flash -Project lab"
    Write-Host ""
    Write-Host "Recommended first run:"
    Write-Host "  .\fpga.bat setup"
    Write-Host "  .\fpga.bat doctor"
    Write-Host "  .\fpga.bat build -Project lab2"
    Write-Host ""
}

try {
    switch ($Command.ToLowerInvariant()) {
        "setup" { Invoke-Setup }
        "install" { Invoke-Setup }
        "doctor" { Invoke-Doctor }
        "package" { Invoke-PackageToolchain }
        "build" { Invoke-Build }
        "flash" { Invoke-Flash }
        "list" { Show-Projects }
        default { Show-Help }
    }
} catch {
    Write-Host $_.Exception.Message
    exit 1
}
