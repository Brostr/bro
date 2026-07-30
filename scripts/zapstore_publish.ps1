# Zapstore publish helper for Bro
# - Masked nsec/seed prompt (no echo, never stored in history or command line)
# - Passes the key to the WSL zapstore CLI via SIGN_WITH (WSLENV), never as an argument
# - Clears the key from memory afterwards
param([switch]$VerifyOnly)

$ErrorActionPreference = 'Stop'

# ----------------------------------------------------------------------
# Janela grafica (Windows Forms) com campo de senha mascarado.
# A chave NUNCA aparece na tela, no terminal nem no historico.
# ----------------------------------------------------------------------
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$form = New-Object System.Windows.Forms.Form
$form.Text = if ($VerifyOnly) { 'Verificar SEED/chave - Bro (sem publicar)' } else { 'Zapstore Publish - Bro v1.0.133+619' }
$form.Size = New-Object System.Drawing.Size(540, 230)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.MinimizeBox = $false
$form.TopMost = $true
$form.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 38)

$lbl = New-Object System.Windows.Forms.Label
$lbl.Text = if ($VerifyOnly) { "Cole sua SEED (12/24 palavras) OU nsec.`r`nVou SO conferir a chave - nada sera publicado." } else { "Cole sua SEED (12/24 palavras) OU nsec/chave hex de 64.`r`nA digitacao fica OCULTA. Depois clique em Publicar." }
$lbl.AutoSize = $false
$lbl.Size = New-Object System.Drawing.Size(500, 50)
$lbl.Location = New-Object System.Drawing.Point(15, 15)
$lbl.ForeColor = [System.Drawing.Color]::Gainsboro
$lbl.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$form.Controls.Add($lbl)

$txt = New-Object System.Windows.Forms.TextBox
$txt.UseSystemPasswordChar = $true
$txt.Size = New-Object System.Drawing.Size(500, 28)
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
$btnOk.Text = if ($VerifyOnly) { 'Verificar' } else { 'Publicar' }
$btnOk.Size = New-Object System.Drawing.Size(120, 36)
$btnOk.Location = New-Object System.Drawing.Point(275, 145)
$btnOk.BackColor = [System.Drawing.Color]::FromArgb(255, 140, 0)
$btnOk.ForeColor = [System.Drawing.Color]::Black
$btnOk.FlatStyle = 'Flat'
$btnOk.DialogResult = [System.Windows.Forms.DialogResult]::OK
$form.Controls.Add($btnOk)
$form.AcceptButton = $btnOk

$btnCancel = New-Object System.Windows.Forms.Button
$btnCancel.Text = 'Cancelar'
$btnCancel.Size = New-Object System.Drawing.Size(120, 36)
$btnCancel.Location = New-Object System.Drawing.Point(405, 145)
$btnCancel.BackColor = [System.Drawing.Color]::FromArgb(60, 60, 70)
$btnCancel.ForeColor = [System.Drawing.Color]::White
$btnCancel.FlatStyle = 'Flat'
$btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
$form.Controls.Add($btnCancel)
$form.CancelButton = $btnCancel

$form.Add_Shown({ $txt.Focus() })
$result = $form.ShowDialog()

if ($result -ne [System.Windows.Forms.DialogResult]::OK) {
    Write-Host 'Cancelado pelo usuario. Nada foi publicado.' -ForegroundColor Yellow
    $form.Dispose()
    exit 1
}

$key = $txt.Text
$txt.Text = ''
$form.Dispose()

$key = $key.Trim()

if ([string]::IsNullOrWhiteSpace($key)) {
    Write-Host 'Nenhuma chave informada. Abortando.' -ForegroundColor Red
    exit 1
}

# Expected Zapstore publisher pubkey for Bro = the OWNER of the existing
# app.bro.mobile listing on relay.zapstore.dev (npub14dkurl..., created 2026-05-21).
# Only this pubkey may UPDATE the listing; any other pubkey is rejected by the
# relay with "another pubkey has already published an app with the same 'd' tag".
$expectedPub = 'ab6dc1fcd5659b406d3e0512e05e8afde3b9bfc776e0a9657f57eae9ef069a2e'

# Detect input type: BIP-39 seed (>= 12 words) vs nsec/hex
$words = $key -split '\s+' | Where-Object { $_ -ne '' }
$looksNsec = $key.StartsWith('nsec1')
$looksHex  = ($key -match '^[0-9a-fA-F]{64}$')
$looksSeed = ($words.Count -ge 12) -and (-not $looksNsec) -and (-not $looksHex)

