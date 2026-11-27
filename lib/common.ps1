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

function ConvertTo-JsonText($Value) {
    return $script:Json.Serialize($Value)
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
