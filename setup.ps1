param(
    [switch]$Ensure,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

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

try {
    $tls12 = [System.Net.SecurityProtocolType]::Tls12
    $protocols = [System.Net.ServicePointManager]::SecurityProtocol
    if (($protocols -band $tls12) -ne $tls12) {
        [System.Net.ServicePointManager]::SecurityProtocol = $protocols -bor $tls12
    }
} catch {
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
        @("-y", "-o$Destination"),
        @("x", "-y", "-o$Destination")
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
        [string]$Purpose = "release",
        [switch]$AllowMissing
    )

    if ([string]::IsNullOrWhiteSpace($Repository)) {
        return $null
    }

    $Repository = $Repository.Trim()

    $patterns = @($AssetPatterns | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($patterns.Count -eq 0) {
        return $null
    }

    $releaseUri = if ([string]::IsNullOrWhiteSpace($Tag) -or $Tag -eq "latest") {
        "https://api.github.com/repos/$Repository/releases/latest"
    } else {
        "https://api.github.com/repos/$Repository/releases/tags/$Tag"
    }

    try {
        $release = Invoke-RestMethod -Uri $releaseUri -Headers $githubApiHeaders
    } catch {
        $statusCode = $null
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
            try {
                $statusCode = [int]$_.Exception.Response.StatusCode
            } catch {
            }
        }

        if ($statusCode -eq 404) {
            return $null
        }

        $lookupMessage = "GitHub $Purpose lookup failed for '$Repository' from $releaseUri. $($_.Exception.Message)"
        if ($AllowMissing) {
            Write-Host $lookupMessage
            return $null
        }

        throw $lookupMessage
    }

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

    $missingMessage = "Could not find a $Purpose asset in $Repository release $($release.tag_name) matching: $($patterns -join ', ').$availableMessage"
    if ($AllowMissing) {
        Write-Host $missingMessage
        return $null
    }

    throw $missingMessage
}

function Get-NewestMatchingFileInDirectories {
    param(
        [string[]]$Directories,
        [string[]]$Patterns
    )

    $matches = foreach ($directory in $Directories) {
        if ([string]::IsNullOrWhiteSpace($directory) -or -not (Test-Path -LiteralPath $directory)) {
            continue
        }

        foreach ($pattern in $Patterns) {
            Get-ChildItem -LiteralPath $directory -File -Filter $pattern -ErrorAction SilentlyContinue
        }
    }

    return @($matches | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)[0]
}

function Expand-ZipArchive {
    param(
        [string]$ArchivePath,
        [string]$Destination
    )

    Remove-DirectoryIfExists -PathValue $Destination
    Ensure-Directory -PathValue $Destination

    $tarCommand = Get-Command "tar.exe" -ErrorAction SilentlyContinue
    if ($tarCommand) {
        & $tarCommand.Source -xf $ArchivePath -C $Destination
        if ($LASTEXITCODE -ne 0) {
            throw "tar.exe failed with exit code $LASTEXITCODE while extracting $ArchivePath"
        }
        return
    }

    Expand-Archive -LiteralPath $ArchivePath -DestinationPath $Destination -Force
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
        [string]$RelativePath,
        [switch]$Directory,
        [switch]$File
    )

    if ([string]::IsNullOrWhiteSpace($BasePath) -or [string]::IsNullOrWhiteSpace($RelativePath)) {
        return $null
    }

    return Find-PathBySuffix -Root $BasePath -RelativePath $RelativePath -Directory:$Directory -File:$File
}