if ($looksSeed) {
    Write-Host ('Seed detectada (' + $words.Count + ' palavras). Derivando chave Nostr via NIP-06...') -ForegroundColor Cyan
    $proj = 'C:\Users\produ\Documents\GitHub\bro_app'
    Push-Location $proj
    try {
        $env:BRO_SEED = $key
        $env:BRO_EMIT_SEC = '1'
        # Capture derivation output ONLY in a variable (never written to log)
        $derived = & dart run scripts/derive_nostr_key.dart 2>&1
    }
    finally {
        $env:BRO_SEED = $null
        Remove-Item Env:BRO_SEED -ErrorAction SilentlyContinue
        $env:BRO_EMIT_SEC = $null
        Remove-Item Env:BRO_EMIT_SEC -ErrorAction SilentlyContinue
        Pop-Location
    }
    $pubLine = ($derived | Select-String -Pattern '^PUBKEY=([0-9a-fA-F]{64})$')
    $secLine = ($derived | Select-String -Pattern '^NSEC=(nsec1[0-9a-z]+)$')
    if (-not $pubLine -or -not $secLine) {
        Write-Host 'Falha ao derivar a chave da seed (seed invalida?). Abortando.' -ForegroundColor Red
        Write-Host ($derived | Where-Object { $_ -notmatch 'SEC=' } | Out-String) -ForegroundColor DarkGray
        $key = $null; exit 1
    }
    $derivedPub = $pubLine.Matches[0].Groups[1].Value.ToLower()
    $key = $secLine.Matches[0].Groups[1].Value  # use derived nsec as signing key
    $derived = $null
    Write-Host ('npub derivada (hex): ' + $derivedPub) -ForegroundColor Cyan
    if ($derivedPub -ne $expectedPub) {
        Write-Host '' 
        Write-Host 'ATENCAO: a chave derivada NAO e a publisher autorizada no relay.' -ForegroundColor Red
        Write-Host ("  esperado: $expectedPub") -ForegroundColor DarkGray
        Write-Host ("  derivado: $derivedPub") -ForegroundColor DarkGray
        Write-Host 'Esta seed e de outra identidade. O relay vai recusar. Abortando.' -ForegroundColor Red
        $key = $null; exit 2
    }
    Write-Host 'OK! Seed corresponde a dona da listagem (npub14dkurl...).' -ForegroundColor Green
    $looksNsec = $true
}
elseif (-not ($looksNsec -or $looksHex)) {
    Write-Host 'Formato inesperado (esperado seed 12/24 palavras, nsec1... ou 64 hex). Abortando por seguranca.' -ForegroundColor Red
    $key = $null
    exit 1
}
Write-Host ('Chave pronta OK (' + $key.Length + ' chars). Iniciando publicacao...') -ForegroundColor Green
Write-Host ''

if ($VerifyOnly) {
    Write-Host '=== MODO VERIFICACAO: chave conferida, NADA foi publicado. ===' -ForegroundColor Yellow
    $key = $null
    [System.GC]::Collect()
    Write-Host 'Chave removida da memoria.' -ForegroundColor DarkGray
    Write-Host 'Pode fechar esta janela.' -ForegroundColor DarkGray
    exit 0
}

try {
    # Share SIGN_WITH into WSL without ever putting it on a command line
    $env:SIGN_WITH = $key
    $env:WSLENV = 'SIGN_WITH/u'

    $log = 'C:\Users\produ\Documents\GitHub\bro_app\scripts\zapstore_publish.log'
    "===== zapstore publish $(Get-Date -Format o) =====" | Out-File -FilePath $log -Encoding utf8
    # The retry loop lives in a .sh file to avoid PowerShell/WSL quote mangling.
    wsl -d Ubuntu -- bash /mnt/c/Users/produ/Documents/GitHub/bro_app/scripts/zapstore_run.sh 2>&1 | Tee-Object -FilePath $log -Append
    $code = $LASTEXITCODE
    Write-Host ''
    Write-Host ("zapstore publish terminou com exit code: $code") -ForegroundColor Cyan
    "EXIT_CODE=$code" | Out-File -FilePath $log -Append -Encoding utf8
}
finally {
    # Wipe the key from this process environment and memory
    $env:SIGN_WITH = $null
    Remove-Item Env:SIGN_WITH -ErrorAction SilentlyContinue
    $env:WSLENV = $null
    Remove-Item Env:WSLENV -ErrorAction SilentlyContinue
    $key = $null
    [System.GC]::Collect()
    Write-Host 'Chave removida da memoria.' -ForegroundColor DarkGray
}
