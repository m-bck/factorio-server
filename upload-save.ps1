<#
.SYNOPSIS
    Upload a Factorio save file to the server
.DESCRIPTION
    Uploads a local save file to the Factorio server via SCP and optionally restarts the server
.EXAMPLE
    .\upload-save.ps1
    .\upload-save.ps1 -SaveFile "C:\saves\mysave.zip" -ServerIP "192.168.1.100"
#>

param(
    [string]$SaveFile,
    [string]$ServerIP,
    [string]$User = "root",
    [switch]$NoRestart
)

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "  FACTORIO" -ForegroundColor Cyan
Write-Host "  Save File Uploader" -ForegroundColor White
Write-Host ""

# Get server IP if not provided
if (-not $ServerIP) {
    $ServerIP = Read-Host "  Server IP"
}

# Get save file if not provided
if (-not $SaveFile) {
    Write-Host ""
    Write-Host "  Drag and drop your save file here, or enter the path:" -ForegroundColor Yellow
    $SaveFile = Read-Host "  Save file path"
    $SaveFile = $SaveFile.Trim('"').Trim("'")
}

# Validate save file exists
if (-not (Test-Path $SaveFile)) {
    Write-Host ""
    Write-Host "  ERROR: File not found: $SaveFile" -ForegroundColor Red
    exit 1
}

# Validate it's a zip file
if (-not $SaveFile.EndsWith(".zip")) {
    Write-Host ""
    Write-Host "  ERROR: Save file must be a .zip file" -ForegroundColor Red
    exit 1
}

$FileName = Split-Path $SaveFile -Leaf
$FileSize = (Get-Item $SaveFile).Length / 1MB

Write-Host ""
Write-Host "  File:   $FileName" -ForegroundColor White
Write-Host "  Size:   $([math]::Round($FileSize, 2)) MB" -ForegroundColor White
Write-Host "  Server: $User@$ServerIP" -ForegroundColor White
Write-Host ""

# Ask about renaming to world.zip
$TargetName = $FileName
Write-Host "  The server expects 'world.zip' by default." -ForegroundColor Yellow
$rename = Read-Host "  Rename to world.zip? [Y/n]"
if ($rename -ne "n" -and $rename -ne "N") {
    $TargetName = "world.zip"
}

Write-Host ""
Write-Host "  Uploading..." -ForegroundColor Cyan

# Upload via SCP
try {
    $scpTarget = "${User}@${ServerIP}:/opt/factorio/saves/${TargetName}"
    scp $SaveFile $scpTarget
    
    if ($LASTEXITCODE -ne 0) {
        throw "SCP failed with exit code $LASTEXITCODE"
    }
    
    Write-Host "  Upload complete!" -ForegroundColor Green
}
catch {
    Write-Host "  ERROR: Upload failed - $_" -ForegroundColor Red
    exit 1
}

# Fix permissions
Write-Host "  Setting permissions..." -ForegroundColor Cyan
ssh "${User}@${ServerIP}" "chown factorio:factorio /opt/factorio/saves/${TargetName}"

# Restart server
if (-not $NoRestart) {
    Write-Host ""
    $restart = Read-Host "  Restart server now? [Y/n]"
    if ($restart -ne "n" -and $restart -ne "N") {
        Write-Host "  Restarting Factorio server..." -ForegroundColor Cyan
        ssh "${User}@${ServerIP}" "systemctl restart factorio"
        Write-Host "  Server restarted!" -ForegroundColor Green
        
        # Show status
        Write-Host ""
        Write-Host "  Server Status:" -ForegroundColor White
        ssh "${User}@${ServerIP}" "systemctl status factorio --no-pager | head -5"
    }
}

Write-Host ""
Write-Host "  Done! Connect to: ${ServerIP}:34197" -ForegroundColor Green
Write-Host ""
