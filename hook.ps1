# Claude Code hook 入口。只处理桌面应用里的会话，把事件写进 spool 交给监听程序，不直接调用 Slack。
#   stop          Stop hook：一轮结束
#   permission    PermissionRequest hook：选择题或授权，阻塞等 Slack 里的答案
#   notification  Notification hook：会话在等输入（兜底）
param([Parameter(Mandatory)] [ValidateSet('stop', 'permission', 'notification')] [string]$Mode)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\common.ps1')

$WaitSeconds = 540   # settings.json 里 PermissionRequest hook 的 timeout 要大于它

function Read-HookInput {
    $reader = New-Object System.IO.StreamReader ([Console]::OpenStandardInput(), $script:Utf8)
    return ConvertFrom-JsonDict $reader.ReadToEnd()
}

function Write-HookOutput($Value) {
    $bytes = $script:Utf8.GetBytes((ConvertTo-JsonText $Value))
    $out = [Console]::OpenStandardOutput()
    $out.Write($bytes, 0, $bytes.Length)
    $out.Flush()
}

function Get-BaseEvent($Hook) {
    $transcript = [string](Get-Dict $Hook 'transcript_path' '')
    return @{
        host_id    = $env:CLAUDE_CODE_HOST_SESSION_ID
        cli_id     = [string](Get-Dict $Hook 'session_id' '')
        cwd        = [string](Get-Dict $Hook 'cwd' '')
        transcript = $transcript
        title      = (Get-TranscriptInfo $transcript).title
        at         = (Get-Date).ToString('o')
    }
}

$TerminalStatuses = @('completed', 'failed', 'stopped', 'killed', 'cancelled')

function Invoke-Stop($Hook) {
    $ev = Get-BaseEvent $Hook
    $body = [string](Get-Dict $Hook 'last_assistant_message' '')
    if (-not $body.Trim()) { $body = (Get-TranscriptInfo $ev.transcript).text }
    $carryFile = Join-Path $script:CarryDir "$($ev.cli_id).json"
    $carry = @()
    if (Test-Path $carryFile) { $carry = @(ConvertFrom-JsonDict (Read-TextFile $carryFile)) }

    # 后台任务还没跑完：只是中间停顿，先把这段回复存起来，真正停下时一起发
    $running = @(@(Get-Dict $Hook 'background_tasks' @()) | Where-Object {
            -not ($_ -is [System.Collections.IDictionary] -and $TerminalStatuses -contains ([string](Get-Dict $_ 'status' '')).ToLower())
        })
    if ($running.Count -gt 0) {
        if ($body.Trim()) {
            $keep = @($carry | Select-Object -Last 9) + $body
            Write-TextFileAtomic $carryFile (ConvertTo-JsonText $keep)
        }
        return
    }
    $ev.kind = 'stop'
    $ev.body = ((@($carry) + $body) | Where-Object { $_ -and $_.Trim() }) -join "`n`n---`n`n"
    New-SpoolEvent $ev
    if (Test-Path $carryFile) { Remove-Item $carryFile -Force }
}

function Test-AnsweredInTerminal([string]$Transcript, [long]$Offset) {
    # 在电脑上先答了：transcript 会追加 tool_result
    if ($Offset -lt 0 -or -not (Test-Path -LiteralPath $Transcript)) { return $false }
    $len = (Get-Item -LiteralPath $Transcript).Length
    if ($len -le $Offset) { return $false }
    foreach ($line in (Get-TranscriptLines $Transcript ($len - $Offset + 1))) {
        if ($line.Contains('"tool_result"') -and $line.Contains('"type":"user"')) { return $true }
    }
    return $false
}

function Invoke-Permission($Hook) {
    $ev = Get-BaseEvent $Hook
    $tool = [string](Get-Dict $Hook 'tool_name' '')
    $toolInput = Get-Dict $Hook 'tool_input' @{}
    $id = [guid]::NewGuid().ToString('N')
    $req = @{ id = $id; pid = $PID; host_id = $ev.host_id; tool = $tool; created = $ev.at }
    if ($tool -eq 'AskUserQuestion') {
        $req.kind = 'ask'; $req.questions = @(Get-Dict $toolInput 'questions' @())
    } else {
        $req.kind = 'perm'
        $detail = Get-Dict $toolInput 'command'
        if (-not $detail) { $detail = Get-Dict $toolInput 'file_path' }
        if (-not $detail) { $detail = ConvertTo-JsonText $toolInput }
        $req.detail = ([string]$detail).Substring(0, [Math]::Min(800, ([string]$detail).Length))
    }
    $base = Join-Path $script:PendingDir $id
    Write-TextFileAtomic "$base.json" (ConvertTo-JsonText $req)
    $ev.kind = $req.kind; $ev.request_id = $id
    New-SpoolEvent $ev

    $offset = if ($ev.transcript -and (Test-Path -LiteralPath $ev.transcript)) { (Get-Item -LiteralPath $ev.transcript).Length } else { -1 }
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    $closed = 'timeout'
    $tick = 0
    while ((Get-Date) -lt $deadline) {
        if (Test-Path "$base.answer") {
            $answer = ConvertFrom-JsonDict (Read-TextFile "$base.answer")
            $closed = 'answered'
            if ($req.kind -eq 'ask') {
                $decision = @{ behavior = 'allow'; updatedInput = @{ questions = $req.questions; answers = (Get-Dict $answer 'answers') } }
            } else {
                $decision = @{ behavior = (Get-Dict $answer 'behavior') }
                if ($decision.behavior -eq 'deny') { $decision.message = '用户在 Slack 中拒绝了该操作' }
            }
            Write-HookOutput @{ hookSpecificOutput = @{ hookEventName = 'PermissionRequest'; decision = $decision } }
            break
        }
        $tick++
        if ($tick % 4 -eq 0 -and (Test-AnsweredInTerminal $ev.transcript $offset)) { $closed = 'terminal'; break }
        Start-Sleep -Milliseconds 500
    }
    # 不输出任何东西 = 回到桌面应用自己的弹窗
    Write-TextFileAtomic "$base.closed" $closed
}

function Invoke-Notification($Hook) {
    $ev = Get-BaseEvent $Hook
    $ev.kind = 'notify'
    $ev.body = [string](Get-Dict $Hook 'message' '')
    New-SpoolEvent $ev
}

try {
    # 只管桌面应用的会话；cc-connect、终端里的会话直接跳过
    if ($env:CLAUDE_CODE_ENTRYPOINT -ne 'claude-desktop' -or -not $env:CLAUDE_CODE_HOST_SESSION_ID) { exit 0 }
    $hook = Read-HookInput
    switch ($Mode) {
        'stop' { Invoke-Stop $hook }
        'permission' { Invoke-Permission $hook }
        'notification' { Invoke-Notification $hook }
    }
} catch {
    Write-Log 'hook' "$Mode 出错：$($_.Exception.Message)"
}
exit 0
