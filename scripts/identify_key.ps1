# Identify-key helper for Bro / Zapstore  (LOOP MODE)
# - Masked prompt (seed OR nsec/hex). The secret NEVER appears on screen, in the
#   terminal, in history, on a command line, or in any log.
# - Shows ONLY the resulting PUBLIC npub + hex pubkey, and whether it matches the
#   Zapstore listing owner (ab6dc1fc...). The npub is public: safe to share.
# - Loops: paste one key, see result, paste the next... Cancel to stop.
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$owner = 'ab6dc1fcd5659b406d3e0512e05e8afde3b9bfc776e0a9657f57eae9ef069a2e'
$resultFile = 'C:\Users\produ\Documents\GitHub\bro_app\scripts\_idresult.txt'

function Read-MaskedKey {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Identificar chave - Bro (so mostra a npub publica)'
    $form.Size = New-Object System.Drawing.Size(560, 230)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.TopMost = $true
    $form.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 38)

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = "Cole uma SEED (12/24 palavras) OU nsec/hex.`r`nMostro SO a npub publica. Cancelar encerra o loop."
    $lbl.AutoSize = $false
    $lbl.Size = New-Object System.Drawing.Size(520, 50)
    $lbl.Location = New-Object System.Drawing.Point(15, 15)
    $lbl.ForeColor = [System.Drawing.Color]::Gainsboro
    $lbl.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $form.Controls.Add($lbl)

    $txt = New-Object System.Windows.Forms.TextBox
    $txt.UseSystemPasswordChar = $true
    $txt.Size = New-Object System.Drawing.Size(520, 28)
    $txt.Location = New-Object System.Drawing.Point(15, 75)
    $txt.Font = New-Object System.Drawing.Font('Consolas', 11)
    $form.Controls.Add($txt)

    $chk = New-Object System.Windows.Forms.CheckBox
    $chk.Text = 'Mostrar chave'
    $chk.Location = New-Object System.Drawing.Point(15, 110)
    $chk.Size = New-Object System.Drawing.Size(150, 24)
    $chk.ForeColor = [System.Drawing.Color]::Gainsboro
    $chk.Add_CheckedChanged({ $txt.UseSystemPasswordChar = -not $chk.Checked })
    $form.Controls.Add($chk)

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = 'Identificar'
    $btnOk.Size = New-Object System.Drawing.Size(120, 36)
    $btnOk.Location = New-Object System.Drawing.Point(295, 145)
    $btnOk.BackColor = [System.Drawing.Color]::FromArgb(255, 140, 0)
    $btnOk.ForeColor = [System.Drawing.Color]::Black
    $btnOk.FlatStyle = 'Flat'
    $btnOk.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Controls.Add($btnOk)
    $form.AcceptButton = $btnOk

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = 'Cancelar'
    $btnCancel.Size = New-Object System.Drawing.Size(120, 36)
    $btnCancel.Location = New-Object System.Drawing.Point(425, 145)
    $btnCancel.BackColor = [System.Drawing.Color]::FromArgb(60, 60, 70)
    $btnCancel.ForeColor = [System.Drawing.Color]::White
    $btnCancel.FlatStyle = 'Flat'
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($btnCancel)
    $form.CancelButton = $btnCancel

    $form.Add_Shown({ $txt.Focus() })
    $res = $form.ShowDialog()
    $val = $txt.Text
    $txt.Text = ''
    $form.Dispose()
    if ($res -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
    return $val
}

