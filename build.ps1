param(
    [string]$Design,
    [string]$Top,
    [string]$Xdc
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $MyInvocation.MyCommand.Path

function Resolve-WorkspacePath {
    param(
        [string]$PathValue,
        [string]$WorkspaceRoot
    )

    if (-not $PathValue) {
        return $null
    }

    if ([System.IO.Path]::IsPathRooted($PathValue)) {
        return [System.IO.Path]::GetFullPath($PathValue)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $WorkspaceRoot $PathValue))
}

function Add-UniquePath {
    param(
        [System.Collections.Generic.List[string]]$Files,
        [string]$PathValue
    )

    if (-not $PathValue) {
        return
    }

    $normalizedPath = [System.IO.Path]::GetFullPath($PathValue)
    if (-not $Files.Contains($normalizedPath)) {
        $Files.Add($normalizedPath)
    }
}

function Get-WorkspaceRelativePath {
    param(
        [string]$WorkspaceRoot,
        [string]$PathValue
    )

    $workspacePath = [System.IO.Path]::GetFullPath($WorkspaceRoot)
    $fullPath = [System.IO.Path]::GetFullPath($PathValue)

    if ($fullPath.StartsWith($workspacePath, [System.StringComparison]::OrdinalIgnoreCase)) {
        $relative = $fullPath.Substring($workspacePath.Length).TrimStart('\\')
        if ($relative) {
            return $relative
        }
    }

    return $fullPath
}

function Get-RequiredEnv {
    param([string]$Name)

    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "Missing required environment variable: $Name. Run fpga.bat build instead of calling build.ps1 directly."
    }

    return $value
}

function Get-RtlFiles {
    param(
        [string]$WorkspaceRoot,
        [string]$PrimaryDesign
    )

    if (-not $PrimaryDesign) {
        throw "Primary design path is required to resolve the project RTL set."
    }

    $designItem = Get-Item -LiteralPath $PrimaryDesign
    $projectDir = $designItem.Directory.FullName
    $files = New-Object System.Collections.Generic.List[string]

    Add-UniquePath -Files $files -PathValue $PrimaryDesign

    if (Test-Path $projectDir) {
        $rtlFiles = Get-ChildItem -Path $projectDir -File -Recurse -Include *.v,*.sv |
            Sort-Object FullName
        foreach ($rtl in $rtlFiles) {
            Add-UniquePath -Files $files -PathValue $rtl.FullName
        }
    }

    return $files
}

function Get-ModuleNamesFromRtlFile {
    param([string]$FilePath)

    $text = Get-Content -LiteralPath $FilePath -Raw
    $text = [regex]::Replace($text, '(?s)/\*.*?\*/', '')
    $modules = New-Object System.Collections.Generic.List[string]

    foreach ($line in ($text -split "\r?\n")) {
        $lineWithoutComment = [regex]::Replace($line, '//.*$', '')
        $match = [regex]::Match($lineWithoutComment, '^\s*module\s+([A-Za-z_][A-Za-z0-9_$]*)\b')
        if ($match.Success) {
            $moduleName = $match.Groups[1].Value
            if (-not $modules.Contains($moduleName)) {
                $modules.Add($moduleName)
            }
        }
    }

    return $modules.ToArray()
}

function Get-DefaultTopFromDesign {
    param([string]$DesignPath)

    $moduleNames = @(Get-ModuleNamesFromRtlFile -FilePath $DesignPath)
    if ($moduleNames.Count -gt 0) {
        return $moduleNames[0]
    }

    throw "Could not infer top module from design file: $DesignPath"
}

function Get-DefaultXdcPath {
    param(
        [string]$WorkspaceRoot,
        [string]$DesignPath
    )

    $designItem = Get-Item -LiteralPath $DesignPath
    $designDir = $designItem.Directory.FullName
    $designBase = [System.IO.Path]::GetFileNameWithoutExtension($designItem.Name)
    $candidates = @(
        (Join-Path $designDir "$designBase`_openxc7.xdc"),
        (Join-Path $designDir "$designBase.xdc"),
        (Join-Path $WorkspaceRoot "constraints\$designBase`_openxc7.xdc"),
        (Join-Path $WorkspaceRoot "constraints\$designBase.xdc"),
        (Join-Path $WorkspaceRoot "constraints\nexys_a7_100t_openxc7.xdc"),
        (Join-Path $WorkspaceRoot "constraints\nexys_a7_100t_master.xdc")
    )

    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) {
            return $candidate
        }
    }

    throw "No default XDC file found for design: $DesignPath"
}

