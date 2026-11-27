# 安全

这个工具能把 Slack 里的文字打进你电脑上的 Claude 会话，而 Claude 会话能执行命令。所以 **能在 Slack 里控制它的人，等于能在你电脑上执行命令**。请按下面的方式使用。

## 已有的防护

- 只处理 `.env` 里 `OWNER_USER_ID` 这一个人发的消息和点的按钮，其他人的一律忽略。
- 只处理 bot 和你之间私信里的消息，频道里的不管。
- 用 Socket Mode 连接，电脑不对外开端口。
- 往会话打字前确认你没在用键鼠、会话没有开着的弹窗。

## 你需要注意

- **保管好 token**：`SLACK_BOT_TOKEN` 和 `SLACK_APP_TOKEN` 只放在 `%USERPROFILE%\.claude-slack-bridge\.env`，不要提交、不要发给别人。泄露了就到 Slack 应用后台重新生成。
- **Slack 账号本身**：开两步验证。手机丢了，先在 Slack 里登出那台设备，或停掉计划任务 `claude-slack-bridge`。
- **运行数据**：`%USERPROFILE%\.claude-slack-bridge\` 下的状态和日志含有会话标题和回复片段。
- **授权按钮**：Slack 里点“允许”和在电脑上点效果一样，看清命令再点。

## 报告漏洞

请不要开公开 issue。用 GitHub 的 [Private vulnerability reporting](https://github.com/omiyeong/claude-slack-bridge/security/advisories/new) 私下报告，写清复现步骤和影响。
