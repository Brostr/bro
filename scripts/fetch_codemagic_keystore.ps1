# Fetches Android keystore from Codemagic API
# Usage: set $env:CODEMAGIC_API_TOKEN first, then run this script

if (-not $env:CODEMAGIC_API_TOKEN) {
    Write-Error "CODEMAGIC_API_TOKEN env var not set. Run: `$env:CODEMAGIC_API_TOKEN = 'your_token'"
    exit 1
}

$headers = @{ "x-auth-token" = $env:CODEMAGIC_API_TOKEN }

Write-Host "=== Listing Android keystores ===" -ForegroundColor Cyan
try {
    $list = Invoke-RestMethod -Uri "https://api.codemagic.io/signing-files/android-keystore" -Headers $headers -ErrorAction Stop
    $list | ConvertTo-Json -Depth 10
} catch {
    Write-Host "Error listing keystores:" -ForegroundColor Red
    Write-Host $_.Exception.Message
    Write-Host "StatusCode: $($_.Exception.Response.StatusCode.value__)"
    exit 1
}

# Try to extract id
$keystore = $list | Where-Object { $_.referenceName -eq 'bro_keystore' -or $_.name -eq 'bro_keystore' } | Select-Object -First 1
if (-not $keystore) {
    $keystore = $list | Select-Object -First 1
}

if (-not $keystore) {
    Write-Host "No keystore found in response." -ForegroundColor Yellow
    exit 1
}

$id = $keystore.id
if (-not $id) { $id = $keystore._id }
Write-Host ""
Write-Host "Found keystore id: $id" -ForegroundColor Green

Write-Host ""
Write-Host "=== Attempting download (variant 1: /signing-files/android-keystore/<id>) ===" -ForegroundColor Cyan
$out1 = "bro_keystore_v1.jks"
try {
    Invoke-WebRequest -Uri "https://api.codemagic.io/signing-files/android-keystore/$id" -Headers $headers -OutFile $out1 -ErrorAction Stop
    $size = (Get-Item $out1).Length
    Write-Host "Saved $out1 ($size bytes)" -ForegroundColor Green
} catch {
    Write-Host "Variant 1 failed: $($_.Exception.Message)" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=== Attempting download (variant 2: /signing-files/android-keystore/<id>/file) ===" -ForegroundColor Cyan
$out2 = "bro_keystore_v2.jks"
try {
    Invoke-WebRequest -Uri "https://api.codemagic.io/signing-files/android-keystore/$id/file" -Headers $headers -OutFile $out2 -ErrorAction Stop
    $size = (Get-Item $out2).Length
    Write-Host "Saved $out2 ($size bytes)" -ForegroundColor Green
} catch {
    Write-Host "Variant 2 failed: $($_.Exception.Message)" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=== Attempting download (variant 3: /signing-files/android-keystore/<id>/download) ===" -ForegroundColor Cyan
$out3 = "bro_keystore_v3.jks"
try {
    Invoke-WebRequest -Uri "https://api.codemagic.io/signing-files/android-keystore/$id/download" -Headers $headers -OutFile $out3 -ErrorAction Stop
    $size = (Get-Item $out3).Length
    Write-Host "Saved $out3 ($size bytes)" -ForegroundColor Green
} catch {
    Write-Host "Variant 3 failed: $($_.Exception.Message)" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=== Done. Check files with: Get-ChildItem bro_keystore_v*.jks ===" -ForegroundColor Cyan
