# Codex 企业微信通知

该项目构建一个每用户安装的 Windows MSI。安装时会打开独立配置窗口，测试并使用当前用户的 Windows DPAPI 加密保存企业微信群机器人 Webhook，然后将一个 Stop Hook 合并到当前用户的 Codex `hooks.json`。

安装包只提供企业微信通知，不包含 ntfy 或 token 统计功能，也不安装常驻程序。

## 用户环境

- Windows 10 或 Windows 11
- Windows 自带的 Windows PowerShell 5.1（`powershell.exe`）
- Codex
- 可访问企业微信机器人 Webhook 的网络

不需要 PowerShell 7、.NET Framework 4.8、.NET SDK、Node.js 或企业微信客户端。

## 构建

构建电脑要求：

- WiX Toolset 4

运行：

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive -File .\build.ps1
```

输出：

```text
dist\CodexWeComNotifier-x64.msi
```

当前版本没有代码签名，Windows 会显示“未知发布者”。

## 安装

### 使用 winget

winget 清单正在 [microsoft/winget-pkgs#405323](https://github.com/microsoft/winget-pkgs/pull/405323) 审核。PR 合并并同步到 winget 源后，可运行：

```powershell
winget source update
winget install SwedenJiang.CodexWeComNotifier --interactive
```

必须保留 `--interactive`，因为安装过程中需要填写并测试企业微信 Webhook。

### 下载安装包

在 winget 清单正式上线前，可从 [GitHub Releases](https://github.com/swedenjiang-Gh/CodexWeComNotifier/releases/latest) 下载 `CodexWeComNotifier-x64.msi` 并运行。

## 配置步骤

1. 在安装时打开的独立窗口中粘贴完整的企业微信群机器人 Webhook。
2. 点击“测试并保存”。
3. 在 Codex 设置的“钩子 / Hooks”中找到新 Hook 并设置信任。
4. 重启 Codex，在新任务中生效。

安装后，以下两个脚本位于当前用户的 `%USERPROFILE%\.codex\hooks`：

- `configure-wecom.ps1`：配置或更新 Webhook。
- `notify-wecom.ps1`：Codex 任务结束时发送企业微信通知。

Webhook 只会在目标电脑上生成 `%USERPROFILE%\.codex\hooks\wecom-webhook.dpapi`，不会进入源码或安装包。Codex 每次任务结束时临时运行 `notify-wecom.ps1`，发送完成后脚本立即退出。
