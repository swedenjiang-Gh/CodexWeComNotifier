using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using CodexWeComNotifier;

internal static class Program
{
    private static int failures;

    private static int Main()
    {
        Run("Webhook accepts enterprise WeChat HTTPS URL", () =>
            Assert(WebhookValidator.IsValid("https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=test-key"), "valid URL rejected"));
        Run("Webhook rejects unsafe and incomplete URLs", TestInvalidWebhooks);
        Run("Notification body contains workspace and time", TestNotificationBody);
        Run("Notification body falls back for invalid input", TestNotificationFallback);
        Run("DPAPI secret round trips for current user", TestSecretRoundTrip);
        Run("Hook merge preserves existing entries and is idempotent", TestHookMerge);
        Run("Hook removal removes only notifier entry", TestHookRemoval);
        Run("WeCom client accepts errcode zero", TestWeComSuccess);
        Run("WeCom client rejects nonzero errcode", TestWeComFailure);
        Run("WeCom client rejects HTTP failure", TestWeComHttpFailure);
        Run("Hook runner sends once and returns zero", TestHookRunner);
        Run("Hook runner returns zero on timeout", TestHookRunnerTimeout);
        Run("Configuration guidance text is preserved exactly", TestUserMessages);

        Console.WriteLine(failures == 0 ? "ALL TESTS PASSED" : failures + " TEST(S) FAILED");
        return failures == 0 ? 0 : 1;
    }

    private static void TestInvalidWebhooks()
    {
        string[] values =
        {
            "http://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=test-key",
            "https://example.com/cgi-bin/webhook/send?key=test-key",
            "https://qyapi.weixin.qq.com/cgi-bin/webhook/send",
            "https://qyapi.weixin.qq.com/other?key=test-key"
        };
        foreach (string value in values)
        {
            Assert(!WebhookValidator.IsValid(value), "invalid URL accepted: " + value);
        }
    }

    private static void TestNotificationBody()
    {
        DateTime time = new DateTime(2026, 7, 21, 9, 30, 0);
        string body = NotificationText.FromEventJson("{\"cwd\":\"C:\\\\Work\\\\Demo\"}", time);
        Assert(body.Contains("Codex 任务轮次已结束"), "missing title");
        Assert(body.Contains("工作区：Demo"), "missing workspace");
        Assert(body.Contains("时间：2026-07-21 09:30:00"), "missing time");
    }

    private static void TestNotificationFallback()
    {
        string body = NotificationText.FromEventJson("not-json", new DateTime(2026, 7, 21, 9, 30, 0));
        Assert(body.Contains("工作区：未知工作区"), "missing fallback");
    }

    private static void TestSecretRoundTrip()
    {
        using (TempDirectory temp = new TempDirectory())
        {
            string path = Path.Combine(temp.Path, "webhook.dat");
            SecretStore store = new SecretStore(path);
            store.Save("https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=test-key");
            Assert(store.Load().EndsWith("test-key", StringComparison.Ordinal), "secret mismatch");
            Assert(!File.ReadAllText(path).Contains("test-key"), "plaintext secret written");
        }
    }

    private static void TestHookMerge()
    {
        using (TempDirectory temp = new TempDirectory())
        {
            string path = Path.Combine(temp.Path, "hooks.json");
            File.WriteAllText(path, "{\"hooks\":{\"SessionStart\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"existing-start\"}]}],\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"existing-stop\"}]}]}}", Encoding.UTF8);
            HookConfigManager manager = new HookConfigManager(path);
            string executable = @"C:\Program Files\CodexWeComNotifier\CodexWeComNotifier.exe";
            manager.EnsureHook(executable);
            manager.EnsureHook(executable);
            string json = File.ReadAllText(path);
            Assert(json.Contains("existing-start"), "SessionStart removed");
            Assert(json.Contains("existing-stop"), "existing Stop removed");
            Assert(Count(json, "--hook") == 1, "notifier Hook duplicated");
        }
    }

    private static void TestHookRemoval()
    {
        using (TempDirectory temp = new TempDirectory())
        {
            string path = Path.Combine(temp.Path, "hooks.json");
            File.WriteAllText(path, "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"existing-stop\"}]}]}}", Encoding.UTF8);
            HookConfigManager manager = new HookConfigManager(path);
            string executable = @"C:\Program Files\CodexWeComNotifier\CodexWeComNotifier.exe";
            manager.EnsureHook(executable);
            manager.RemoveHook(executable);
            string json = File.ReadAllText(path);
            Assert(json.Contains("existing-stop"), "existing Stop removed");
            Assert(!json.Contains("--hook"), "notifier Hook remains");
        }
    }

    private static void TestWeComSuccess()
    {
        FakeHandler handler = new FakeHandler(HttpStatusCode.OK, "{\"errcode\":0,\"errmsg\":\"ok\"}");
        using (WeComClient client = new WeComClient(handler))
        {
            client.SendAsync("https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=test-key", "hello").GetAwaiter().GetResult();
        }
        Assert(handler.CallCount == 1, "unexpected request count");
        Assert(handler.LastBody.Contains("hello"), "message missing from request");
    }

