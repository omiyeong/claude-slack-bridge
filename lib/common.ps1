# 公共工具：路径、JSON、配置、日志、空闲时间、transcript 读取
Set-StrictMode -Version 2
Add-Type -AssemblyName System.Web.Extensions

$script:Utf8 = New-Object System.Text.UTF8Encoding $false
$script:DataDir = Join-Path $env:USERPROFILE '.claude-slack-bridge'
$script:SpoolDir = Join-Path $DataDir 'spool'
$script:PendingDir = Join-Path $DataDir 'pending'
$script:CarryDir = Join-Path $DataDir 'carry'
$script:LogDir = Join-Path $DataDir 'logs'
$script:StateFile = Join-Path $DataDir 'state.json'
foreach ($d in @($DataDir, $SpoolDir, $PendingDir, $CarryDir, $LogDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d | Out-Null }
}

$script:Json = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$script:Json.MaxJsonLength = [int]::MaxValue

function ConvertFrom-JsonDict([string]$Text) {
    # 返回可修改的 Dictionary / object[]，比 ConvertFrom-Json 的 PSCustomObject 好改
    return $script:Json.DeserializeObject($Text)
}

function ConvertTo-PlainValue($Value) {
    # PowerShell 会把函数返回值包成 PSObject，JavaScriptSerializer 序列化它会报循环引用，先拆包
    # 注意：`-is [psobject]` 对任何对象都为真，不能用来判断；一律取 .PSObject.BaseObject
    if ($null -eq $Value) { return $null }
    $Value = $Value.PSObject.BaseObject
    if ($Value -is [string] -or $Value -is [ValueType]) { return $Value }
    if ($Value -is [System.Collections.IDictionary]) {
        $d = New-Object 'System.Collections.Generic.Dictionary[string,object]'
        foreach ($k in @($Value.Keys)) {
            $v = ConvertTo-PlainValue $Value[$k]
            # 函数返回值存进 object 槽时会被重新包一层，存之前再拆一次
            $raw = $null; if ($null -ne $v) { $raw = $v.PSObject.BaseObject }
            # 不要用 $( ) 包，它会把单元素数组拆成标量
            $d.Add([string]$k, $raw)
        }
        return , $d
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $list = New-Object 'System.Collections.Generic.List[object]'
        foreach ($item in $Value) {
            $v = ConvertTo-PlainValue $item
            $raw = $null; if ($null -ne $v) { $raw = $v.PSObject.BaseObject }
            $list.Add($raw)
        }
        return , $list.ToArray()
    }
    return $Value
}

function ConvertTo-JsonText($Value) {
    return $script:Json.Serialize((ConvertTo-PlainValue $Value))
}

function Read-TextFile([string]$Path) {
    return [System.IO.File]::ReadAllText($Path, $script:Utf8)
}

function Write-TextFileAtomic([string]$Path, [string]$Text) {
    # 先写临时文件再改名，读的一方不会读到写了一半的文件
    $tmp = "$Path.$PID.tmp"
    [System.IO.File]::WriteAllText($tmp, $Text, $script:Utf8)
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Get-Dict($Dict, [string]$Key, $Default = $null) {
    if ($null -ne $Dict -and $Dict -is [System.Collections.IDictionary] -and $Dict.ContainsKey($Key)) {
        return $Dict[$Key]
    }
    return $Default
}

function Write-Log([string]$Name, [string]$Message) {
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    [System.IO.File]::AppendAllText((Join-Path $script:LogDir "$Name.log"), "$line`r`n", $script:Utf8)
}

function Read-BridgeEnv {
    $path = Join-Path $script:DataDir '.env'
    if (-not (Test-Path $path)) { throw ".env 不存在：$path" }
    $cfg = @{ AWAY_AFTER_SECONDS = '300'; INJECT_IDLE_SECONDS = '30' }
    foreach ($line in [System.IO.File]::ReadAllLines($path, $script:Utf8)) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith('#') -or -not $t.Contains('=')) { continue }
        $i = $t.IndexOf('=')
        $cfg[$t.Substring(0, $i).Trim()] = $t.Substring($i + 1).Trim()
    }
    # 测试用：环境变量 BRIDGE_AWAY_AFTER_SECONDS 等可临时覆盖 .env 里的阈值
    foreach ($k in @('AWAY_AFTER_SECONDS', 'INJECT_IDLE_SECONDS')) {
        $override = [Environment]::GetEnvironmentVariable("BRIDGE_$k")
        if ($override) { $cfg[$k] = $override }
    }
    foreach ($k in @('SLACK_BOT_TOKEN', 'SLACK_APP_TOKEN', 'OWNER_USER_ID')) {
        if (-not $cfg[$k]) { throw ".env 缺少 $k" }
    }
    return $cfg
}

