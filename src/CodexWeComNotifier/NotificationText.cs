using System;
using System.Collections.Generic;
using System.IO;
using System.Web.Script.Serialization;

namespace CodexWeComNotifier
{
    public static class NotificationText
    {
        public static string FromEventJson(string eventJson, DateTime localTime)
        {
            string workspace = GetWorkspace(eventJson);
            return "Codex 任务轮次已结束\n工作区：" + workspace +
                   "\n时间：" + localTime.ToString("yyyy-MM-dd HH:mm:ss");
        }

        private static string GetWorkspace(string eventJson)
        {
            if (string.IsNullOrWhiteSpace(eventJson))
            {
                return "未知工作区";
            }

            try
            {
                JavaScriptSerializer serializer = new JavaScriptSerializer();
                Dictionary<string, object> root = serializer.DeserializeObject(eventJson) as Dictionary<string, object>;
                object value;
                if (root == null || !root.TryGetValue("cwd", out value))
                {
                    return "未知工作区";
                }

                string cwd = value as string;
                if (string.IsNullOrWhiteSpace(cwd))
                {
                    return "未知工作区";
                }

                string trimmed = cwd.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
                string leaf = Path.GetFileName(trimmed);
                return string.IsNullOrWhiteSpace(leaf) ? cwd : leaf;
            }
            catch
            {
                return "未知工作区";
            }
        }
    }
}