    private static void TestWeComFailure()
    {
        FakeHandler handler = new FakeHandler(HttpStatusCode.OK, "{\"errcode\":93000,\"errmsg\":\"invalid\"}");
        bool threw = false;
        using (WeComClient client = new WeComClient(handler))
        {
            try
            {
                client.SendAsync("https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=test-key", "hello").GetAwaiter().GetResult();
            }
            catch (InvalidOperationException)
            {
                threw = true;
            }
        }
        Assert(threw, "nonzero errcode accepted");
    }

    private static void TestWeComHttpFailure()
    {
        FakeHandler handler = new FakeHandler(HttpStatusCode.BadGateway, "gateway error");
        bool threw = false;
        using (WeComClient client = new WeComClient(handler))
        {
            try
            {
                client.SendAsync("https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=test-key", "hello").GetAwaiter().GetResult();
            }
            catch (HttpRequestException)
            {
                threw = true;
            }
        }
        Assert(threw, "HTTP failure accepted");
    }

    private static void TestHookRunner()
    {
        using (TempDirectory temp = new TempDirectory())
        {
            string secretPath = Path.Combine(temp.Path, "webhook.dat");
            string statusPath = Path.Combine(temp.Path, "status.log");
            SecretStore store = new SecretStore(secretPath);
            store.Save("https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=test-key");
            FakeHandler handler = new FakeHandler(HttpStatusCode.OK, "{\"errcode\":0,\"errmsg\":\"ok\"}");
            using (WeComClient client = new WeComClient(handler))
            {
                HookRunner runner = new HookRunner(store, client, statusPath, () => new DateTime(2026, 7, 21, 9, 30, 0));
                int result = runner.Run(new StringReader("{\"cwd\":\"C:\\\\Work\\\\Demo\"}"));
                Assert(result == 0, "Hook returned nonzero");
            }
            Assert(handler.CallCount == 1, "Hook did not send exactly once");
            Assert(File.ReadAllText(statusPath).Contains("OK"), "success status missing");
        }
    }

    private static void TestHookRunnerTimeout()
    {
        using (TempDirectory temp = new TempDirectory())
        {
            string secretPath = Path.Combine(temp.Path, "webhook.dat");
            string statusPath = Path.Combine(temp.Path, "status.log");
            SecretStore store = new SecretStore(secretPath);
            store.Save("https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=test-key");
            TimeoutHandler handler = new TimeoutHandler();
            using (WeComClient client = new WeComClient(handler))
            {
                HookRunner runner = new HookRunner(store, client, statusPath, () => new DateTime(2026, 7, 21, 9, 30, 0));
                int result = runner.Run(new StringReader("{\"cwd\":\"C:\\\\Work\\\\Demo\"}"));
                Assert(result == 0, "Hook returned nonzero on timeout");
            }
            Assert(handler.CallCount == 1, "Hook did not attempt one request");
            Assert(File.ReadAllText(statusPath).Contains("ERROR"), "failure status missing");
        }
    }

    private static void TestUserMessages()
    {
        Assert(UserMessages.WebhookSteps == "可以先建两个机器人，然后和机器人拉个群聊，然后点群聊右上方的三个点···，找到消息推送，点“添加”即可提取webhook地址。", "Webhook steps changed");
        Assert(UserMessages.HookTrust == "在 Codex 设置的“钩子 / Hooks”里可以找到新的 Hook，设置信任即可。", "Hook trust text changed");
    }

    private static int Count(string value, string needle)
    {
        int count = 0;
        int index = 0;
        while ((index = value.IndexOf(needle, index, StringComparison.Ordinal)) >= 0)
        {
            count++;
            index += needle.Length;
        }
        return count;
    }

    private static void Run(string name, Action action)
    {
        try
        {
            action();
            Console.WriteLine("PASS " + name);
        }
        catch (Exception exception)
        {
            failures++;
            Console.WriteLine("FAIL " + name + ": " + exception.Message);
        }
    }

    private static void Assert(bool condition, string message)
    {
        if (!condition)
        {
            throw new InvalidOperationException(message);
        }
    }

    private sealed class FakeHandler : HttpMessageHandler
    {
        private readonly HttpStatusCode statusCode;
        private readonly string responseBody;

        public FakeHandler(HttpStatusCode statusCode, string responseBody)
        {
            this.statusCode = statusCode;
            this.responseBody = responseBody;
        }

        public int CallCount { get; private set; }
        public string LastBody { get; private set; }

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            CallCount++;
            LastBody = await request.Content.ReadAsStringAsync().ConfigureAwait(false);
            return new HttpResponseMessage(statusCode)
            {
                Content = new StringContent(responseBody, Encoding.UTF8, "application/json")
            };
        }
    }

    private sealed class TimeoutHandler : HttpMessageHandler
    {
        public int CallCount { get; private set; }

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            CallCount++;
            return Task.FromException<HttpResponseMessage>(new TaskCanceledException("timeout"));
        }
    }

    private sealed class TempDirectory : IDisposable
    {
        public TempDirectory()
        {
            Path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "CodexWeComNotifierTests", Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(Path);
        }

        public string Path { get; }

        public void Dispose()
        {
            try
            {
                Directory.Delete(Path, true);
            }
            catch
            {
            }
        }
    }
}
