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
    [switch]$DownloadFullToolchain,
    [switch]$RequireFullBuildTools,
    [string]$Device = "xc7a100t",
    [string]$Part = "xc7a100tcsg324-1"
)

$ErrorActionPreference = "Stop"
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

foreach ($PathEntry in @($ToolBin, $OpenXc7Root, (Join-Path $OpenXc7Root "oss-cad-suite\bin"), (Join-Path $OpenXc7Root "build\prjxray\tools"), $MingwBin, $UsrBin)) {
    if ((Test-Path $PathEntry) -and (($env:Path -split ';') -notcontains $PathEntry)) {
        $env:Path = "$PathEntry;$env:Path"
    }
}

function Add-PathEntry {
    param([string]$PathEntry)
    if ((Test-Path $PathEntry) -and (($env:Path -split ';') -notcontains $PathEntry)) {
        $env:Path = "$PathEntry;$env:Path"
    }
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
    $Release = Invoke-RestMethod -Uri $Uri -Headers @{ "User-Agent" = "FPGA-Compiler-Setup" }
    $Patterns = @($ReleaseConfig.assetPatterns)
    if ($Patterns.Count -eq 0) { $Patterns = @("*.zip") }

    foreach ($Pattern in $Patterns) {
        $Asset = @($Release.assets | Where-Object { $_.name -like $Pattern } | Sort-Object name | Select-Object -First 1)
        if ($Asset.Count -gt 0) { return $Asset[0] }
    }
    return $null
}

