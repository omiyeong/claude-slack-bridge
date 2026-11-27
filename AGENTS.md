# 协作约定

- 只用 Windows PowerShell 5.1 和 .NET Framework 自带的东西，不引入外部依赖。
- `.ps1` 文件保存为带 BOM 的 UTF-8，否则 PowerShell 5.1 会把中文读乱。
- hook 只写 spool，不调用 Slack；Slack、状态文件、打字都只在 `listener.ps1` 一个进程里做。
- JSON 用 `ConvertFrom-JsonDict` / `ConvertTo-JsonText`（JavaScriptSerializer），不用 `ConvertFrom-Json`；字典取值用 `Get-Dict`。
- 不要用 `$input`、`$host`、`$args` 这类 PowerShell 自动变量名。
- 要存进字典或列表的值不要用 `$( )` 包：它会把单元素数组拆成标量。序列化统一走 `ConvertTo-JsonText`，它会拆掉 PowerShell 的 PSObject 包装（`-is [psobject]` 对任何对象都为真，不能用来判断）。
- Slack 的读取类方法（`chat.getPermalink`、`conversations.*`）不接受 JSON 请求体，加进 `lib\slack.ps1` 的 `$FormMethods`。
- 提交前检查：所有 `.ps1` 能被 `[Management.Automation.Language.Parser]::ParseFile` 解析且没有错误。
- 测试打字时用临时测试会话，不用正在干活的会话。token、`.env`、运行数据不进仓库。
