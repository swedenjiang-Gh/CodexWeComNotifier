using System;

namespace CodexWeComNotifier
{
    public static class WebhookValidator
    {
        public static bool IsValid(string value)
        {
            Uri uri;
            if (string.IsNullOrWhiteSpace(value) ||
                !Uri.TryCreate(value.Trim(), UriKind.Absolute, out uri))
            {
                return false;
            }

            if (!string.Equals(uri.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase) ||
                !string.Equals(uri.Host, "qyapi.weixin.qq.com", StringComparison.OrdinalIgnoreCase) ||
                !string.Equals(uri.AbsolutePath, "/cgi-bin/webhook/send", StringComparison.Ordinal) ||
                (!uri.IsDefaultPort && uri.Port != 443) ||
                !string.IsNullOrEmpty(uri.Fragment))
            {
                return false;
            }

            string query = uri.Query.TrimStart('?');
            foreach (string part in query.Split(new[] { '&' }, StringSplitOptions.RemoveEmptyEntries))
            {
                string[] pair = part.Split(new[] { '=' }, 2);
                if (pair.Length == 2 &&
                    string.Equals(pair[0], "key", StringComparison.Ordinal) &&
                    !string.IsNullOrWhiteSpace(Uri.UnescapeDataString(pair[1])))
                {
                    return true;
                }
            }

            return false;
        }
    }
}