function Install-OpenXc7Bundle {
    $Config = Get-ToolchainConfig
    if (-not $Config -or -not ($Config.autoDownload -or $DownloadFullToolchain -or $Ensure -or $RequireFullBuildTools)) { return }

    if ((Test-Path (Join-Path $OpenXc7Root "nextpnr-xilinx.exe")) -and
        (Test-Path (Join-Path $OpenXc7Root "build\prjxray\tools\xc7frames2bit.exe"))) {
        return
    }

    $BundleRoot = Expand-ConfigPath $Config.toolchainBundle.root
    if ($BundleRoot -and (Test-Path -LiteralPath $BundleRoot)) {
        New-Item -ItemType Directory -Force -Path $OpenXc7Root | Out-Null
        Copy-Item -LiteralPath (Join-Path $BundleRoot "*") -Destination $OpenXc7Root -Recurse -Force
        return
    }

    $Asset = Get-GitHubReleaseAsset $Config.toolchainBundle.githubRelease
    if (-not $Asset) {
        Write-Host "No openXC7 toolchain release asset found for auto-download."
        return
    }

    New-Item -ItemType Directory -Force -Path $ToolRoot | Out-Null
    $ArchivePath = Join-Path $ToolRoot $Asset.name
    $ExtractRoot = Join-Path $ToolRoot "_openxc7_extract"

    Write-Host "Downloading openXC7 toolchain bundle: $($Asset.name)"
    Invoke-WebRequest -Uri $Asset.browser_download_url -OutFile $ArchivePath
    if (Test-Path -LiteralPath $ExtractRoot) { Remove-Item -LiteralPath $ExtractRoot -Recurse -Force }
    Expand-Archive -LiteralPath $ArchivePath -DestinationPath $ExtractRoot -Force

    $CandidateRoots = @($ExtractRoot) + @(Get-ChildItem -Path $ExtractRoot -Directory -Recurse -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
    $DetectedRoot = $CandidateRoots | Where-Object { Test-Path (Join-Path $_ "nextpnr-xilinx.exe") } | Select-Object -First 1
    if (-not $DetectedRoot) { throw "Downloaded bundle did not contain nextpnr-xilinx.exe." }

    if (Test-Path -LiteralPath $OpenXc7Root) { Remove-Item -LiteralPath $OpenXc7Root -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $OpenXc7Root | Out-Null
    Copy-Item -LiteralPath (Join-Path $DetectedRoot "*") -Destination $OpenXc7Root -Recurse -Force
    Remove-Item -LiteralPath $ExtractRoot -Recurse -Force
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
    $Python = Find-CommandPath @("python.exe", "python", "python3.exe", "python3")
    Write-CommandShim -Name "nextpnr-xilinx" -Target (Join-Path $OpenXc7Root "nextpnr-xilinx.exe")
    Write-CommandShim -Name "xc7frames2bit" -Target (Join-Path $OpenXc7Root "build\prjxray\tools\xc7frames2bit.exe")

    $Fasm2FramesExe = Join-Path $OpenXc7Root "fasm2frames.exe"
    $Fasm2FramesPy = Join-Path $OpenXc7Root "src\prjxray\utils\fasm2frames.py"
    if (Test-Path -LiteralPath $Fasm2FramesExe) {
        Write-CommandShim -Name "fasm2frames" -Target $Fasm2FramesExe
    } elseif ($Python -and (Test-Path -LiteralPath $Fasm2FramesPy)) {
        Write-CommandShim -Name "fasm2frames" -Target $Fasm2FramesPy -Prefix "`"$Python`""
    }
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

    return @{
        Missing = $Missing
        HasYosys = $Missing -notcontains "yosys"
        HasOpenFpgaLoader = $Missing -notcontains "openFPGALoader"
        HasFullBuildTools = ($Missing -notcontains "nextpnr-xilinx") -and ($Missing -notcontains "fasm2frames") -and ($Missing -notcontains "xc7frames2bit")
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

function Invoke-Setup {
    New-Item -ItemType Directory -Force -Path $ToolBin, $BuildRoot | Out-Null
    Add-PathEntry $ToolBin
    Add-PathEntry $OpenXc7Root
    Add-PathEntry (Join-Path $OpenXc7Root "oss-cad-suite\bin")
    Add-PathEntry (Join-Path $OpenXc7Root "build\prjxray\tools")
    Add-PathEntry $MingwBin
    Add-PathEntry $UsrBin

    Write-Host ""
    Write-Host "====== FPGA Setup ======"
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

    try {
        Install-OpenXc7Bundle
        Install-OpenXc7Shims
    } catch {
        if ($Ensure) { throw }
        Write-Host "openXC7 auto-install skipped: $($_.Exception.Message)"
    }

    if ($PersistPath) {
        $UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
        foreach ($Entry in @($ToolBin, $OpenXc7Root, (Join-Path $OpenXc7Root "oss-cad-suite\bin"), (Join-Path $OpenXc7Root "build\prjxray\tools"), $MingwBin, $UsrBin)) {
            if ((Test-Path $Entry) -and (($UserPath -split ';') -notcontains $Entry)) {
                $UserPath = "$Entry;$UserPath"
            }
        }
        [Environment]::SetEnvironmentVariable("Path", $UserPath, "User")
        Write-Host "Updated user PATH. Open a new terminal for persistent PATH changes."
    }

    $Status = Get-ToolStatus
    $PrebuiltBitstreams = Get-PrebuiltBitstreams
    $LiteReady = $Status.HasOpenFpgaLoader -and $PrebuiltBitstreams.Count -gt 0

    Write-Host ""
    if ($Status.Missing.Count -eq 0) {
        Write-Host "Setup complete. Run: .\fpga.bat build"
        return
    }

    Write-Host "Missing tools: $($Status.Missing -join ', ')"
    Write-Host ""
    if ($LiteReady) {
        Write-Host "Lite mode is ready."
        Write-Host "You can flash a prebuilt project without downloading the full build toolchain:"
        Write-Host "  .\fpga.bat flash -Project $($PrebuiltBitstreams[0].Directory.Name)"
        Write-Host ""
    }

    if ($Status.HasYosys -and -not $Status.HasFullBuildTools) {
        Write-Host "Synthesis-only mode is ready."
        Write-Host "You can still run: .\fpga.bat build -Project <name>"
        Write-Host "That will generate .json output and skip .bit generation until the full toolchain is installed."
        Write-Host ""
    }

    Write-Host "Windows-native target:"
    Write-Host "  - Lightweight default: use prebuilt .bit files and .\fpga.bat flash -Project <name>"
    Write-Host "  - Yosys can be installed from MSYS2 with: .\fpga.bat setup -InstallPackages"
    Write-Host "  - Full openXC7/prjxray download is optional: .\fpga.bat setup -DownloadFullToolchain"
    Write-Host "  - Native openXC7/MSYS2-built binaries can also be put on PATH or in .toolchain\tools\bin."
    Write-Host "  - Vivado and WSL are not required by these scripts."

    if ($RequireFullBuildTools -and -not $Status.HasFullBuildTools) {
        exit 1
    }

    if ($LiteReady -or $Status.HasYosys) {
        return
    }

    exit 1
}

function Invoke-Build {
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

function Show-Help {
    Write-Host "FPGA Compiler for native Windows"
    Write-Host ""
    Write-Host "Usage:"
    Write-Host "  .\fpga.bat setup"
    Write-Host "  .\fpga.bat setup -InstallPackages"
    Write-Host "  .\fpga.bat setup -DownloadFullToolchain"
    Write-Host "  .\fpga.bat list"
    Write-Host "  .\fpga.bat build"
    Write-Host "  .\fpga.bat build -Project lab2"
    Write-Host "  .\fpga.bat flash"
    Write-Host "  .\fpga.bat flash -Project lab"
    Write-Host ""
}

try {
    switch ($Command.ToLowerInvariant()) {
        "setup" { Invoke-Setup }
        "build" { Invoke-Build }
        "flash" { Invoke-Flash }
        "list" { Show-Projects }
        default { Show-Help }
    }
} catch {
    Write-Host $_.Exception.Message
    exit 1
}
