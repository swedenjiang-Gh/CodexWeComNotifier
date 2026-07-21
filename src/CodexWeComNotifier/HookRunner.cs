using System;
using System.IO;
using System.Text;

namespace CodexWeComNotifier
{
    public sealed class HookRunner
    {
        private readonly SecretStore secretStore;
        private readonly WeComClient client;
        private readonly string statusPath;
        private readonly Func<DateTime> clock;

        public HookRunner(SecretStore secretStore, WeComClient client, string statusPath, Func<DateTime> clock)
        {
            this.secretStore = secretStore;
            this.client = client;
            this.statusPath = statusPath;
            this.clock = clock;
        }

        public int Run(TextReader input)
        {
            DateTime now = clock();
            string state = "ERROR";
            string errorType = null;
            try
            {
                string eventJson = input.ReadToEnd();
                string body = NotificationText.FromEventJson(eventJson, now);
                string webhook = secretStore.Load();
                client.SendAsync(webhook, body).GetAwaiter().GetResult();
                state = "OK";
            }
            catch (Exception exception)
            {
                errorType = exception.GetType().Name;
            }

            try
            {
                string directory = Path.GetDirectoryName(statusPath);
                if (!string.IsNullOrEmpty(directory))
                {
                    Directory.CreateDirectory(directory);
                }
                string line = now.ToString("yyyy-MM-dd HH:mm:ss") + " WECOM=" + state;
                if (errorType != null)
                {
                    line += " type=" + errorType;
                }
                File.WriteAllText(statusPath, line, new UTF8Encoding(false));
            }
            catch
            {
            }

            return 0;
        }
    }
}
