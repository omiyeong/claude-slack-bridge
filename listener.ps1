# 常驻监听程序：唯一持有 Slack 连接的进程。
# 取 spool 里的 hook 事件发到 Slack 私信；收你在 thread 里的回复，打回对应的桌面会话；处理选择题按钮。
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\common.ps1')
. (Join-Path $PSScriptRoot 'lib\slack.ps1')

$script:Cfg = Read-BridgeEnv
$Owner = $Cfg.OWNER_USER_ID
$AwayAfter = [int]$Cfg.AWAY_AFTER_SECONDS
$InjectIdle = [int]$Cfg.INJECT_IDLE_SECONDS
$VerifySeconds = 15

$StatusEmoji = @{ running = 'arrow_forward'; stop = 'large_green_circle'; ask = 'large_blue_circle'; perm = 'large_orange_circle'; notify = 'large_yellow_circle'; handled = 'white_circle' }
$StatusText = @{ running = '已收到回复，进行中'; stop = '已停下'; ask = '等你选择'; perm = '等你授权'; notify = '等你输入'; handled = '已在电脑上处理' }

# ---------- 状态 ----------

function Read-State {
    if (Test-Path $script:StateFile) { $s = ConvertFrom-JsonDict (Read-TextFile $script:StateFile) }
    else { $s = New-Object 'System.Collections.Generic.Dictionary[string,object]' }
    if (-not $s.ContainsKey('sessions')) { $s['sessions'] = New-Object 'System.Collections.Generic.Dictionary[string,object]' }
    return $s
}
function Save-State { Write-TextFileAtomic $script:StateFile (ConvertTo-JsonText $script:State) }

$script:State = Read-State
$script:Pending = @{}          # request_id -> @{ req; ts; sel; host }
$script:InjectQueue = New-Object System.Collections.Queue
$script:InjectJob = $null      # 正在打字的子进程
$script:Verifying = @()        # 打完字等 transcript 确认的回复
$script:SeenEvents = New-Object System.Collections.Generic.List[string]

function Test-Away { return (Get-IdleSeconds) -ge $AwayAfter }

function Get-Project([string]$Cwd) { if ($Cwd) { return Split-Path $Cwd -Leaf } else { return '~' } }

function Get-SessionByThread([string]$ThreadTs) {
    foreach ($kv in $script:State.sessions.GetEnumerator()) {
        if ((Get-Dict $kv.Value 'thread_ts') -eq $ThreadTs -or @(Get-Dict $kv.Value 'old_threads' @()) -contains $ThreadTs) { return @{ host = $kv.Key; s = $kv.Value } }
    }
    return $null
}

function Update-SessionInfo($Ev) {
    $host_ = $Ev.host_id
    if (-not $script:State.sessions.ContainsKey($host_)) {
        $script:State.sessions[$host_] = New-Object 'System.Collections.Generic.Dictionary[string,object]'
    }
    $s = $script:State.sessions[$host_]
    foreach ($k in @('cli_id', 'cwd', 'transcript')) { if (Get-Dict $Ev $k) { $s[$k] = $Ev[$k] } }
    if (Get-Dict $Ev 'title') { $s['title'] = $Ev.title }
    return $s
}

function Get-ParentText($S, [string]$Status) {
    $name = Get-Project (Get-Dict $S 'cwd')
    $title = Get-Dict $S 'title' ''
    $head = if ($title) { "*$name · $title*" } else { "*$name*" }
    return "$head`n$($StatusText[$Status]) · $(Get-Date -Format 'HH:mm')"
}

function Get-LatestTopTs {
    $h = Invoke-SlackApi 'conversations.history' @{ channel = $script:State.dm; limit = '1' }
    $m = @(Get-Dict $h 'messages' @())
    if ($m.Count) { return [string](Get-Dict $m[0] 'ts') } else { return '' }
}