function Convert-XdcForOpenXc7 {
    param(
        [string]$InputXdc,
        [string]$OutputXdc
    )

    $convertedLines = New-Object System.Collections.Generic.List[string]
    $dictPattern = '^\s*set_property\s+-dict\s+\{(?<props>.+?)\}\s+\[get_ports\s+\{(?<port>.+?)\}\]\s*;?\s*(?<comment>#.*)?$'

    foreach ($line in Get-Content -LiteralPath $InputXdc) {
        $match = [regex]::Match($line, $dictPattern)
        if (-not $match.Success) {
            $convertedLines.Add($line)
            continue
        }

        $propsText = $match.Groups['props'].Value.Trim()
        $port = $match.Groups['port'].Value.Trim()
        $comment = $match.Groups['comment'].Value.Trim()
        $tokens = @($propsText -split '\s+' | Where-Object { $_ -ne '' })

        if (($tokens.Count % 2) -ne 0) {
            throw "Unsupported -dict constraint format in XDC line: $line"
        }

        for ($i = 0; $i -lt $tokens.Count; $i += 2) {
            $propName = $tokens[$i]
            $propValue = $tokens[$i + 1]
            $newLine = "set_property $propName $propValue [get_ports {$port}]"
            if ($i -eq 0 -and $comment) {
                $newLine += " $comment"
            }
            $convertedLines.Add($newLine)
        }
    }

    $text = ($convertedLines -join "`r`n") + "`r`n"
    Set-Content -LiteralPath $OutputXdc -Value $text -Encoding ASCII
}

function Assert-RtlFilesValid {
    param(
        [string]$WorkspaceRoot,
        [System.Collections.Generic.List[string]]$RtlFiles,
        [string]$Top
    )

    $moduleToFile = @{}
    $allModules = New-Object System.Collections.Generic.List[string]

    foreach ($rtlFile in $RtlFiles) {
        $modules = @(Get-ModuleNamesFromRtlFile -FilePath $rtlFile)
        $relativeFile = Get-WorkspaceRelativePath -WorkspaceRoot $WorkspaceRoot -PathValue $rtlFile

        if ($modules.Count -eq 0) {
            throw "RTL file does not declare a module: $relativeFile"
        }

        if ($modules.Count -eq 1) {
            $expectedName = [System.IO.Path]::GetFileNameWithoutExtension($rtlFile)
            $actualName = $modules[0]
            if ($actualName -ne $expectedName) {
                throw "Module/file mismatch in $relativeFile. File name '$expectedName' does not match module '$actualName'. Rename the file or the module so they match."
            }
        }

        foreach ($moduleName in $modules) {
            if ($moduleToFile.ContainsKey($moduleName)) {
                $previousFile = Get-WorkspaceRelativePath -WorkspaceRoot $WorkspaceRoot -PathValue $moduleToFile[$moduleName]
                throw "Duplicate module '$moduleName' found in both $previousFile and $relativeFile."
            }

            $moduleToFile[$moduleName] = $rtlFile
            $allModules.Add($moduleName)
        }
    }

    if (-not $moduleToFile.ContainsKey($Top)) {
        $availableModules = ($allModules | Sort-Object) -join ", "
        throw "Top module '$Top' was not found in the RTL set. Available modules: $availableModules"
    }
}

$ossCadEnv = Get-RequiredEnv "OSS_CAD_ENV"
$yosysExe = Get-RequiredEnv "YOSYS_EXE"
$pythonExe = Get-RequiredEnv "PYTHON_EXE"
$nextpnrExe = Get-RequiredEnv "NEXTPNR_EXE"
$xc7frames2bitExe = Get-RequiredEnv "XC7FRAMES2BIT_EXE"
$prjxrayUtils = Get-RequiredEnv "PRJXRAY_UTILS"
$xrayDbRoot = Get-RequiredEnv "XRAY_DB_ROOT"
$part = Get-RequiredEnv "PART"
$partFile = Get-RequiredEnv "PART_FILE"
$chipdb = Get-RequiredEnv "CHIPDB"

