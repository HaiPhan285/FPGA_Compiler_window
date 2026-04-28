[CmdletBinding()]
param(
    [string]$Project,
    [string]$SourceDir,
    [string]$Top,
    [string]$Constraints,
    [switch]$All,
    [switch]$Flash,
    [string]$Bitstream,
    [string]$Device = "xc7a100t",
    [string]$Part = "xc7a100tcsg324-1"
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$ToolBin = Join-Path $RepoRoot ".toolchain\tools\bin"
$BuildRoot = Join-Path $RepoRoot "build"
$AppRoot = Join-Path $RepoRoot "app"

foreach ($PathEntry in @($ToolBin, "C:\msys64\mingw64\bin", "C:\msys64\usr\bin")) {
    if ((Test-Path $PathEntry) -and (($env:Path -split ';') -notcontains $PathEntry)) {
        $env:Path = "$PathEntry;$env:Path"
    }
}

function Find-CommandPath {
    param([string[]]$Names, [switch]$Required)
    foreach ($Name in $Names) {
        $Command = Get-Command $Name -ErrorAction SilentlyContinue
        if ($Command) { return $Command.Source }
    }
    if ($Required) { throw "Required tool not found: $($Names -join ' or ')" }
    return $null
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
    if ($Files.Count -eq 1) { return $Files[0].FullName }
    if ($Files.Count -gt 1) { return $Files[0].FullName }
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
        & $Exe @ArgsList 2>&1 | ForEach-Object { "$_" } | Tee-Object -FilePath $LogFile
        $ExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $PreviousErrorActionPreference
    }
    if ($ExitCode -ne 0) {
        throw "Command failed: $Exe $($ArgsList -join ' '). See $LogFile"
    }
}

function Find-ChipDb {
    param([string]$DeviceName)
    $Candidates = @(
        (Join-Path $ToolBin "..\share\nextpnr\xilinx\chipdb-$DeviceName.bin"),
        (Join-Path $RepoRoot ".toolchain\tools\share\nextpnr\xilinx\chipdb-$DeviceName.bin"),
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

try {
    if ($Flash) {
        $Loader = Find-CommandPath @("openFPGALoader.exe", "openFPGALoader") -Required
        $ResolvedBitstream = Resolve-BitstreamFile $Bitstream $Project
        Write-Host "Flashing bitstream: $ResolvedBitstream"
        Invoke-Checked $Loader @("-b", "nexys_a7_100", $ResolvedBitstream) (Join-Path $BuildRoot "flash.log")
        exit 0
    }

    if ($All) {
        foreach ($Dir in Get-ProjectDirs) { Build-OneProject $Dir.FullName }
        exit 0
    }

    if ($SourceDir) {
        Build-OneProject (Resolve-Path $SourceDir).Path
        exit 0
    }

    $Projects = @(Get-ProjectDirs)
    if ($Project) {
        $Match = $Projects | Where-Object { $_.Name -eq $Project } | Select-Object -First 1
        if (-not $Match) { throw "Project not found under app\: $Project" }
        Build-OneProject $Match.FullName
        exit 0
    }

    if ($Projects.Count -eq 0) { throw "No buildable projects found in app\" }
    if ($Projects.Count -eq 1) {
        Build-OneProject $Projects[0].FullName
        exit 0
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
} catch {
    Write-Host $_.Exception.Message
    exit 1
}
