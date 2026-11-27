# 提交前检查：所有 .ps1 能被 PowerShell 解析，且保存为带 BOM 的 UTF-8（否则 PowerShell 5.1 会把中文读乱）。
# 本地和 CI 都跑它：powershell -NoProfile -ExecutionPolicy Bypass -File tools\check.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$failed = 0

foreach ($f in Get-ChildItem $root -Recurse -Filter '*.ps1' | Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' }) {
    $rel = $f.FullName.Substring($root.Length + 1)
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errors) | Out-Null
    foreach ($e in @($errors)) {
        Write-Output "$rel`:$($e.Extent.StartLineNumber): $($e.Message)"
        $failed++
    }
    $head = [IO.File]::ReadAllBytes($f.FullName) | Select-Object -First 3
    if (($head -join ',') -ne '239,187,191') {
        Write-Output "$rel`: 不是带 BOM 的 UTF-8"
        $failed++
    }
}

if ($failed) { Write-Output "检查失败：$failed 处"; exit 1 }
Write-Output '检查通过'