function Get-PubFromKey([string]$key) {
    $words = $key -split '\s+' | Where-Object { $_ -ne '' }
    $looksNsec = $key.StartsWith('nsec1')
    $looksHex  = ($key -match '^[0-9a-fA-F]{64}$')
    $looksSeed = ($words.Count -ge 12) -and (-not $looksNsec) -and (-not $looksHex)
    $hexPub = $null
    if ($looksSeed) {
        Write-Host ('Seed (' + $words.Count + ' palavras). Derivando via NIP-06...') -ForegroundColor Cyan
        $proj = 'C:\Users\produ\Documents\GitHub\bro_app'
        Push-Location $proj
        try {
            $env:BRO_SEED = $key
            $env:BRO_EMIT_SEC = '0'
            $derived = & dart run scripts/derive_nostr_key.dart 2>&1
        }
        finally {
            $env:BRO_SEED = $null; Remove-Item Env:BRO_SEED -ErrorAction SilentlyContinue
            $env:BRO_EMIT_SEC = $null; Remove-Item Env:BRO_EMIT_SEC -ErrorAction SilentlyContinue
            Pop-Location
        }
        $pubLine = ($derived | Select-String -Pattern '^PUBKEY=([0-9a-fA-F]{64})$')
        $derived = $null
        if ($pubLine) { $hexPub = $pubLine.Matches[0].Groups[1].Value.ToLower() }
    }
    elseif ($looksNsec -or $looksHex) {
        Write-Host 'nsec/hex. Derivando pubkey via WSL (sem expor a chave)...' -ForegroundColor Cyan
        try {
            $env:IDKEY = $key
            $env:WSLENV = 'IDKEY/u'
            $out = wsl -d Ubuntu -- bash /mnt/c/Users/produ/Documents/GitHub/bro_app/scripts/idkey_run.sh 2>&1
        }
        finally {
            $env:IDKEY = $null; Remove-Item Env:IDKEY -ErrorAction SilentlyContinue
            $env:WSLENV = $null; Remove-Item Env:WSLENV -ErrorAction SilentlyContinue
        }
        $hl = ($out | Select-String -Pattern '^HEX=([0-9a-fA-F]{64})$')
        if ($hl) { $hexPub = $hl.Matches[0].Groups[1].Value.ToLower() }
    }
    else {
        Write-Host 'Formato inesperado (use seed 12/24, nsec1... ou 64 hex).' -ForegroundColor Red
    }
    return $hexPub
}

Write-Host '=== Identificador de chaves (loop). Cancelar encerra. ===' -ForegroundColor White
$n = 0
while ($true) {
    $key = Read-MaskedKey
    if ($null -eq $key) { Write-Host 'Encerrado.' -ForegroundColor Yellow; break }
    $key = $key.Trim()
    if ([string]::IsNullOrWhiteSpace($key)) { Write-Host 'Vazio, ignorado.' -ForegroundColor DarkGray; continue }
    $n++
    $hexPub = $null
    try { $hexPub = Get-PubFromKey $key } finally { $key = $null; [System.GC]::Collect() }
    if (-not $hexPub) { Write-Host "[$n] Nao derivou (chave invalida?)." -ForegroundColor Red; continue }
    $npub = (wsl -d Ubuntu -- bash -lc "/home/produ/bin/nak encode npub $hexPub" 2>&1).Trim()
    $isOwner = ($hexPub -eq $owner)
    Write-Host ''
    Write-Host "===== chave #$n (PUBLICO) =====" -ForegroundColor White
    Write-Host ("hex : $hexPub") -ForegroundColor Gray
    Write-Host ("npub: $npub") -ForegroundColor Cyan
    if ($isOwner) {
        Write-Host '>>> ESTA E A DONA (ab6dc1fc)! Use para publicar. <<<' -ForegroundColor Green
    } else {
        Write-Host '>>> NAO e a dona (esperado ab6dc1fc). <<<' -ForegroundColor Yellow
    }
    Write-Host '===============================' -ForegroundColor White
    $match = if ($isOwner) { 'OWNER_MATCH' } else { 'NOT_OWNER' }
    "$(Get-Date -Format o) hex=$hexPub npub=$npub $match" | Out-File -FilePath $resultFile -Append -Encoding utf8
    if ($isOwner) { Write-Host 'Encontrei a dona! Pode parar (Cancelar) e me avisar.' -ForegroundColor Green }
}
Write-Host 'Chaves removidas da memoria. Pode me dizer as npubs (sao publicas).' -ForegroundColor DarkGray