if (-not $Design) {
    $candidateSv = Join-Path $root "src\your_design.sv"
    $candidateV = Join-Path $root "src\your_design.v"
    if (Test-Path $candidateSv) {
        $Design = $candidateSv
    } elseif (Test-Path $candidateV) {
        $Design = $candidateV
    } else {
        throw "Design file not found. Pass a file path or place your_design.v / your_design.sv in src."
    }
}

$Design = Resolve-WorkspacePath -PathValue $Design -WorkspaceRoot $root

if (-not $Top) {
    $Top = Get-DefaultTopFromDesign -DesignPath $Design
}

if (-not $Xdc) {
    $Xdc = Get-DefaultXdcPath -WorkspaceRoot $root -DesignPath $Design
} else {
    $Xdc = Resolve-WorkspacePath -PathValue $Xdc -WorkspaceRoot $root
}

$rtlFiles = Get-RtlFiles -WorkspaceRoot $root -PrimaryDesign $Design
if ($rtlFiles.Count -eq 0) {
    throw "No RTL files found. Put .v or .sv files under src, or pass a design file path."
}

Assert-RtlFilesValid -WorkspaceRoot $root -RtlFiles $rtlFiles -Top $Top

foreach ($path in @($ossCadEnv, $yosysExe, $pythonExe, $nextpnrExe, $xc7frames2bitExe, $partFile, $chipdb, $Design, $Xdc)) {
    if (-not (Test-Path $path)) {
        throw "Missing required file: $path"
    }
}

$buildDir = Join-Path $root "build"
if (-not (Test-Path $buildDir)) {
    New-Item -ItemType Directory -Path $buildDir | Out-Null
}

$designItem = Get-Item $Design
$designBase = [System.IO.Path]::GetFileNameWithoutExtension($designItem.Name)
$json = Join-Path $buildDir "$designBase.json"
$fasm = Join-Path $buildDir "$designBase.fasm"
$frames = Join-Path $buildDir "$designBase.frames"
$bit = Join-Path $buildDir "$designBase.bit"
$ysScript = Join-Path $buildDir "$designBase.ys"
$convertedXdc = Join-Path $buildDir "$designBase.converted.xdc"
$rtlSummary = $rtlFiles | ForEach-Object { "  - $_" }
$ysContent = @(
foreach ($rtlFile in $rtlFiles) {
    'read_verilog -sv "{0}"' -f ($rtlFile -replace '\\','/')
}
)
$ysContent += @(
    "synth_xilinx -flatten -nowidelut -abc9 -arch xc7 -top $Top"
    'write_json "{0}"' -f ($json -replace '\\','/')
)
$ysText = ($ysContent -join "`r`n") + "`r`n"
Set-Content -LiteralPath $ysScript -Value $ysText -Encoding ASCII
Convert-XdcForOpenXc7 -InputXdc $Xdc -OutputXdc $convertedXdc

Write-Host ""
Write-Host "===== Nexys A7 100T OpenXC7 Build ====="
Write-Host "DESIGN  : $($designItem.FullName)"
Write-Host "RTL     :"
$rtlSummary | ForEach-Object { Write-Host $_ }
Write-Host "TOP     : $Top"
Write-Host "XDC     : $Xdc"
Write-Host "XDC USE : $convertedXdc"
Write-Host "CHIPDB  : $chipdb"
Write-Host "OUTPUT  : $bit"
Write-Host ""

Write-Host "[1/4] Yosys synthesis..."
$yosysCmd = 'call "{0}" && yosys -s "{1}"' -f $ossCadEnv, $ysScript
& cmd.exe /c $yosysCmd
if ($LASTEXITCODE -ne 0) { throw "Yosys synthesis failed." }

Write-Host "[2/4] nextpnr-xilinx place and route..."
& $nextpnrExe --chipdb $chipdb --xdc $convertedXdc --json $json --fasm $fasm
if ($LASTEXITCODE -ne 0) { throw "nextpnr-xilinx failed." }

Write-Host "[3/4] fasm2frames..."
& $pythonExe (Join-Path $prjxrayUtils "fasm2frames.py") --db-root $xrayDbRoot --part $part $fasm $frames
if ($LASTEXITCODE -ne 0) { throw "fasm2frames failed." }

Write-Host "[4/4] xc7frames2bit..."
& $xc7frames2bitExe --part_file $partFile --part_name $part --frm_file $frames --output_file $bit
if ($LASTEXITCODE -ne 0) { throw "xc7frames2bit failed." }

Write-Host ""
Write-Host "SUCCESS: $bit"