function Confirm-Thread($S) {
    # 要往会话 thread 里发东西前调用：保证这个会话的 thread 在私信最下面。
    # Slack 的 thread 不会因为有新回复而下移，所以不在最下面时就新开一个 thread，旧的标成“已移到下方”。
    $old = [string](Get-Dict $S 'thread_ts' '')
    if ($old) {
        try { if ((Get-LatestTopTs) -eq $old) { return } } catch { return }
        $st = Get-Dict $S 'status'
        try {
            Invoke-SlackApi 'chat.update' @{ channel = $script:State.dm; ts = $old; text = "$((Get-ParentText $S $st).Split("`n")[0])`n已移到下方" } | Out-Null
            if ($st -and $StatusEmoji.ContainsKey($st)) { Set-SlackReaction $script:State.dm $old $StatusEmoji[$st] -Remove }
        } catch { Write-Log 'listener' "标记旧 thread 失败：$($_.Exception.Message)" }
        # 旧 thread 里回复仍然送到这个会话
        $S['old_threads'] = @(@(Get-Dict $S 'old_threads' @()) + $old | Select-Object -Last 20)
    }
    $r = Invoke-SlackApi 'chat.postMessage' @{ channel = $script:State.dm; text = (Get-ParentText $S 'stop') }
    $S['thread_ts'] = Get-Dict $r 'ts'
    # 状态表情要重新加到新开头消息上
    $S['status'] = $null
    Save-State
}

function Set-SessionStatus($S, [string]$Status) {
    $old = Get-Dict $S 'status'
    $S['status'] = $Status
    Save-State
    if (-not (Get-Dict $S 'thread_ts')) { return }
    try { Invoke-SlackApi 'chat.update' @{ channel = $script:State.dm; ts = $S.thread_ts; text = (Get-ParentText $S $Status) } | Out-Null }
    catch { Write-Log 'listener' "更新开头消息失败：$($_.Exception.Message)" }
    if ($old -and $old -ne $Status -and $StatusEmoji.ContainsKey($old)) { Set-SlackReaction $script:State.dm $S.thread_ts $StatusEmoji[$old] -Remove }
    Set-SlackReaction $script:State.dm $S.thread_ts $StatusEmoji[$Status]
}

function Send-Thread($S, [string]$Text) { Send-SlackMarkdown $script:State.dm $S.thread_ts $Text | Out-Null }

# ---------- hook 事件 ----------

function Test-OpenQuestion([string]$HostId) {
    foreach ($f in @(Get-ChildItem $script:PendingDir -Filter '*.json' | Where-Object { $_.Name -notlike 'inject-*' })) {
        if (Test-Path (Join-Path $script:PendingDir "$($f.BaseName).closed")) { continue }
        try { $req = ConvertFrom-JsonDict (Read-TextFile $f.FullName) } catch { continue }
        if ((Get-Dict $req 'host_id') -eq $HostId -and (Test-ProcessAlive ([int](Get-Dict $req 'pid' 0)))) { return $true }
    }
    return $false
}

function Invoke-SpoolEvents {
    foreach ($f in @(Get-ChildItem $script:SpoolDir -Filter '*.json' | Sort-Object Name)) {
        try { $ev = ConvertFrom-JsonDict (Read-TextFile $f.FullName) } catch { Write-Log 'listener' "坏事件文件 $($f.Name)"; Remove-Item $f.FullName -Force; continue }
        Remove-Item $f.FullName -Force
        $s = Update-SessionInfo $ev
        switch ($ev.kind) {
            { $_ -in 'stop', 'notify' } {
                # Notification 只是兜底：已经在等选择/授权，或刚推过“已停下”时不再重复
                if ($ev.kind -eq 'notify' -and ((Test-OpenQuestion $ev.host_id) -or (Get-Dict $s 'status') -eq 'stop')) { Save-State; break }
                if (Test-Away) {
                    Confirm-Thread $s
                    $body = Get-Dict $ev 'body' ''
                    if ($ev.kind -eq 'notify' -and -not $body) { $body = '会话在等你输入' }
                    Send-Thread $s $body
                    Set-SessionStatus $s $ev.kind
                } else {
                    Set-SessionStatus $s $ev.kind
                }
            }
            # ask / perm 由 Update-Pending 从 pending 目录接手，这里只更新会话信息
        }
    }
}

# ---------- 选择题和授权 ----------

function Get-AskBlocks($P) {
    $req = $P.req; $id = $req.id
    $blocks = @()
    $qs = @($req.questions)
    for ($i = 0; $i -lt $qs.Count; $i++) {
        $q = $qs[$i]
        $multi = [bool](Get-Dict $q 'multiSelect' $false)
        $lines = @("*问题$($i + 1)：$($q.question)*$(if ($multi) { ' （可多选）' })")
        $opts = @($q.options)
        foreach ($o in $opts) { $d = Get-Dict $o 'description' ''; $lines += "• $($o.label)$(if ($d) { " —— $d" })" }
        $blocks += @{ type = 'section'; text = @{ type = 'mrkdwn'; text = ($lines -join "`n") } }
        if ($multi) {
            $boxes = @(); for ($j = 0; $j -lt $opts.Count; $j++) { $boxes += @{ text = @{ type = 'plain_text'; text = [string]$opts[$j].label }; value = [string]$j } }
            $el = @{ type = 'checkboxes'; action_id = "chk|$id|$i"; options = $boxes }
            # 重画消息时带回已勾选的项；block_id 固定，Slack 才不会当成新控件
            if ($P.checks.ContainsKey($i) -and @($P.checks[$i]).Count) { $el.initial_options = @(foreach ($j in @($P.checks[$i])) { $boxes[$j] }) }
            $blocks += @{ type = 'actions'; block_id = "chkb|$id|$i"; elements = @($el) }
        } else {
            $btns = @()
            for ($j = 0; $j -lt $opts.Count; $j++) {
                $label = [string]$opts[$j].label; if ($label.Length -gt 70) { $label = $label.Substring(0, 70) + '…' }
                $b = @{ type = 'button'; action_id = "sel|$id|$i|$j"; value = [string]$j; text = @{ type = 'plain_text'; text = $label } }
                if ($P.sel.ContainsKey($i) -and $P.sel[$i] -eq $j) { $b.style = 'primary' }
                $btns += $b
            }
            $blocks += @{ type = 'actions'; elements = $btns }
        }
        # 对应电脑弹窗里的 Other：自己写答案，回车即发送
        $field = @{ type = 'plain_text_input'; action_id = "txt|$id|$i"; placeholder = @{ type = 'plain_text'; text = '都不合适就直接写，回车发送' } }
        if ($P.custom.ContainsKey($i)) { $field.initial_value = [string]$P.custom[$i] }
        # 改点按钮后要清掉输入框：换一个 block_id 让 Slack 丢弃旧内容
        $rev = if ($P.rev.ContainsKey($i)) { $P.rev[$i] } else { 0 }
        $blocks += @{ type = 'input'; dispatch_action = $true; optional = $true; block_id = "txtb|$id|$i|$rev"
            label = @{ type = 'plain_text'; text = '其他' }; element = $field }
    }
    $single = ($qs.Count -eq 1 -and -not [bool](Get-Dict $qs[0] 'multiSelect' $false))
    if (-not $single) {
        $blocks += @{ type = 'actions'; elements = @(@{ type = 'button'; action_id = "sub|$id"; style = 'primary'; text = @{ type = 'plain_text'; text = '提交' } }) }
    }
    return $blocks
}

function Get-PermBlocks($P) {
    $req = $P.req
    return @(
        @{ type = 'section'; text = @{ type = 'mrkdwn'; text = "*工具*：$($req.tool)`n``````$($req.detail)``````" } },
        @{ type = 'actions'; elements = @(
                @{ type = 'button'; action_id = "perm|$($req.id)|allow"; style = 'primary'; text = @{ type = 'plain_text'; text = '允许' } },
                @{ type = 'button'; action_id = "perm|$($req.id)|deny"; style = 'danger'; text = @{ type = 'plain_text'; text = '拒绝' } }) }
    )
}

function Close-PendingMessage($P, [string]$Text) {
    if (-not $P.ts) { return }
    try { Invoke-SlackApi 'chat.update' @{ channel = $script:State.dm; ts = $P.ts; text = $Text; blocks = @(@{ type = 'section'; text = @{ type = 'mrkdwn'; text = $Text } }) } | Out-Null }
    catch { Write-Log 'listener' "关闭选择消息失败：$($_.Exception.Message)" }
}

function Test-ProcessAlive([int]$ProcessId) { return [bool](Get-Process -Id $ProcessId -ErrorAction SilentlyContinue) }

function Sync-PendingFiles {
    # 以 pending 目录为准：监听重启后，正在等的问题也能重新接上
    foreach ($f in @(Get-ChildItem $script:PendingDir -Filter '*.json' | Where-Object { $_.Name -notlike 'inject-*' })) {
        $id = $f.BaseName
        if ($script:Pending.ContainsKey($id) -or (Test-Path (Join-Path $script:PendingDir "$id.closed"))) { continue }
        try { $req = ConvertFrom-JsonDict (Read-TextFile $f.FullName) } catch { continue }
        $posted = Join-Path $script:PendingDir "$id.posted"
        $ts = if (Test-Path $posted) { (Read-TextFile $posted).Trim() } else { $null }
        $script:Pending[$id] = @{ req = $req; ts = $ts; sel = @{}; custom = @{}; checks = @{}; rev = @{}; host = (Get-Dict $req 'host_id') }
        Write-Log 'listener' "待答问题 $id（$(Get-Dict $req 'kind')）"
    }
}

function Update-Pending {
    Sync-PendingFiles
    foreach ($id in @($script:Pending.Keys)) {
        $p = $script:Pending[$id]
        $base = Join-Path $script:PendingDir $id
        $s = $script:State.sessions[$p.host]
        $closed = if (Test-Path "$base.closed") { Read-TextFile "$base.closed" } elseif (-not (Test-ProcessAlive ([int]$p.req.pid))) { 'gone' } else { $null }
        if ($closed) {
            switch ($closed) {
                'answered' { }   # 点击时已经写好“已选择 / 已拒绝”，不要覆盖
                'terminal' { Close-PendingMessage $p '已在电脑上处理'; if ($p.ts) { Set-SessionStatus $s 'handled' } }
                default { Close-PendingMessage $p '已超时，回到电脑上的弹窗处理' }
            }
            foreach ($suffix in @('json', 'answer', 'closed', 'posted')) { Remove-Item "$base.$suffix" -Force -ErrorAction SilentlyContinue }
            $script:Pending.Remove($id)
            continue
        }
        if (-not $p.ts -and (Test-Away)) {
            # 人不在电脑前才发到 Slack；在的话就在电脑上答
            Confirm-Thread $s
            $blocks = if ($p.req.kind -eq 'ask') { Get-AskBlocks $p } else { Get-PermBlocks $p }
            $r = Invoke-SlackApi 'chat.postMessage' @{ channel = $script:State.dm; thread_ts = $s.thread_ts; text = $StatusText[$p.req.kind]; blocks = $blocks }
            $p.ts = Get-Dict $r 'ts'
            Write-TextFileAtomic "$base.posted" $p.ts
            Write-Log 'listener' "已发选择消息 $id"
            Set-SessionStatus $s $p.req.kind
        }
    }
}

function Write-Answer([string]$Id, $Answer) {
    Write-TextFileAtomic (Join-Path $script:PendingDir "$Id.answer") (ConvertTo-JsonText $Answer)
}

function Invoke-BlockAction($Payload) {
    if ((Get-Dict (Get-Dict $Payload 'user') 'id') -ne $Owner) { return }
    $action = @(Get-Dict $Payload 'actions' @())[0]
    $parts = ([string](Get-Dict $action 'action_id' '')).Split('|')
    $id = $parts[1]
    if (-not $script:Pending.ContainsKey($id)) {
        $msg = Get-Dict $Payload 'message'
        Close-PendingMessage @{ ts = (Get-Dict $msg 'ts') } '该请求已结束，操作不再生效'
        return
    }
    $p = $script:Pending[$id]
    $s = $script:State.sessions[$p.host]
    Save-FormState $p $Payload
    switch ($parts[0]) {
        'perm' {
            Write-Answer $id @{ behavior = $parts[2] }
            Close-PendingMessage $p "已$(if ($parts[2] -eq 'allow') { '允许' } else { '拒绝' })"
            Set-SessionStatus $s 'running'
        }
        'chk' { }   # 勾选状态已由 Save-FormState 记下
        'txt' {
            $i = [int]$parts[2]
            $val = ([string](Get-Dict $action 'value' '')).Trim()
            if ($val) { $p.custom[$i] = $val; $p.sel.Remove($i) } else { $p.custom.Remove($i) }
            if (@($p.req.questions).Count -eq 1) { Submit-Ask $p $Payload }
            else { Invoke-SlackApi 'chat.update' @{ channel = $script:State.dm; ts = $p.ts; text = '等你选择'; blocks = (Get-AskBlocks $p) } | Out-Null }
        }
        'sel' {
            $i = [int]$parts[2]
            $p.sel[$i] = [int]$parts[3]
            $p.custom.Remove($i)
            $p.rev[$i] = 1 + $(if ($p.rev.ContainsKey($i)) { $p.rev[$i] } else { 0 })
            if (@($p.req.questions).Count -eq 1) { Submit-Ask $p $Payload }
            else { Invoke-SlackApi 'chat.update' @{ channel = $script:State.dm; ts = $p.ts; text = '等你选择'; blocks = (Get-AskBlocks $p) } | Out-Null }
        }
        'sub' { Submit-Ask $p $Payload }
    }
}

function Save-FormState($P, $Payload) {
    # 把当前勾选和输入框内容记下来：重画消息和提交都用它
    $values = Get-Dict (Get-Dict $Payload 'state') 'values'
    if ($null -eq $values) { return }
    foreach ($blk in @($values.Values)) {
        foreach ($key in @($blk.Keys)) {
            $k = $key.Split('|')
            if ($k.Count -lt 3 -or $k[1] -ne $P.req.id) { continue }
            $el = $blk[$key]; $i = [int]$k[2]
            if ($k[0] -eq 'chk') {
                $P.checks[$i] = @(foreach ($o in @(Get-Dict $el 'selected_options' @())) { [int]$o.value })
            } elseif ($k[0] -eq 'txt') {
                $typed = ([string](Get-Dict $el 'value' '')).Trim()
                if ($typed) { $P.custom[$i] = $typed; $P.sel.Remove($i) } else { $P.custom.Remove($i) }
            }
        }
    }
}

function Submit-Ask($P, $Payload) {
    $qs = @($P.req.questions)
    $answers = @{}; $missing = @(); $summary = @()
    for ($i = 0; $i -lt $qs.Count; $i++) {
        $q = $qs[$i]; $opts = @($q.options)
        $answer = ''
        if ([bool](Get-Dict $q 'multiSelect' $false)) {
            $picked = @()
            if ($P.checks.ContainsKey($i)) { foreach ($j in @($P.checks[$i])) { $picked += [string]$opts[$j].label } }
            if ($P.custom.ContainsKey($i)) { $picked += $P.custom[$i] }
            $answer = $picked -join ', '
        } elseif ($P.custom.ContainsKey($i)) {
            $answer = $P.custom[$i]
        } elseif ($P.sel.ContainsKey($i)) {
            $answer = [string]$opts[$P.sel[$i]].label
        }
        if ($answer) { $answers[[string]$q.question] = $answer; $summary += "• $($q.question) → *$answer*" } else { $missing += $i + 1 }
    }

    if ($missing.Count) {
        Invoke-SlackApi 'chat.postMessage' @{ channel = $script:State.dm; thread_ts = $script:State.sessions[$P.host].thread_ts; text = "问题 $($missing -join '、') 还没选" } | Out-Null
        return
    }
    Write-Answer $P.req.id @{ answers = $answers }
    Close-PendingMessage $P "已选择`n$($summary -join "`n")"
    Set-SessionStatus $script:State.sessions[$P.host] 'running'
}

# ---------- 回复打回会话 ----------

function ConvertFrom-SlackText([string]$Text) {
    return $Text.Replace('&lt;', '<').Replace('&gt;', '>').Replace('&amp;', '&')
}

function Invoke-MessageEvent($Ev) {
    if ((Get-Dict $Ev 'type') -ne 'message' -or (Get-Dict $Ev 'subtype') -or (Get-Dict $Ev 'bot_id')) { return }
    if ((Get-Dict $Ev 'user') -ne $Owner -or (Get-Dict $Ev 'channel') -ne $script:State.dm) { return }
    $text = ConvertFrom-SlackText ([string](Get-Dict $Ev 'text' '')).Trim()
    $threadTs = Get-Dict $Ev 'thread_ts'
    if (-not $threadTs) {
        if ($text -eq '列表') { Send-SessionList } else {
            Invoke-SlackApi 'chat.postMessage' @{ channel = $script:State.dm; text = '回复请发在对应会话的 thread 里。在外面开新会话请去项目频道。发「列表」可以看所有在等你的会话。' } | Out-Null
        }
        return
    }
    $found = Get-SessionByThread $threadTs
    if (-not $found -or -not $text) { return }
    foreach ($p in $script:Pending.Values) {
        if ($p.host -eq $found.host -and $p.ts) {
            Invoke-SlackApi 'chat.postMessage' @{ channel = $script:State.dm; thread_ts = $threadTs; text = '这个会话正在等你点上面的按钮，处理完再回复。' } | Out-Null
            return
        }
    }
    Set-SlackReaction $script:State.dm $Ev.ts 'eyes'
    $script:InjectQueue.Enqueue(@{ host = $found.host; text = $text; ts = $Ev.ts; thread = $threadTs })
}

function Send-SessionList {
    $lines = @()
    foreach ($kv in $script:State.sessions.GetEnumerator()) {
        $s = $kv.Value
        $st = Get-Dict $s 'status'
        if ($st -notin 'stop', 'ask', 'perm', 'notify' -or -not (Get-Dict $s 'thread_ts')) { continue }
        $link = Get-Dict (Invoke-SlackApi 'chat.getPermalink' @{ channel = $script:State.dm; message_ts = $s.thread_ts }) 'permalink'
        $lines += "• <$link|$(Get-Project (Get-Dict $s 'cwd')) · $(Get-Dict $s 'title' '')>  $($StatusText[$st])"
    }
    $text = if ($lines.Count) { $lines -join "`n" } else { '没有在等你的会话' }
    Invoke-SlackApi 'chat.postMessage' @{ channel = $script:State.dm; text = $text } | Out-Null
}

function Complete-Reply($Item, [bool]$Ok, [string]$Reason) {
    Set-SlackReaction $script:State.dm $Item.ts 'eyes' -Remove
    if ($Ok) {
        Set-SlackReaction $script:State.dm $Item.ts 'white_check_mark'
        Set-SessionStatus $script:State.sessions[$Item.host] 'running'
    } else {
        Set-SlackReaction $script:State.dm $Item.ts 'warning'
        Invoke-SlackApi 'chat.postMessage' @{ channel = $script:State.dm; thread_ts = $Item.thread; text = "没送达：$Reason" } | Out-Null
    }
    Write-Log 'listener' "回复 $($Item.host) $(if ($Ok) { 'ok' } else { $Reason })：$($Item.text.Substring(0, [Math]::Min(60, $Item.text.Length)))"
}

function Update-Injection {
    # 打完字后等 transcript 出现这条消息
    foreach ($v in @($script:Verifying)) {
        $s = $script:State.sessions[$v.host]
        if (Test-UserMessageArrived (Get-Dict $s 'transcript') $v.text $v.since) {
            Complete-Reply $v $true ''
            $script:Verifying = @($script:Verifying | Where-Object { $_ -ne $v })
        } elseif ((Get-Date) -gt $v.deadline) {
            Complete-Reply $v $false "已打进输入框，但 $VerifySeconds 秒内没在会话记录里看到这条消息"
            $script:Verifying = @($script:Verifying | Where-Object { $_ -ne $v })
        }
    }
    # 正在打字的子进程
    if ($script:InjectJob) {
        $j = $script:InjectJob
        if (-not $j.proc.HasExited) { return }
        $result = if (Test-Path $j.result) { Read-TextFile $j.result } else { 'error:打字进程没有返回结果' }
        Remove-Item $j.textFile, $j.result -Force -ErrorAction SilentlyContinue
        $script:InjectJob = $null
        if ($result -eq 'ok') {
            $j.item.deadline = (Get-Date).AddSeconds($VerifySeconds)
            $script:Verifying += $j.item
        } else { Complete-Reply $j.item $false ($result -replace '^error:', '') }
        return
    }
    if ($script:InjectQueue.Count -eq 0) { return }
    # 有人在用电脑就先等，不和人抢键盘
    if ((Get-IdleSeconds) -lt $InjectIdle) { return }
    $item = $script:InjectQueue.Dequeue()
    $s = $script:State.sessions[$item.host]
    $tr = Get-Dict $s 'transcript'
    $item.since = if ($tr -and (Test-Path -LiteralPath $tr)) { (Get-Item -LiteralPath $tr).Length } else { 0 }
    $tag = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $textFile = Join-Path $script:PendingDir "inject-$tag.txt"
    $resultFile = Join-Path $script:PendingDir "inject-$tag.result"
    [System.IO.File]::WriteAllText($textFile, $item.text, $script:Utf8)
    # Start-Process 只按空格拼参数，路径要自己加引号
    $args_ = '-NoProfile -STA -ExecutionPolicy Bypass -File "{0}" -SessionId "{1}" -TextFile "{2}" -ResultFile "{3}"' -f `
        (Join-Path $PSScriptRoot 'lib\inject.ps1'), $item.host, $textFile, $resultFile
    $proc = Start-Process powershell -ArgumentList $args_ -WindowStyle Hidden -PassThru
    $script:InjectJob = @{ proc = $proc; item = $item; textFile = $textFile; result = $resultFile }
}

# ---------- Socket Mode 消息 ----------

function Invoke-SocketMessage([string]$Raw) {
    $m = ConvertFrom-JsonDict $Raw
    $type = Get-Dict $m 'type'
    $envId = Get-Dict $m 'envelope_id'
    if ($envId) { Send-SlackSocket @{ envelope_id = $envId } }   # 3 秒内必须确认
    switch ($type) {
        'hello' { Write-Log 'listener' 'Socket Mode 已连接' }
        'disconnect' { throw 'Slack 要求重连' }
        'events_api' {
            $payload = Get-Dict $m 'payload'
            $eid = Get-Dict $payload 'event_id'
            if ($eid) {
                if ($script:SeenEvents.Contains($eid)) { return }
                $script:SeenEvents.Add($eid); if ($script:SeenEvents.Count -gt 300) { $script:SeenEvents.RemoveAt(0) }
            }
            Invoke-MessageEvent (Get-Dict $payload 'event')
        }
        'interactive' {
            $payload = Get-Dict $m 'payload'
            if ((Get-Dict $payload 'type') -eq 'block_actions') { Invoke-BlockAction $payload }
        }
    }
}

# ---------- 主循环 ----------

$dm = Invoke-SlackApi 'conversations.open' @{ users = $Owner }
$script:State['dm'] = Get-Dict (Get-Dict $dm 'channel') 'id'
Save-State
Write-Log 'listener' '启动'

$backoff = 2
while ($true) {
    try {
        if (-not (Test-SlackSocketOpen)) { Connect-SlackSocket; $backoff = 2 }
        $raw = Receive-SlackSocket 500
        if ($raw) { Invoke-SocketMessage $raw }
        Invoke-SpoolEvents
        Update-Pending
        Update-Injection
    } catch {
        Write-Log 'listener' "出错：$($_.Exception.Message)"
        if (-not (Test-SlackSocketOpen) -or $_.Exception.Message -match '重连|关闭') {
            try { if ($script:Ws) { $script:Ws.Dispose() } } catch {}
            $script:Ws = $null
            Start-Sleep -Seconds $backoff
            $backoff = [Math]::Min($backoff * 2, 60)
        }
    }
}