if (-not ('BridgeIdle' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class BridgeIdle {
    [StructLayout(LayoutKind.Sequential)]
    struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
    public static double Seconds() {
        LASTINPUTINFO info = new LASTINPUTINFO();
        info.cbSize = (uint)Marshal.SizeOf(info);
        if (!GetLastInputInfo(ref info)) return 0;
        return unchecked((uint)Environment.TickCount - info.dwTime) / 1000.0;
    }
}
'@
}

function Get-IdleSeconds { return [BridgeIdle]::Seconds() }

function Get-TranscriptLines([string]$Path, [int]$TailBytes = 2000000) {
    # 只读文件尾部，长会话的 transcript 可能有几十 MB
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return @() }
    $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    try {
        $start = [Math]::Max(0, $fs.Length - $TailBytes)
        $fs.Seek($start, 'Begin') | Out-Null
        $buf = New-Object byte[] ($fs.Length - $start)
        [void]$fs.Read($buf, 0, $buf.Length)
    } finally { $fs.Dispose() }
    $lines = $script:Utf8.GetString($buf) -split "`n"
    # 从中间开始读时第一行不完整，丢掉
    if ($start -gt 0) { $lines = @($lines | Select-Object -Skip 1) }
    return $lines
}

function Get-MessageText($Entry) {
    # transcript 一行里 message.content 可能是字符串，也可能是块数组
    $msg = Get-Dict $Entry 'message'
    $content = Get-Dict $msg 'content'
    if ($content -is [string]) { return $content }
    $parts = @()
    foreach ($b in @($content)) {
        if ((Get-Dict $b 'type') -eq 'text') { $parts += [string](Get-Dict $b 'text' '') }
    }
    return ($parts -join "`n")
}

function Get-TranscriptInfo([string]$Path) {
    # 最后一段 assistant 文本和会话标题（/rename 的名字优先，其次自动标题）
    $text = ''; $custom = ''; $auto = ''
    foreach ($line in (Get-TranscriptLines $Path)) {
        if (-not $line.StartsWith('{')) { continue }
        if ($line.Contains('"custom-title"') -or $line.Contains('"ai-title"') -or $line.Contains('"type":"assistant"')) {
            try { $d = ConvertFrom-JsonDict $line } catch { continue }
            switch (Get-Dict $d 'type') {
                'custom-title' { $custom = [string](Get-Dict $d 'customTitle' '') }
                'ai-title' { $auto = [string](Get-Dict $d 'aiTitle' '') }
                'assistant' { $t = Get-MessageText $d; if ($t.Trim()) { $text = $t } }
            }
        }
    }
    $title = if ($custom) { $custom } elseif ($auto) { $auto } else { '' }
    return @{ text = $text; title = $title }
}

function Get-RecentMessages([string]$Path, [int]$Count) {
    # 最近几条对话：用户消息各算一条，一轮里 Claude 被工具调用隔开的几段文字合成一条
    $msgs = New-Object 'System.Collections.Generic.List[object]'
    foreach ($line in (Get-TranscriptLines $Path)) {
        if (-not $line.StartsWith('{') -or -not ($line.Contains('"type":"user"') -or $line.Contains('"type":"assistant"'))) { continue }
        try { $d = ConvertFrom-JsonDict $line } catch { continue }
        $role = Get-Dict $d 'type'
        if ($role -notin 'user', 'assistant' -or (Get-Dict $d 'isMeta' $false) -or (Get-Dict $d 'isSidechain' $false)) { continue }
        # 工具结果没有文字；命令输出、系统提醒这类用户侧记录不是你写的
        $text = (Get-MessageText $d).Trim()
        if (-not $text -or ($role -eq 'user' -and $text -match '^(<(command-|local-command|system-reminder|task-notification|bash-)|/slack\s*$)')) { continue }
        $last = if ($msgs.Count) { $msgs[$msgs.Count - 1] } else { $null }
        if ($last -and $role -eq 'assistant' -and $last.role -eq 'assistant') { $last.text = "$($last.text)`n`n$text" }
        else { $msgs.Add(@{ role = $role; text = $text }) }
    }
    return @($msgs | Select-Object -Last $Count)
}

function Test-UserMessageArrived([string]$Path, [string]$Needle, [long]$SinceBytes) {
    # 打字后确认：transcript 在 SinceBytes 之后出现了一条包含回复原文的用户消息
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $len = (Get-Item -LiteralPath $Path).Length
    if ($len -le $SinceBytes) { return $false }
    $needle = $Needle.Trim()
    # 多读 1 个字节，让被丢掉的“不完整首行”正好是上一行末尾的换行
    foreach ($line in (Get-TranscriptLines $Path ($len - $SinceBytes + 1))) {
        if (-not $line.Contains('"type":"user"')) { continue }
        try { $d = ConvertFrom-JsonDict $line } catch { continue }
        if ((Get-Dict $d 'type') -eq 'user' -and (Get-MessageText $d).Contains($needle)) { return $true }
    }
    return $false
}

function New-SpoolEvent([hashtable]$Event) {
    $name = '{0:yyyyMMddHHmmssfff}-{1}.json' -f (Get-Date), [guid]::NewGuid().ToString('N').Substring(0, 8)
    Write-TextFileAtomic (Join-Path $script:SpoolDir $name) (ConvertTo-JsonText $Event)
}