function Test-PythonModule {
    param(
        [string]$PythonPath,
        [string]$ModuleName
    )

    if (-not $PythonPath -or -not (Test-Path -LiteralPath $PythonPath)) {
        return $false
    }

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & $PythonPath -c "import $ModuleName" *> $null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
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

function Get-BatchEnvironmentValues {
    param([string]$FilePath)

    $values = @{}
    if (-not (Test-Path -LiteralPath $FilePath)) {
        return $values
    }

    foreach ($line in Get-Content -LiteralPath $FilePath) {
        if ($line -match '^set "(?<name>[^=]+)=(?<value>.*)"$') {
            $values[$matches.name] = $matches.value
        }
    }

    return $values
}

function Test-ToolchainEnvFile {
    param(
        [string]$FilePath,
        [string[]]$DependencyPaths
    )

    if (-not (Test-Path -LiteralPath $FilePath)) {
        return $false
    }

    $envItem = Get-Item -LiteralPath $FilePath
    foreach ($dependencyPath in $DependencyPaths) {
        if ([string]::IsNullOrWhiteSpace($dependencyPath) -or -not (Test-Path -LiteralPath $dependencyPath)) {
            continue
        }

        $dependencyItem = Get-Item -LiteralPath $dependencyPath
        if ($dependencyItem.LastWriteTimeUtc -gt $envItem.LastWriteTimeUtc) {
            return $false
        }
    }

    $values = Get-BatchEnvironmentValues -FilePath $FilePath
    foreach ($key in @(
        "CHIPDB",
        "NEXTPNR_EXE",
        "OPENFPGALOADER_EXE",
        "OSS_CAD",
        "OSS_CAD_ENV",
        "PART_FILE",
        "PRJXRAY_UTILS",
        "PYTHON_EXE",
        "XC7FRAMES2BIT_EXE",
        "XRAY_DB_ROOT",
        "YOSYS_EXE"
    )) {
        if (-not $values.ContainsKey($key)) {
            return $false
        }

        $pathValue = $values[$key]
        if ([string]::IsNullOrWhiteSpace($pathValue) -or -not (Test-Path -LiteralPath $pathValue)) {
            return $false
        }
    }

    return $true
}

function Get-DownloadFileName {
    param(
        [string]$Url,
        [string]$DefaultName
    )

    if (-not [string]::IsNullOrWhiteSpace($DefaultName)) {
        return $DefaultName
    }

    if (-not [string]::IsNullOrWhiteSpace($Url)) {
        try {
            $name = [System.IO.Path]::GetFileName(([System.Uri]$Url).AbsolutePath)
            if (-not [string]::IsNullOrWhiteSpace($name)) {
                return $name
            }
        } catch {
        }
    }

    return "download.bin"
}

function Install-ChipDbAsset {
    param(
        [string]$SourcePath,
        [string]$ArchiveSubPath,
        [string]$DestinationPath
    )

    $extension = [System.IO.Path]::GetExtension($SourcePath).ToLowerInvariant()
    switch ($extension) {
        ".bin" {
            Ensure-Directory -PathValue (Split-Path -Parent $DestinationPath)
            Copy-Item -LiteralPath $SourcePath -Destination $DestinationPath -Force
            return [System.IO.Path]::GetFullPath($DestinationPath)
        }

        ".zip" {
            $tempRoot = New-TemporaryDirectory
            try {
                Expand-ZipArchive -ArchivePath $SourcePath -Destination $tempRoot

                $resolvedChipdb = $null
                if (-not [string]::IsNullOrWhiteSpace($ArchiveSubPath)) {
                    $resolvedChipdb = Resolve-RelativeToRoot -BasePath $tempRoot -RelativePath $ArchiveSubPath -File
                }

                if (-not $resolvedChipdb) {
                    $resolvedChipdb = Find-FirstMatchingFile -Roots @($tempRoot) -Names @((Split-Path -Leaf $DestinationPath))
                }

                if (-not $resolvedChipdb) {
                    throw "Could not find chipdb file inside $SourcePath"
                }

                Ensure-Directory -PathValue (Split-Path -Parent $DestinationPath)
                Copy-Item -LiteralPath $resolvedChipdb -Destination $DestinationPath -Force
                return [System.IO.Path]::GetFullPath($DestinationPath)
            } finally {
                Remove-DirectoryIfExists -PathValue $tempRoot
            }
        }

        default {
            throw "Unsupported chipdb asset type '$extension' for $SourcePath"
        }
    }
}

function Ensure-OptionalBundle {
    param($Config)

    $configuredRoot = Resolve-WorkspacePath (Get-ConfigValue -Object $Config -Path @("toolchainBundle", "root"))
    if ($configuredRoot -and (Test-Path -LiteralPath $configuredRoot)) {
        return [System.IO.Path]::GetFullPath($configuredRoot)
    }

    if ((Test-Path -LiteralPath $managedBundleRoot) -and -not $Force) {
        return [System.IO.Path]::GetFullPath($managedBundleRoot)
    }

    if (-not $autoDownload) {
        return $configuredRoot
    }

    $githubRepo = Get-ConfigValue -Object $Config -Path @("toolchainBundle", "githubRelease", "repo")
    $githubTag = Get-ConfigValue -Object $Config -Path @("toolchainBundle", "githubRelease", "tag") -Default "latest"
    $assetPatterns = Get-PathList -Config $Config -Path @("toolchainBundle", "githubRelease", "assetPatterns")
    $downloadUrl = Get-ConfigValue -Object $Config -Path @("toolchainBundle", "downloadUrl")
    $archiveName = Get-ConfigValue -Object $Config -Path @("toolchainBundle", "archiveName")

    $cachePatterns = New-Object System.Collections.Generic.List[string]
    foreach ($pattern in @($assetPatterns + @($archiveName))) {
        if (-not [string]::IsNullOrWhiteSpace($pattern) -and -not $cachePatterns.Contains($pattern)) {
            $cachePatterns.Add($pattern)
        }
    }

    $cachedArchive = if (-not $Force -and $cachePatterns.Count -gt 0) {
        Get-NewestMatchingFileInDirectories -Directories @($repoDownloadsDir, $downloadsDir) -Patterns @($cachePatterns)
    } else {
        $null
    }

    if ($cachedArchive) {
        $archivePath = $cachedArchive.FullName
        Write-Host "Using cached toolchain bundle $($cachedArchive.Name)"
    } else {
        $asset = $null
        if (-not [string]::IsNullOrWhiteSpace($githubRepo) -and $assetPatterns.Count -gt 0) {
            $asset = Get-GitHubReleaseAsset -Repository $githubRepo -Tag $githubTag -AssetPatterns $assetPatterns -Purpose "toolchain bundle" -AllowMissing
            if ($asset) {
                $archiveName = $asset.Name
            } elseif ([string]::IsNullOrWhiteSpace($downloadUrl)) {
                return $configuredRoot
            }
        } elseif ([string]::IsNullOrWhiteSpace($downloadUrl)) {
            return $configuredRoot
        }

        $archiveName = Get-DownloadFileName -Url $downloadUrl -DefaultName $archiveName
        if ($asset) {
            $archivePath = Join-Path $downloadsDir $asset.Name
            Invoke-DownloadFile -Url $asset.Url -Destination $archivePath -ReuseExisting:(-not $Force)
        } else {
            $archivePath = Join-Path $downloadsDir $archiveName
            Invoke-DownloadFile -Url $downloadUrl -Destination $archivePath -ReuseExisting:(-not $Force)
        }
    }

    if ([System.IO.Path]::GetExtension($archivePath).ToLowerInvariant() -ne ".zip") {
        throw "Unsupported toolchain bundle type '$([System.IO.Path]::GetExtension($archivePath))' for $archivePath"
    }

    Write-Host "Installing OpenXC7 bundle into $managedBundleRoot"
    Expand-ZipArchive -ArchivePath $archivePath -Destination $managedBundleRoot
    return [System.IO.Path]::GetFullPath($managedBundleRoot)
}

function Ensure-OssCadSuite {
    param(
        $Config,
        [string]$BundleRoot
    )

    $configuredRoot = Resolve-WorkspacePath (Get-ConfigValue -Object $Config -Path @("ossCadSuite", "root"))
    if ($configuredRoot -and (Test-Path -LiteralPath (Join-Path $configuredRoot "environment.bat"))) {
        return [System.IO.Path]::GetFullPath($configuredRoot)
    }

    $bundleOssCadRelativeRoot = Get-ConfigValue -Object $Config -Path @("toolchainBundle", "ossCadSuiteRoot") -Default "oss-cad-suite"
    $bundleOssCadRoot = if ($BundleRoot) {
        Get-OssCadSuiteRootFromCandidates -Roots @($BundleRoot) -RelativePath $bundleOssCadRelativeRoot
    } else {
        $null
    }
    if ($bundleOssCadRoot) {
        return $bundleOssCadRoot
    }

    $managedRoot = Get-OssCadSuiteRootFromCandidates -Roots @($managedOssCadExtractRoot) -RelativePath ""
    if ($managedRoot -and -not $Force) {
        return $managedRoot
    }

    if ((Test-Path -LiteralPath (Join-Path $legacyOssCadRoot "environment.bat")) -and -not $Force) {
        return [System.IO.Path]::GetFullPath($legacyOssCadRoot)
    }

    if (-not $autoDownload) {
        return $configuredRoot
    }

    $cachedArchive = if (-not $Force) {
        Get-NewestMatchingFileInDirectories -Directories @($repoDownloadsDir, $downloadsDir) -Patterns @(
            "oss-cad-suite-windows-x64-*.zip",
            "oss-cad-suite-windows-x64-*.exe"
        )
    } else {
        $null
    }

    if ($cachedArchive) {
        $assetName = $cachedArchive.Name
        $archivePath = $cachedArchive.FullName
        Write-Host "Using cached OSS CAD Suite archive $assetName"
    } else {
        $asset = Get-GitHubReleaseAsset -Repository "YosysHQ/oss-cad-suite-build" -AssetPatterns @(
            "*windows-x64*.zip",
            "*windows-x64*.exe"
        ) -Purpose "OSS CAD Suite"
        $archivePath = Join-Path $downloadsDir $asset.Name
        Invoke-DownloadFile -Url $asset.Url -Destination $archivePath -ReuseExisting:(-not $Force)
    }

    Write-Host "Installing OSS CAD Suite into $managedOssCadExtractRoot"
    switch ([System.IO.Path]::GetExtension($archivePath).ToLowerInvariant()) {
        ".zip" {
            Expand-ZipArchive -ArchivePath $archivePath -Destination $managedOssCadExtractRoot
        }

        ".exe" {
            Expand-SelfExtractingArchive -ArchivePath $archivePath -Destination $managedOssCadExtractRoot
        }

        default {
            throw "Unsupported OSS CAD Suite asset type '$([System.IO.Path]::GetExtension($archivePath))' for $archivePath"
        }
    }

    $installedRoot = Get-OssCadSuiteRootFromExtraction -Root $managedOssCadExtractRoot
    if (-not $installedRoot) {
        throw "OSS CAD Suite was extracted, but environment.bat was not found under $managedOssCadExtractRoot"
    }

    return $installedRoot
}

function Ensure-ChipDb {
    param(
        $Config,
        [string]$BundleRoot
    )

    $chipdbRelativePath = Get-ConfigValue -Object $Config -Path @("chipdb", "path") -Default "tools\xc7a100t.bin"
    $chipdbArchiveSubPath = Get-ConfigValue -Object $Config -Path @("chipdb", "archiveSubPath") -Default $chipdbRelativePath
    $configuredChipdbPath = Resolve-WorkspacePath $chipdbRelativePath

    if ($configuredChipdbPath -and (Test-Path -LiteralPath $configuredChipdbPath)) {
        return [System.IO.Path]::GetFullPath($configuredChipdbPath)
    }

    $bundleChipdbPath = if ($BundleRoot) {
        Resolve-RelativeToRoot -BasePath $BundleRoot -RelativePath $chipdbArchiveSubPath -File
    } else {
        $null
    }
    if ($bundleChipdbPath) {
        return $bundleChipdbPath
    }

    if ((Test-Path -LiteralPath $managedChipdbPath) -and -not $Force) {
        return [System.IO.Path]::GetFullPath($managedChipdbPath)
    }

    $legacyChipdbPath = Join-Path $legacyFpgaTools "source-build\build\nextpnr-xilinx\xc7a100t.bin"
    if ((Test-Path -LiteralPath $legacyChipdbPath) -and -not $Force) {
        return [System.IO.Path]::GetFullPath($legacyChipdbPath)
    }

    if (-not $autoDownload) {
        return $configuredChipdbPath
    }

    $githubRepo = Get-ConfigValue -Object $Config -Path @("chipdb", "githubRelease", "repo")
    $githubTag = Get-ConfigValue -Object $Config -Path @("chipdb", "githubRelease", "tag") -Default "latest"
    $assetPatterns = Get-PathList -Config $Config -Path @("chipdb", "githubRelease", "assetPatterns")
    $downloadUrl = Get-ConfigValue -Object $Config -Path @("chipdb", "downloadUrl")
    $archiveName = Get-ConfigValue -Object $Config -Path @("chipdb", "archiveName")

    $cachePatterns = New-Object System.Collections.Generic.List[string]
    foreach ($pattern in @($assetPatterns + @($archiveName) + @((Split-Path -Leaf $managedChipdbPath)))) {
        if (-not [string]::IsNullOrWhiteSpace($pattern) -and -not $cachePatterns.Contains($pattern)) {
            $cachePatterns.Add($pattern)
        }
    }

    $cachedAsset = if (-not $Force -and $cachePatterns.Count -gt 0) {
        Get-NewestMatchingFileInDirectories -Directories @($repoDownloadsDir, $downloadsDir) -Patterns @($cachePatterns)
    } else {
        $null
    }

    if ($cachedAsset) {
        $assetPath = $cachedAsset.FullName
        Write-Host "Using cached chipdb asset $($cachedAsset.Name)"
    } else {
        $asset = $null
        if (-not [string]::IsNullOrWhiteSpace($githubRepo) -and $assetPatterns.Count -gt 0) {
            $asset = Get-GitHubReleaseAsset -Repository $githubRepo -Tag $githubTag -AssetPatterns $assetPatterns -Purpose "chipdb" -AllowMissing
            if ($asset) {
                $archiveName = $asset.Name
            } elseif ([string]::IsNullOrWhiteSpace($downloadUrl)) {
                return $configuredChipdbPath
            }
        } elseif ([string]::IsNullOrWhiteSpace($downloadUrl)) {
            return $configuredChipdbPath
        }

        $archiveName = Get-DownloadFileName -Url $downloadUrl -DefaultName $archiveName
        if ($asset) {
            $assetPath = Join-Path $downloadsDir $asset.Name
            Invoke-DownloadFile -Url $asset.Url -Destination $assetPath -ReuseExisting:(-not $Force)
        } else {
            $assetPath = Join-Path $downloadsDir $archiveName
            Invoke-DownloadFile -Url $downloadUrl -Destination $assetPath -ReuseExisting:(-not $Force)
        }
    }

    return Install-ChipDbAsset -SourcePath $assetPath -ArchiveSubPath $chipdbArchiveSubPath -DestinationPath $managedChipdbPath
}

$defaultConfig = Read-ConfigFile -PathValue $defaultConfigPath
$localConfig = Read-ConfigFile -PathValue $localConfigPath
$config = Merge-ConfigData -Base $defaultConfig -Override $localConfig

$autoDownload = [bool](Get-ConfigValue -Object $config -Path @("autoDownload") -Default $true)
$toolchainStoreRoot = Resolve-WorkspacePath (Get-ConfigValue -Object $config -Path @("sharedToolchainRoot") -Default $defaultSharedToolchainRoot)
$downloadsDir = Join-Path $toolchainStoreRoot "downloads"
$repoDownloadsDir = Join-Path $root "tools-cache"
$managedBundleRoot = Join-Path $toolchainStoreRoot "openxc7-bundle"
$managedOssCadExtractRoot = Join-Path $toolchainStoreRoot "oss-cad-suite-install"
$managedChipdbRoot = Join-Path $toolchainStoreRoot "chipdb"
$part = Get-ConfigValue -Object $config -Path @("part") -Default "xc7a100tcsg324-1"
$managedChipdbPath = Join-Path $managedChipdbRoot (Split-Path -Leaf (Get-ConfigValue -Object $config -Path @("chipdb", "archiveSubPath") -Default "tools\xc7a100t.bin"))

Ensure-Directory -PathValue $toolchainStoreRoot
Ensure-Directory -PathValue $downloadsDir

if (-not $Force -and (Test-ToolchainEnvFile -FilePath $envFile -DependencyPaths @($defaultConfigPath, $localConfigPath))) {
    Write-Host "Toolchain ready (cached env): $envFile"
    return
}

$bundleRoot = Ensure-OptionalBundle -Config $config
$ossCadRoot = Ensure-OssCadSuite -Config $config -BundleRoot $bundleRoot
$chipdb = Ensure-ChipDb -Config $config -BundleRoot $bundleRoot

$prjxrayRelativeRoot = Get-ConfigValue -Object $config -Path @("toolchainBundle", "prjxrayRoot") -Default "src\prjxray"
$prjxrayDbRelativeRoot = Get-ConfigValue -Object $config -Path @("toolchainBundle", "prjxrayDbRoot") -Default "src\prjxray-db\artix7"
$nextpnrRelativeExe = Get-ConfigValue -Object $config -Path @("toolchainBundle", "nextpnrExe") -Default "nextpnr-xilinx.exe"
$xc7framesRelativeExe = Get-ConfigValue -Object $config -Path @("toolchainBundle", "xc7frames2bitExe") -Default "build\prjxray\tools\xc7frames2bit.exe"
$pathExtrasRelative = Get-PathList -Config $config -Path @("toolchainBundle", "pathExtras")

$prjxrayRoot = Resolve-FirstExistingPath @(
    (Resolve-WorkspacePath (Get-ConfigValue -Object $config -Path @("projectXray", "root"))),
    (Resolve-RelativeToRoot -BasePath $bundleRoot -RelativePath $prjxrayRelativeRoot -Directory),
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
    (Resolve-RelativeToRoot -BasePath $bundleRoot -RelativePath $prjxrayDbRelativeRoot -Directory),
    (Find-ProjectXrayDatabaseRoot -Root $bundleRoot -Part $part),
    (Join-Path $legacyFpgaTools "source-build\src\prjxray-db\artix7")
)

$nextpnrExe = Resolve-FirstExistingPath @(
    (Resolve-WorkspacePath (Get-ConfigValue -Object $config -Path @("nextpnrXilinx", "exePath"))),
    (Resolve-RelativeToRoot -BasePath $bundleRoot -RelativePath $nextpnrRelativeExe -File),
    $legacyNextpnrExe
)

$configuredPythonExe = Resolve-WorkspacePath (Get-ConfigValue -Object $config -Path @("pythonExe"))
$pythonCandidates = @(
    $configuredPythonExe,
    (Join-Path $legacyFpgaTools "pyenv\bin\python.exe"),
    (Join-Path $ossCadRoot "lib\python3.exe"),
    (Find-FirstMatchingFile -Roots @($ossCadRoot) -Names @("python3.exe", "python.exe"))
)
$pythonExe = $null
foreach ($candidate in $pythonCandidates) {
    if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate) -and (Test-PythonModule -PythonPath $candidate -ModuleName "textx")) {
        $pythonExe = [System.IO.Path]::GetFullPath($candidate)
        break
    }
}

