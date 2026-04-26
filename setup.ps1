param(
    [switch]$Ensure,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$stateDir = Join-Path $root ".toolchain"
$envFile = Join-Path $stateDir "env.bat"
$defaultConfigPath = Join-Path $root "toolchain.json"
$localConfigPath = Join-Path $root "toolchain.local.json"
$defaultSharedToolchainRoot = Join-Path ([Environment]::GetFolderPath("LocalApplicationData")) "fpga-tools-cache"
$legacyFpgaTools = "C:\Users\27mik\AppData\Local\fpga-tools"
$legacyOssCadRoot = "C:\fpga-tools\oss-cad-suite"
$legacyNextpnrExe = "C:\Users\27mik\nextpnr-xilinx-patched.exe"
$githubApiHeaders = @{
    "Accept" = "application/vnd.github+json"
    "User-Agent" = "nexys-a7-100t-toolchain-setup"
}

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

        if ($current -is [System.Collections.IDictionary]) {
            if (-not $current.Contains($segment)) {
                return $Default
            }

            $current = $current[$segment]
            continue
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

function ConvertTo-ConfigData {
    param($Value)

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [System.Collections.IDictionary]) {
        $result = @{}
        foreach ($key in $Value.Keys) {
            $result[$key] = ConvertTo-ConfigData -Value $Value[$key]
        }
        return $result
    }

    if ($Value -is [System.Management.Automation.PSObject] -and -not ($Value -is [string])) {
        $properties = @($Value.PSObject.Properties)
        if ($properties.Count -gt 0) {
            $result = @{}
            foreach ($property in $properties) {
                $result[$property.Name] = ConvertTo-ConfigData -Value $property.Value
            }
            return $result
        }
    }

    if ($Value -is [System.Array]) {
        return @($Value | ForEach-Object { ConvertTo-ConfigData -Value $_ })
    }

    return $Value
}

function Merge-ConfigData {
    param(
        $Base,
        $Override
    )

    if ($null -eq $Base) {
        return $Override
    }

    if ($null -eq $Override) {
        return $Base
    }

    if (($Base -is [System.Collections.IDictionary]) -and ($Override -is [System.Collections.IDictionary])) {
        $merged = @{}

        foreach ($key in $Base.Keys) {
            $merged[$key] = $Base[$key]
        }

        foreach ($key in $Override.Keys) {
            if ($merged.Contains($key)) {
                $merged[$key] = Merge-ConfigData -Base $merged[$key] -Override $Override[$key]
            } else {
                $merged[$key] = $Override[$key]
            }
        }

        return $merged
    }

    return $Override
}

function Read-ConfigFile {
    param([string]$PathValue)

    if (-not (Test-Path -LiteralPath $PathValue)) {
        return $null
    }

    $content = Get-Content -LiteralPath $PathValue -Raw
    if ([string]::IsNullOrWhiteSpace($content)) {
        return $null
    }

    return ConvertTo-ConfigData -Value (ConvertFrom-Json -InputObject $content)
}

function Resolve-WorkspacePath {
    param([string]$PathValue)

    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        return $null
    }

    $expandedPath = [Environment]::ExpandEnvironmentVariables($PathValue.Trim())
    if ([System.IO.Path]::IsPathRooted($expandedPath)) {
        return [System.IO.Path]::GetFullPath($expandedPath)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $root $expandedPath))
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
    $pathValue = Join-Path ([System.IO.Path]::GetTempPath()) ("fpga-toolchain-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $pathValue | Out-Null
    return $pathValue
}

function Normalize-PathSuffix {
    param([string]$PathValue)

    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        return ""
    }

    return ($PathValue.Trim() -replace '/', '\' -replace '^[\\]+|[\\]+$', '').ToLowerInvariant()
}

function Find-PathBySuffix {
    param(
        [string]$Root,
        [string]$RelativePath,
        [switch]$Directory,
        [switch]$File
    )

    if ([string]::IsNullOrWhiteSpace($Root) -or [string]::IsNullOrWhiteSpace($RelativePath)) {
        return $null
    }

    if (-not (Test-Path -LiteralPath $Root)) {
        return $null
    }

    $directCandidate = Join-Path $Root $RelativePath
    if (Test-Path -LiteralPath $directCandidate) {
        return [System.IO.Path]::GetFullPath($directCandidate)
    }

    $normalizedSuffix = Normalize-PathSuffix -PathValue $RelativePath
    $leafName = Split-Path -Path $RelativePath -Leaf

    if ($Directory) {
        $matches = Get-ChildItem -LiteralPath $Root -Recurse -Directory -Filter $leafName -ErrorAction SilentlyContinue
    } elseif ($File) {
        $matches = Get-ChildItem -LiteralPath $Root -Recurse -File -Filter $leafName -ErrorAction SilentlyContinue
    } else {
        $matches = Get-ChildItem -LiteralPath $Root -Recurse -Force -Filter $leafName -ErrorAction SilentlyContinue
    }

    foreach ($match in @($matches | Sort-Object FullName)) {
        $fullPath = [System.IO.Path]::GetFullPath($match.FullName)
        if ((Normalize-PathSuffix -PathValue $fullPath).EndsWith($normalizedSuffix)) {
            return $fullPath
        }
    }

    return @($matches | Sort-Object FullName | Select-Object -ExpandProperty FullName -First 1)[0]
}

