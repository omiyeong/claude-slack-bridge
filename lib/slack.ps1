# Slack Web API 和 Socket Mode
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Invoke-SlackApi([string]$Method, [hashtable]$Body = @{}, [string]$Token = $script:Cfg.SLACK_BOT_TOKEN) {
    $bytes = $script:Utf8.GetBytes((ConvertTo-JsonText $Body))
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $resp = Invoke-WebRequest -UseBasicParsing -Method Post -Uri "https://slack.com/api/$Method" `
                -Headers @{ Authorization = "Bearer $Token" } -ContentType 'application/json; charset=utf-8' -Body $bytes
        } catch {
            $r = $_.Exception.Response
            if ($r -and [int]$r.StatusCode -eq 429) {
                $wait = [int]($r.Headers['Retry-After']); if ($wait -lt 1) { $wait = 1 }
                Start-Sleep -Seconds $wait
                continue
            }
            if ($attempt -eq 3) { throw }
            Start-Sleep -Seconds 2
            continue
        }
        $text = $script:Utf8.GetString($resp.RawContentStream.ToArray())
        $data = ConvertFrom-JsonDict $text
        if (-not (Get-Dict $data 'ok' $false)) {
            throw "Slack $Method 失败：$(Get-Dict $data 'error' $text)"
        }
        return $data
    }
}

function Split-SlackText([string]$Text, [int]$Max = 11000) {
    # markdown 块单条上限 12000 字符，按段落切，切不开再硬切
    $chunks = @(); $cur = ''
    foreach ($para in ($Text -split "`n`n")) {
        while ($para.Length -gt $Max) {
            if ($cur) { $chunks += $cur; $cur = '' }
            $chunks += $para.Substring(0, $Max); $para = $para.Substring($Max)
        }
        if ($cur -and ($cur.Length + $para.Length + 2) -gt $Max) { $chunks += $cur; $cur = $para }
        elseif ($cur) { $cur = "$cur`n`n$para" } else { $cur = $para }
    }
    if ($cur) { $chunks += $cur }
    if ($chunks.Count -eq 0) { $chunks = @('（空回复）') }
    return $chunks
}

function Send-SlackMarkdown([string]$Channel, [string]$ThreadTs, [string]$Text) {
    foreach ($chunk in (Split-SlackText $Text)) {
        $body = @{ channel = $Channel; text = $chunk; blocks = @(@{ type = 'markdown'; text = $chunk }) }
        if ($ThreadTs) { $body.thread_ts = $ThreadTs }
        try { $last = Invoke-SlackApi 'chat.postMessage' $body }
        catch {
            # markdown 块被拒（比如超长或格式问题）就退回纯文本，至少把内容送到
            Write-Log 'listener' "markdown 块发送失败，改用纯文本：$($_.Exception.Message)"
            $body.Remove('blocks')
            $last = Invoke-SlackApi 'chat.postMessage' $body
        }
    }
    return $last
}

function Set-SlackReaction([string]$Channel, [string]$Ts, [string]$Name, [switch]$Remove) {
    $method = if ($Remove) { 'reactions.remove' } else { 'reactions.add' }
    try { Invoke-SlackApi $method @{ channel = $Channel; timestamp = $Ts; name = $Name } | Out-Null }
    catch {
        # 已经加过 / 本来就没有，不算错误
        if ($_.Exception.Message -notmatch 'already_reacted|no_reaction') { Write-Log 'listener' "表情失败 $Name：$($_.Exception.Message)" }
    }
}

# ---------- Socket Mode ----------

$script:Ws = $null
$script:WsRecv = $null
$script:WsBuf = New-Object byte[] 65536
$script:WsMsg = New-Object System.IO.MemoryStream

function Connect-SlackSocket {
    $open = Invoke-SlackApi 'apps.connections.open' @{} $script:Cfg.SLACK_APP_TOKEN
    if ($script:Ws) { try { $script:Ws.Dispose() } catch {} }
    $script:Ws = New-Object System.Net.WebSockets.ClientWebSocket
    $script:Ws.Options.KeepAliveInterval = [TimeSpan]::FromSeconds(30)
    $script:Ws.ConnectAsync([Uri](Get-Dict $open 'url'), [Threading.CancellationToken]::None).Wait()
    $script:WsRecv = $null
    $script:WsMsg.SetLength(0)
}

function Test-SlackSocketOpen {
    return ($script:Ws -and $script:Ws.State -eq [System.Net.WebSockets.WebSocketState]::Open)
}

function Receive-SlackSocket([int]$TimeoutMs) {
    # 等最多 TimeoutMs 毫秒，收到一条完整消息就返回文本，否则返回 $null；未完成的接收留到下次继续
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    while ($true) {
        if (-not $script:WsRecv) {
            $seg = New-Object 'System.ArraySegment[byte]' (, $script:WsBuf)
            $script:WsRecv = $script:Ws.ReceiveAsync($seg, [Threading.CancellationToken]::None)
        }
        $left = [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds
        if ($left -lt 0) { $left = 0 }
        if (-not $script:WsRecv.Wait($left)) { return $null }
        $r = $script:WsRecv.Result
        $script:WsRecv = $null
        if ($r.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) { throw 'Socket Mode 连接被关闭' }
        $script:WsMsg.Write($script:WsBuf, 0, $r.Count)
        if ($r.EndOfMessage) {
            $text = $script:Utf8.GetString($script:WsMsg.ToArray())
            $script:WsMsg.SetLength(0)
            return $text
        }
    }
}

function Send-SlackSocket([hashtable]$Message) {
    $bytes = $script:Utf8.GetBytes((ConvertTo-JsonText $Message))
    $seg = New-Object 'System.ArraySegment[byte]' (, $bytes)
    $script:Ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None).Wait()
}