if (-not $pythonExe) {
    $pythonExe = Resolve-FirstExistingPath $pythonCandidates
}

$xc7frames2bitExe = Resolve-FirstExistingPath @(
    (Resolve-WorkspacePath (Get-ConfigValue -Object $config -Path @("projectXray", "xc7frames2bitExe"))),
    (Resolve-RelativeToRoot -BasePath $bundleRoot -RelativePath $xc7framesRelativeExe -File),
    (Join-Path $legacyFpgaTools "source-build\build\prjxray\tools\xc7frames2bit.exe")
)

$extraPaths = New-Object System.Collections.Generic.List[string]
foreach ($relativeExtra in $pathExtrasRelative) {
    $resolvedExtra = Resolve-RelativeToRoot -BasePath $bundleRoot -RelativePath $relativeExtra -Directory
    if ($resolvedExtra -and (Test-Path -LiteralPath $resolvedExtra) -and -not $extraPaths.Contains($resolvedExtra)) {
        $extraPaths.Add($resolvedExtra)
    }
}

foreach ($pathEntry in @(
    # nextpnr-xilinx-patched.exe is linked against the MSYS2/UCRT runtime.
    # Keep those DLLs ahead of oss-cad-suite\lib to avoid loader entry-point mismatches.
    (Join-Path $legacyFpgaTools "msys64\ucrt64\bin"),
    (Join-Path $legacyFpgaTools "msys64\usr\bin"),
    (Join-Path $legacyFpgaTools "bin"),
    (Join-Path $ossCadRoot "bin"),
    (Join-Path $ossCadRoot "lib")
)) {
    if ($pathEntry -and (Test-Path -LiteralPath $pathEntry) -and -not $extraPaths.Contains($pathEntry)) {
        $extraPaths.Add($pathEntry)
    }
}

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
    Write-Host "If you want automatic downloads, publish or configure the bundle/chipdb release assets."
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
Write-Host "  Cache root    : $toolchainStoreRoot"
Write-Host "  OSS CAD Suite : $ossCadRoot"
Write-Host "  Yosys         : $($envValues.YOSYS_EXE)"
Write-Host "  nextpnr       : $nextpnrExe"
Write-Host "  xc7frames2bit : $xc7frames2bitExe"
Write-Host "  chipdb        : $chipdb"
Write-Host "  env file      : $envFile"