function Find-FirstMatchingFile {
    param(
        [string[]]$Roots,
        [string[]]$Names
    )

    foreach ($rootCandidate in $Roots) {
        if ([string]::IsNullOrWhiteSpace($rootCandidate) -or -not (Test-Path -LiteralPath $rootCandidate)) {
            continue
        }

        foreach ($name in $Names) {
            $match = @(
                Get-ChildItem -LiteralPath $rootCandidate -Recurse -File -Filter $name -ErrorAction SilentlyContinue |
                    Sort-Object FullName |
                    Select-Object -First 1
            )[0]
            if ($match) {
                return [System.IO.Path]::GetFullPath($match.FullName)
            }
        }
    }

    return $null
}

function Find-ProjectXrayDatabaseRoot {
    param(
        [string]$Root,
        [string]$Part
    )

    if ([string]::IsNullOrWhiteSpace($Root) -or [string]::IsNullOrWhiteSpace($Part) -or -not (Test-Path -LiteralPath $Root)) {
        return $null
    }

    $matches = Get-ChildItem -LiteralPath $Root -Recurse -File -Filter "part.yaml" -ErrorAction SilentlyContinue
    foreach ($match in @($matches | Sort-Object FullName)) {
        $partDirectory = Split-Path -Parent $match.FullName
        if ((Split-Path -Leaf $partDirectory).Equals($Part, [System.StringComparison]::OrdinalIgnoreCase)) {
            return [System.IO.Path]::GetFullPath((Split-Path -Parent $partDirectory))
        }
    }

    return $null
}

function Get-OssCadSuiteRootFromExtraction {
    param([string]$Root)

    if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root)) {
        return $null
    }

    $directCandidate = Join-Path $Root "oss-cad-suite"
    if (Test-Path -LiteralPath (Join-Path $directCandidate "environment.bat")) {
        return [System.IO.Path]::GetFullPath($directCandidate)
    }

    $namedCandidate = @(
        Get-ChildItem -LiteralPath $Root -Recurse -Directory -Filter "oss-cad-suite" -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "environment.bat") } |
            Sort-Object FullName |
            Select-Object -First 1
    )[0]
    if ($namedCandidate) {
        return [System.IO.Path]::GetFullPath($namedCandidate.FullName)
    }

    $environmentFile = @(
        Get-ChildItem -LiteralPath $Root -Recurse -File -Filter "environment.bat" -ErrorAction SilentlyContinue |
            Sort-Object FullName |
            Select-Object -First 1
    )[0]
    if ($environmentFile) {
        return [System.IO.Path]::GetFullPath((Split-Path -Parent $environmentFile.FullName))
    }

    return $null
}

function Get-OssCadSuiteRootFromCandidates {
    param(
        [string[]]$Roots,
        [string]$RelativePath = "oss-cad-suite"
    )

    foreach ($rootCandidate in $Roots) {
        if ([string]::IsNullOrWhiteSpace($rootCandidate) -or -not (Test-Path -LiteralPath $rootCandidate)) {
            continue
        }

        $directCandidate = if ([string]::IsNullOrWhiteSpace($RelativePath)) {
            $rootCandidate
        } else {
            Join-Path $rootCandidate $RelativePath
        }
        if (Test-Path -LiteralPath (Join-Path $directCandidate "environment.bat")) {
            return [System.IO.Path]::GetFullPath($directCandidate)
        }

        $discoveredCandidate = if ([string]::IsNullOrWhiteSpace($RelativePath)) {
            Get-OssCadSuiteRootFromExtraction -Root $rootCandidate
        } else {
            $foundPath = Find-PathBySuffix -Root $rootCandidate -RelativePath $RelativePath -Directory
            if ($foundPath -and (Test-Path -LiteralPath (Join-Path $foundPath "environment.bat"))) {
                [System.IO.Path]::GetFullPath($foundPath)
            } else {
                $null
            }
        }

        if ($discoveredCandidate) {
            return $discoveredCandidate
        }
    }

    return $null
}

