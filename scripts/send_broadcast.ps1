# Send broadcast push using a Windows password dialog (no shell input — cannot leak).
# Usage: .\scripts\send_broadcast.ps1
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Broadcast Push - ADMIN_NSEC'
$form.Size = New-Object System.Drawing.Size(540,200)
$form.StartPosition = 'CenterScreen'
$form.TopMost = $true
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.MinimizeBox = $false

$label = New-Object System.Windows.Forms.Label
$label.Location = New-Object System.Drawing.Point(15,15)
$label.Size = New-Object System.Drawing.Size(500,50)
$label.Text = "Cole sua ADMIN_NSEC abaixo (input oculto, igual senha)." + [Environment]::NewLine + "Depois clique OK para enviar o push para TODOS os usuarios."
$form.Controls.Add($label)

$textBox = New-Object System.Windows.Forms.TextBox
$textBox.Location = New-Object System.Drawing.Point(15,70)
$textBox.Size = New-Object System.Drawing.Size(500,25)
$textBox.UseSystemPasswordChar = $true
$form.Controls.Add($textBox)

$okButton = New-Object System.Windows.Forms.Button
$okButton.Location = New-Object System.Drawing.Point(335,115)
$okButton.Size = New-Object System.Drawing.Size(85,28)
$okButton.Text = 'OK (Enviar)'
$okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
$form.AcceptButton = $okButton
$form.Controls.Add($okButton)

$cancelButton = New-Object System.Windows.Forms.Button
$cancelButton.Location = New-Object System.Drawing.Point(425,115)
$cancelButton.Size = New-Object System.Drawing.Size(90,28)
$cancelButton.Text = 'Cancelar'
$cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
$form.CancelButton = $cancelButton
$form.Controls.Add($cancelButton)

$form.Add_Shown({ $textBox.Focus() })
$result = $form.ShowDialog()
if ($result -ne [System.Windows.Forms.DialogResult]::OK) {
  Write-Host 'Cancelado.' -ForegroundColor Yellow
  $form.Dispose()
  return
}

$nsec = $textBox.Text.Trim()
$textBox.Text = ''
$form.Dispose()

if ([string]::IsNullOrWhiteSpace($nsec)) {
  Write-Host 'ERRO: nsec vazia.' -ForegroundColor Red
  return
}

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$env:ADMIN_NSEC = $nsec
$env:BROADCAST_TITLE = "Atenção: confirme seu backup"
$env:BROADCAST_BODY  = "Atenção: nos próximos dias a nova versão exigirá desinstalar e reinstalar o app. Confirme que você anotou suas 12 palavras (Settings → Backup). Sem elas, você perde o acesso a sua conta."

try {
  node scripts/broadcast_push.mjs
} finally {
  Remove-Item Env:ADMIN_NSEC -ErrorAction SilentlyContinue
  $nsec = $null
  [System.GC]::Collect()
}
