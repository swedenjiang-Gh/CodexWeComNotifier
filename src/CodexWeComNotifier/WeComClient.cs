using System;
using System.Collections.Generic;
using System.Net.Http;
using System.Text;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

namespace CodexWeComNotifier
{
    public sealed class WeComClient : IDisposable
    {
        private readonly HttpClient client;
        private readonly JavaScriptSerializer serializer = new JavaScriptSerializer();

        public WeComClient()
            : this(new HttpClientHandler())
        {
        }

        public WeComClient(HttpMessageHandler handler)
        {
            client = new HttpClient(handler, true)
            {
                Timeout = TimeSpan.FromSeconds(8)
            };
        }

        public async Task SendAsync(string webhook, string content)
        {
            Dictionary<string, object> payload = new Dictionary<string, object>
            {
                { "msgtype", "text" },
                { "text", new Dictionary<string, object> { { "content", content } } }
            };

            using (StringContent requestBody = new StringContent(serializer.Serialize(payload), Encoding.UTF8, "application/json"))
            using (HttpResponseMessage response = await client.PostAsync(webhook, requestBody).ConfigureAwait(false))
            {
                if (!response.IsSuccessStatusCode)
                {
                    throw new HttpRequestException("Enterprise WeChat returned HTTP " + (int)response.StatusCode + ".");
                }

                string responseText = await response.Content.ReadAsStringAsync().ConfigureAwait(false);
                Dictionary<string, object> result = serializer.DeserializeObject(responseText) as Dictionary<string, object>;
                object errorCode = null;
                if (result == null || !result.TryGetValue("errcode", out errorCode) || Convert.ToInt32(errorCode) != 0)
                {
                    string code = errorCode == null ? "missing" : Convert.ToString(errorCode);
                    throw new InvalidOperationException("Enterprise WeChat rejected the message with errcode " + code + ".");
                }
            }
        }

        public void Dispose()
        {
            client.Dispose();
        }
    }
}
