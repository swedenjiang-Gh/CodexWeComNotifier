using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Web.Script.Serialization;

namespace CodexWeComNotifier
{
    public sealed class HookConfigManager
    {
        private readonly string path;
        private readonly JavaScriptSerializer serializer = new JavaScriptSerializer();

        public HookConfigManager(string path)
        {
            this.path = path;
        }

        public void EnsureHook(string executablePath)
        {
            Dictionary<string, object> root = LoadRoot();
            Dictionary<string, object> hooks = GetOrCreateDictionary(root, "hooks");
            List<object> stop = GetOrCreateList(hooks, "Stop");
            string command = BuildCommand(executablePath);

            if (!ContainsCommand(stop, command))
            {
                Dictionary<string, object> innerHook = new Dictionary<string, object>
                {
                    { "type", "command" },
                    { "command", command },
                    { "timeout", 15 },
                    { "statusMessage", "Sending enterprise WeChat notification" }
                };
                Dictionary<string, object> group = new Dictionary<string, object>
                {
                    { "hooks", new List<object> { innerHook } }
                };
                stop.Add(group);
            }

            SaveRoot(root);
        }

        public void RemoveHook(string executablePath)
        {
            if (!File.Exists(path))
            {
                return;
            }

            Dictionary<string, object> root = LoadRoot();
            Dictionary<string, object> hooks;
            if (!TryGetDictionary(root, "hooks", out hooks))
            {
                return;
            }

            List<object> stop;
            if (!TryGetList(hooks, "Stop", out stop))
            {
                return;
            }

            string command = BuildCommand(executablePath);
            for (int groupIndex = stop.Count - 1; groupIndex >= 0; groupIndex--)
            {
                Dictionary<string, object> group = stop[groupIndex] as Dictionary<string, object>;
                List<object> inner;
                if (group == null || !TryGetList(group, "hooks", out inner))
                {
                    continue;
                }

                for (int hookIndex = inner.Count - 1; hookIndex >= 0; hookIndex--)
                {
                    Dictionary<string, object> hook = inner[hookIndex] as Dictionary<string, object>;
                    object value;
                    if (hook != null && hook.TryGetValue("command", out value) &&
                        string.Equals(value as string, command, StringComparison.OrdinalIgnoreCase))
                    {
                        inner.RemoveAt(hookIndex);
                    }
                }

                if (inner.Count == 0)
                {
                    stop.RemoveAt(groupIndex);
                }
            }

            if (stop.Count == 0)
            {
                hooks.Remove("Stop");
            }

            SaveRoot(root);
        }

        public static string BuildCommand(string executablePath)
        {
            return "\"" + executablePath + "\" --hook";
        }

        private Dictionary<string, object> LoadRoot()
        {
            if (!File.Exists(path))
            {
                return new Dictionary<string, object>();
            }

            string json = File.ReadAllText(path, Encoding.UTF8);
            if (string.IsNullOrWhiteSpace(json))
            {
                return new Dictionary<string, object>();
            }

            Dictionary<string, object> root = serializer.DeserializeObject(json) as Dictionary<string, object>;
            if (root == null)
            {
                throw new InvalidDataException("hooks.json root must be an object.");
            }
            return root;
        }

        private void SaveRoot(Dictionary<string, object> root)
        {
            string directory = Path.GetDirectoryName(path);
            if (!string.IsNullOrEmpty(directory))
            {
                Directory.CreateDirectory(directory);
            }

            string temporary = path + ".tmp-" + Guid.NewGuid().ToString("N");
            try
            {
                File.WriteAllText(temporary, serializer.Serialize(root), new UTF8Encoding(false));
                if (File.Exists(path))
                {
                    File.Replace(temporary, path, null, true);
                }
                else
                {
                    File.Move(temporary, path);
                }
            }
            finally
            {
                if (File.Exists(temporary))
                {
                    File.Delete(temporary);
                }
            }
        }

        private static bool ContainsCommand(List<object> groups, string command)
        {
            foreach (object groupValue in groups)
            {
                Dictionary<string, object> group = groupValue as Dictionary<string, object>;
                List<object> inner;
                if (group == null || !TryGetList(group, "hooks", out inner))
                {
                    continue;
                }

                foreach (object hookValue in inner)
                {
                    Dictionary<string, object> hook = hookValue as Dictionary<string, object>;
                    object value;
                    if (hook != null && hook.TryGetValue("command", out value) &&
                        string.Equals(value as string, command, StringComparison.OrdinalIgnoreCase))
                    {
                        return true;
                    }
                }
            }
            return false;
        }

        private static Dictionary<string, object> GetOrCreateDictionary(Dictionary<string, object> parent, string key)
        {
            Dictionary<string, object> value;
            if (TryGetDictionary(parent, key, out value))
            {
                return value;
            }
            value = new Dictionary<string, object>();
            parent[key] = value;
            return value;
        }

        private static List<object> GetOrCreateList(Dictionary<string, object> parent, string key)
        {
            List<object> value;
            if (TryGetList(parent, key, out value))
            {
                parent[key] = value;
                return value;
            }
            value = new List<object>();
            parent[key] = value;
            return value;
        }

        private static bool TryGetDictionary(Dictionary<string, object> parent, string key, out Dictionary<string, object> value)
        {
            object raw;
            if (parent.TryGetValue(key, out raw))
            {
                value = raw as Dictionary<string, object>;
                if (value != null)
                {
                    return true;
                }
            }
            value = null;
            return false;
        }

        private static bool TryGetList(Dictionary<string, object> parent, string key, out List<object> value)
        {
            object raw;
            if (!parent.TryGetValue(key, out raw))
            {
                value = null;
                return false;
            }

            value = raw as List<object>;
            if (value != null)
            {
                return true;
            }

            object[] array = raw as object[];
            if (array != null)
            {
                value = new List<object>(array);
                parent[key] = value;
                return true;
            }

            value = null;
            return false;
        }
    }
}
