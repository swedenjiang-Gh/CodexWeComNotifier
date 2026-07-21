using System.IO;
using System.Security.Cryptography;
using System.Text;

namespace CodexWeComNotifier
{
    public sealed class SecretStore
    {
        private readonly string path;

        public SecretStore(string path)
        {
            this.path = path;
        }

        public bool Exists
        {
            get { return File.Exists(path); }
        }

        public void Save(string webhook)
        {
            string directory = Path.GetDirectoryName(path);
            if (!string.IsNullOrEmpty(directory))
            {
                Directory.CreateDirectory(directory);
            }

            byte[] plaintext = Encoding.UTF8.GetBytes(webhook);
            byte[] encrypted = ProtectedData.Protect(plaintext, null, DataProtectionScope.CurrentUser);
            File.WriteAllBytes(path, encrypted);
        }

        public string Load()
        {
            byte[] encrypted = File.ReadAllBytes(path);
            byte[] plaintext = ProtectedData.Unprotect(encrypted, null, DataProtectionScope.CurrentUser);
            return Encoding.UTF8.GetString(plaintext);
        }

        public void Delete()
        {
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }
    }
}
