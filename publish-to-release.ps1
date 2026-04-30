# Script to split toolchain and upload to GitHub Release for instant parallel downloads
# Usage: .\publish-to-release.ps1 -Owner YourUsername -Repo FPGA_Compiler_window -Token $env:GITHUB_TOKEN

param(
    [string]$Owner = "HaiPhan285",
    [string]$Repo = "FPGA_Compiler_window",
    [string]$Token,
    [string]$Tag = "toolchain-v1",
    [string]$ReleaseTitle = "Pre-built Toolchain (Parallel Download)",
    [int]$PartSize = 1000MB
)

if (-not $Token) {
    Write-Host "❌ Error: GITHUB_TOKEN not provided"
    Write-Host "Usage: .\publish-to-release.ps1 -Token 'your-github-token'"
    exit 1
}

$RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$ToolchainZip = Join-Path $RepoRoot ".toolchain.zip"

if (-not (Test-Path $ToolchainZip)) {
    Write-Host "⚠️  Creating .toolchain.zip from .toolchain folder..."
    $TarCmd = Get-Command "tar.exe" -ErrorAction SilentlyContinue
    if ($TarCmd) {
        & $TarCmd.Source -cf (Join-Path $RepoRoot ".toolchain-temp.tar.gz") -C $RepoRoot ".toolchain"
        if ($LASTEXITCODE -ne 0) { throw "tar failed" }
        Write-Host "✅ Created .toolchain-temp.tar.gz"
    } else {
        throw ".toolchain folder not found and tar.exe not available"
    }
}

Write-Host "📦 File size: $('{0:N0}' -f ((Get-Item $ToolchainZip).Length / 1MB)) MB"
Write-Host "📊 Splitting into $('{0:N1}' -f ($PartSize / 1MB)) MB parts..."

# Split into parts
$Parts = @()
$FileSize = (Get-Item $ToolchainZip).Length
$NumParts = [Math]::Ceiling($FileSize / $PartSize)

$Reader = [System.IO.File]::OpenRead($ToolchainZip)
for ($i = 0; $i -lt $NumParts; $i++) {
    $PartPath = Join-Path $RepoRoot ".toolchain-part-$($i+1).zip"
    $PartFile = [System.IO.File]::Create($PartPath)
    
    $BytesRead = 0
    $Buffer = New-Object byte[] 1MB
    while ($BytesRead -lt $PartSize) {
        $Read = $Reader.Read($Buffer, 0, [Math]::Min($Buffer.Length, $PartSize - $BytesRead))
        if ($Read -le 0) { break }
        $PartFile.Write($Buffer, 0, $Read)
        $BytesRead += $Read
    }
    $PartFile.Close()
    
    $PartSize = $PartFile.Length
    $Parts += @{ Name = (Split-Path -Leaf $PartPath); Path = $PartPath; Size = $PartFile.Length }
    Write-Host "  ✅ Part $($i+1): $('{0:N0}' -f ($PartFile.Length / 1MB)) MB"
}
$Reader.Close()

Write-Host "🚀 Uploading to GitHub Release..."
Write-Host "   Owner: $Owner"
Write-Host "   Repo: $Repo"
Write-Host "   Tag: $Tag"
Write-Host "   Parts: $($Parts.Count)"

# Create or update release
$ApiUrl = "https://api.github.com/repos/$Owner/$Repo/releases"
$Headers = @{
    "Authorization" = "token $Token"
    "Accept" = "application/vnd.github.v3+json"
    "Content-Type" = "application/json"
}

# Check if release exists
try {
    $ExistingRelease = Invoke-RestMethod -Uri "$ApiUrl/tags/$Tag" -Headers $Headers -ErrorAction SilentlyContinue
    $ReleaseId = $ExistingRelease.id
    Write-Host "ℹ️  Updating existing release: $Tag"
} catch {
    Write-Host "ℹ️  Creating new release: $Tag"
    
    $Body = @{
        tag_name = $Tag
        name = $ReleaseTitle
        body = "Pre-built FPGA toolchain for instant setup. Download parts in parallel for 3x speed!"
        draft = $false
        prerelease = $false
    } | ConvertTo-Json
    
    $Release = Invoke-RestMethod -Uri $ApiUrl -Method Post -Headers $Headers -Body $Body
    $ReleaseId = $Release.id
}

# Upload parts
foreach ($Part in $Parts) {
    $UploadUrl = "https://uploads.github.com/repos/$Owner/$Repo/releases/$ReleaseId/assets?name=$($Part.Name)"
    Write-Host "   Uploading $($Part.Name) ($('{0:N0}' -f ($Part.Size / 1MB)) MB)..."
    
    try {
        Invoke-RestMethod -Uri $UploadUrl -Method Post -Headers $Headers -InFile $Part.Path | Out-Null
        Write-Host "   ✅ $($Part.Name)"
    } catch {
        Write-Host "   ❌ Failed: $_"
    }
}

Write-Host ""
Write-Host "✅ Release published!"
Write-Host "   URL: https://github.com/$Owner/$Repo/releases/tag/$Tag"
Write-Host ""
Write-Host "🎯 Friends can now use:"
Write-Host "   .\fpga.bat setup -FromRelease -ReleaseTag $Tag"
Write-Host ""
Write-Host "Cleanup (remove temp files):"
Write-Host "   Remove-Item '.toolchain-part-*.zip'"

# Cleanup - optional
Write-Host ""
Read-Host "Press Enter to clean up temporary files (or Ctrl+C to skip)"
Remove-Item (Join-Path $RepoRoot ".toolchain-part-*.zip") -Force 2>/dev/null
Write-Host "Cleaned up ✅"
