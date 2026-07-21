# Codex 企业微信通知

该项目构建一个每用户安装的 Windows MSI。安装时会打开独立配置窗口，测试并使用当前用户的 Windows DPAPI 加密保存企业微信群机器人 Webhook，然后将一个 Stop Hook 合并到当前用户的 Codex `hooks.json`。

## 构建

要求：

- .NET Framework 4.8 targeting pack
- .NET SDK
- WiX Toolset 4

运行：

```powershell
pwsh.exe -NoLogo -NoProfile -NonInteractive -File .\build.ps1
```

输出：

```text
dist\CodexWeComNotifier-x64.msi
```

当前版本没有代码签名，Windows 会显示“未知发布者”。

## 用户使用

1. 运行 MSI。
2. 在独立窗口中粘贴完整的企业微信群机器人 Webhook。
3. 点击“测试并保存”。
4. 在 Codex 设置的“钩子 / Hooks”中找到新 Hook 并设置信任。
5. 重启 Codex，在新任务中生效。

程序不常驻后台。每次任务结束时，Codex 静默启动程序的 `--hook` 模式；消息发送后程序立即退出。
