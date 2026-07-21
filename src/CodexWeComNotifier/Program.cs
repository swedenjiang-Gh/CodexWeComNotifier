using System;
using System.IO;
using System.Linq;
using System.Net;
using System.Windows.Forms;

namespace CodexWeComNotifier
{
    internal static class Program
    {
        [STAThread]
        private static int Main(string[] args)
        {
            ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
            string dataDirectory = AppPaths.GetDataDirectory();
            string secretPath = Path.Combine(dataDirectory, "webhook.dat");
            string statusPath = Path.Combine(dataDirectory, "notify-status.log");
            string hooksPath = Path.Combine(AppPaths.GetCodexHome(), "hooks.json");
            SecretStore secretStore = new SecretStore(secretPath);
            HookConfigManager hookConfigManager = new HookConfigManager(hooksPath);

            if (args.Any(value => string.Equals(value, "--hook", StringComparison.OrdinalIgnoreCase)))
            {
                using (WeComClient client = new WeComClient())
                {
                    HookRunner runner = new HookRunner(secretStore, client, statusPath, () => DateTime.Now);
                    return runner.Run(Console.In);
                }
            }

            if (args.Any(value => string.Equals(value, "--uninstall", StringComparison.OrdinalIgnoreCase)))
            {
                return Uninstall(hookConfigManager, secretStore, statusPath, dataDirectory);
            }

            bool installerMode = args.Any(value => string.Equals(value, "--installer", StringComparison.OrdinalIgnoreCase));
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            using (ConfigureForm form = new ConfigureForm(secretStore, hookConfigManager, Application.ExecutablePath))
            {
                DialogResult result = form.ShowDialog();
                return installerMode && result != DialogResult.OK ? 1 : 0;
            }
        }

        private static int Uninstall(HookConfigManager hookConfigManager, SecretStore secretStore, string statusPath, string dataDirectory)
        {
            try
            {
                hookConfigManager.RemoveHook(Application.ExecutablePath);
            }
            catch
            {
            }

            try
            {
                secretStore.Delete();
                if (File.Exists(statusPath))
                {
                    File.Delete(statusPath);
                }
                if (Directory.Exists(dataDirectory) && Directory.GetFileSystemEntries(dataDirectory).Length == 0)
                {
                    Directory.Delete(dataDirectory, false);
                }
            }
            catch
            {
            }

            return 0;
        }
    }
}