function Invoke-ProcessAndRequireSuccess {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList
    )

    $process = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -Wait -NoNewWindow -PassThru
    if ($process.ExitCode -ne 0) {
        throw "Command failed with exit code $($process.ExitCode): $FilePath $($ArgumentList -join ' ')"
    }
}

function Expand-SelfExtractingArchive {
    param(
        [string]$ArchivePath,
        [string]$Destination
    )

    $attemptErrors = New-Object System.Collections.Generic.List[string]
    $attempts = @(
        @("-y", "-aoa", "-o$Destination"),
        @("x", "-y", "-aoa", "-o$Destination")
    )

    foreach ($attempt in $attempts) {
        Remove-DirectoryIfExists -PathValue $Destination
        Ensure-Directory -PathValue $Destination

        try {
            Invoke-ProcessAndRequireSuccess -FilePath $ArchivePath -ArgumentList $attempt
            if (Get-OssCadSuiteRootFromExtraction -Root $Destination) {
                return
            }

            $attemptErrors.Add("Extraction command succeeded but no oss-cad-suite folder was produced: $($attempt -join ' ')")
        } catch {
            $attemptErrors.Add($_.Exception.Message)
        }
    }

    foreach ($extractorName in @("7z.exe", "7za.exe", "7zr.exe")) {
        $extractor = Get-Command $extractorName -ErrorAction SilentlyContinue
        if (-not $extractor) {
            continue
        }

        Remove-DirectoryIfExists -PathValue $Destination
        Ensure-Directory -PathValue $Destination

        try {
            Invoke-ProcessAndRequireSuccess -FilePath $extractor.Source -ArgumentList @("x", $ArchivePath, "-y", "-aoa", "-o$Destination")
            if (Get-OssCadSuiteRootFromExtraction -Root $Destination) {
                return
            }

            $attemptErrors.Add("External extractor $extractorName succeeded but no oss-cad-suite folder was produced.")
        } catch {
            $attemptErrors.Add($_.Exception.Message)
        }
    }

    throw "Failed to extract $ArchivePath. Attempts: $($attemptErrors -join ' | ')"
}

function Invoke-DownloadFile {
    param(
        [string]$Url,
        [string]$Destination,
        [switch]$ReuseExisting
    )

    Ensure-Directory -PathValue (Split-Path -Parent $Destination)
    if ($ReuseExisting -and (Test-Path -LiteralPath $Destination)) {
        Write-Host "Using cached download $Destination"
        return
    }

    Write-Host "Downloading $Url"
    Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -Headers $githubApiHeaders
}

function Get-GitHubReleaseAsset {
    param(
        [string]$Repository,
        [string]$Tag = "latest",
        [string[]]$AssetPatterns,
        [string]$Purpose = "release"
    )

    if ([string]::IsNullOrWhiteSpace($Repository)) {
        return $null
    }

    $patterns = @($AssetPatterns | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($patterns.Count -eq 0) {
        return $null
    }

    $releaseUri = if ([string]::IsNullOrWhiteSpace($Tag) -or $Tag -eq "latest") {
        "https://api.github.com/repos/$Repository/releases/latest"
    } else {
        "https://api.github.com/repos/$Repository/releases/tags/$Tag"
    }

    $release = Invoke-RestMethod -Uri $releaseUri -Headers $githubApiHeaders
    $assets = @($release.assets)

    foreach ($pattern in $patterns) {
        $asset = @(
            $assets |
                Where-Object { $_.name -like $pattern } |
                Sort-Object name |
                Select-Object -First 1
        )[0]
        if ($asset) {
            return [pscustomobject]@{
                Name = $asset.name
                Url = $asset.browser_download_url
                Tag = $release.tag_name
                Extension = [System.IO.Path]::GetExtension($asset.name).ToLowerInvariant()
                Repository = $Repository
            }
        }
    }

    $availableAssets = @($assets | ForEach-Object { $_.name })
    $availableMessage = if ($availableAssets.Count -gt 0) {
        " Available assets: " + ($availableAssets -join ", ")
    } else {
        ""
    }

    throw "Could not find a $Purpose asset in $Repository release $($release.tag_name) matching: $($patterns -join ', ').$availableMessage"
}

function Get-NewestMatchingFile {
    param(
        [string]$Directory,
        [string[]]$Patterns
    )

    if (-not (Test-Path -LiteralPath $Directory)) {
        return $null
    }

    $matches = foreach ($pattern in $Patterns) {
        Get-ChildItem -LiteralPath $Directory -File -Filter $pattern -ErrorAction SilentlyContinue
    }

    return @($matches | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)[0]
}

function Expand-ZipArchive {
    param(
        [string]$ArchivePath,
        [strin