$ErrorActionPreference = 'Stop'
$pubkey = 'ab6dc1fcd5659b406d3e0512e05e8afde3b9bfc776e0a9657f57eae9ef069a2e'
$relay  = 'wss://relay.zapstore.dev'

$ws = New-Object System.Net.WebSockets.ClientWebSocket
$ct = (New-Object System.Threading.CancellationTokenSource([TimeSpan]::FromSeconds(20))).Token
$ws.ConnectAsync([Uri]$relay, $ct).Wait()

$subId = 'bro-check'
$req = '["REQ","' + $subId + '",{"authors":["' + $pubkey + '"],"kinds":[32267,30063,1063],"limit":20}]'
$bytes = [System.Text.Encoding]::UTF8.GetBytes($req)
$seg = New-Object System.ArraySegment[byte] (,$bytes)
$ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $ct).Wait()

$buf = New-Object byte[] 65536
$found = @{}
$deadline = (Get-Date).AddSeconds(15)
$sb = New-Object System.Text.StringBuilder
while ((Get-Date) -lt $deadline -and $ws.State -eq 'Open') {
    try {
        $recvSeg = New-Object System.ArraySegment[byte] (,$buf)
        $r = $ws.ReceiveAsync($recvSeg, $ct)
        if (-not $r.Wait(3000)) { continue }
        $res = $r.Result
        $chunk = [System.Text.Encoding]::UTF8.GetString($buf, 0, $res.Count)
        [void]$sb.Append($chunk)
        if ($res.EndOfMessage) {
            $msg = $sb.ToString(); $sb.Clear() | Out-Null
            try { $j = $msg | ConvertFrom-Json } catch { continue }
            if ($j[0] -eq 'EVENT') {
                $ev = $j[2]
                $name = ($ev.tags | Where-Object { $_[0] -eq 'name' -or $_[0] -eq 'd' } | Select-Object -First 1)
                $ver  = ($ev.tags | Where-Object { $_[0] -eq 'version' } | Select-Object -First 1)
                $t = [DateTimeOffset]::FromUnixTimeSeconds([long]$ev.created_at).ToString('u')
                $key = "$($ev.kind)"
                if (-not $found.ContainsKey($key)) { $found[$key] = 0 }
                $found[$key]++
                Write-Host ("kind=$($ev.kind)  created=$t  d/name=$($name -join '/')  version=$($ver -join '/')") -ForegroundColor Green
            } elseif ($j[0] -eq 'EOSE') {
                Write-Host '--- EOSE (fim) ---' -ForegroundColor Cyan
                break
            }
        }
    } catch { break }
}
Write-Host ''
Write-Host 'RESUMO:' -ForegroundColor Yellow
'32267 (app)','30063 (release)','1063 (file)' | ForEach-Object {
    $k = ($_ -split ' ')[0]
    $c = if ($found.ContainsKey($k)) { $found[$k] } else { 0 }
    Write-Host ("  kind $_ : $c evento(s)")
}
$ws.Dispose()
