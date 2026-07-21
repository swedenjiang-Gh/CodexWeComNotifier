using System;
using System.Drawing;
using System.IO;
using System.Windows.Forms;

namespace CodexWeComNotifier
{
    public sealed class ConfigureForm : Form
    {
        private readonly SecretStore secretStore;
        private readonly HookConfigManager hookConfigManager;
        private readonly string executablePath;
        private readonly TextBox webhookTextBox;
        private readonly Button saveButton;
        private readonly Label statusLabel;

        public ConfigureForm(SecretStore secretStore, HookConfigManager hookConfigManager, string executablePath)
        {
            this.secretStore = secretStore;
            this.hookConfigManager = hookConfigManager;
            this.executablePath = executablePath;

            Text = "Codex 企业微信通知配置";
            ClientSize = new Size(680, 310);
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            MinimizeBox = false;
            StartPosition = FormStartPosition.CenterScreen;
            Font = new Font("Microsoft YaHei UI", 9F);

            Label stepsLabel = new Label
            {
                AutoSize = false,
                Location = new Point(24, 20),
                Size = new Size(632, 60),
                Text = UserMessages.WebhookSteps
            };

            Label inputLabel = new Label
            {
                AutoSize = true,
                Location = new Point(24, 92),
                Text = "企业微信 Webhook 地址："
            };

            webhookTextBox = new TextBox
            {
                Location = new Point(24, 118),
                Size = new Size(632, 27),
                UseSystemPasswordChar = true
            };

            CheckBox showAddress = new CheckBox
            {
                AutoSize = true,
                Location = new Point(24, 155),
                Text = "显示地址"
            };
            showAddress.CheckedChanged += delegate
            {
                webhookTextBox.UseSystemPasswordChar = !showAddress.Checked;
            };

            statusLabel = new Label
            {
                AutoSize = false,
                Location = new Point(24, 187),
                Size = new Size(480, 50),
                ForeColor = Color.DimGray,
                Text = secretStore.Exists ? "已存在配置。粘贴新地址可重新配置。" : "请粘贴完整 Webhook 地址。"
            };

            saveButton = new Button
            {
                Location = new Point(516, 184),
                Size = new Size(140, 38),
                Text = "测试并保存",
                UseVisualStyleBackColor = true
            };
            saveButton.Click += SaveButtonClick;

            Label privacyLabel = new Label
            {
                AutoSize = false,
                Location = new Point(24, 248),
                Size = new Size(632, 42),
                ForeColor = Color.DimGray,
                Text = "Webhook 只会在本机使用 Windows DPAPI 加密保存，不会写入安装包或日志。"
            };

            Controls.Add(stepsLabel);
            Controls.Add(inputLabel);
            Controls.Add(webhookTextBox);
            Controls.Add(showAddress);
            Controls.Add(statusLabel);
            Controls.Add(saveButton);
            Controls.Add(privacyLabel);
            AcceptButton = saveButton;
        }

        private async void SaveButtonClick(object sender, EventArgs e)
        {
            string webhook = webhookTextBox.Text.Trim();
            if (!WebhookValidator.IsValid(webhook))
            {
                statusLabel.ForeColor = Color.Firebrick;
                statusLabel.Text = "地址格式不正确，请粘贴完整的企业微信群机器人 Webhook。";
                return;
            }

            saveButton.Enabled = false;
            webhookTextBox.Enabled = false;
            statusLabel.ForeColor = Color.DimGray;
            statusLabel.Text = "正在发送测试消息……";

            try
            {
                using (WeComClient client = new WeComClient())
                {
                    string message = "Codex 企业微信通知配置成功\n时间：" + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss");
                    await client.SendAsync(webhook, message);
                }

                secretStore.Save(webhook);
                hookConfigManager.EnsureHook(executablePath);
                statusLabel.ForeColor = Color.DarkGreen;
                statusLabel.Text = "配置成功。";
                MessageBox.Show(
                    UserMessages.HookTrust + "\n\n请重启 Codex，使新 Hook 在新任务中生效。",
                    "配置成功",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Information);
                DialogResult = DialogResult.OK;
                Close();
            }
            catch
            {
                statusLabel.ForeColor = Color.Firebrick;
                statusLabel.Text = "配置失败。请检查网络、Webhook 是否有效以及 Codex 配置文件权限。";
                saveButton.Enabled = true;
                webhookTextBox.Enabled = true;
            }
        }
    }
}
