using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;
using System.Threading.Tasks;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;

namespace ResearchCompanion.Windows;

internal sealed record TranscriptRow(string Id, string Role, string Text, bool CanOpenSource = false,
    string? SourceDisplay = null, string? SourceTitle = null, string? SourcePage = null,
    string? SourceDetails = null, string? SourceWarning = null, string? Original = null, bool Streaming = false);

internal sealed class WindowsTranscript : IDisposable
{
    internal static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);
    private const string Host = "rc-transcript.invalid";
    private const string StartPage = "https://" + Host + "/index.html";
    private readonly WebView2 view = new();
    internal WebView2 Control => view;
    private bool ready;
    private bool dark;
    private string? currentSnapshot;

    internal event Action<JsonElement>? Interaction;

    internal async Task StartAsync(string profile)
    {
        string resources = Path.Combine(AppContext.BaseDirectory, "Transcript");
        if (!File.Exists(Path.Combine(resources, "index.html")))
            throw new InvalidDataException("安装包缺少本地会话渲染资源。");
        await view.EnsureCoreWebView2Async(await CoreWebView2Environment.CreateAsync(
            userDataFolder: Path.Combine(profile, "WebView2")));
        var core = view.CoreWebView2;
        core.SetVirtualHostNameToFolderMapping(Host, resources, CoreWebView2HostResourceAccessKind.Deny);
        core.Settings.AreDevToolsEnabled = false;
        core.Settings.AreDefaultContextMenusEnabled = false;
        core.Settings.IsStatusBarEnabled = false;
        core.Settings.AreHostObjectsAllowed = false;
        core.NavigationStarting += (_, e) => e.Cancel = e.Uri != StartPage;
        core.FrameNavigationStarting += (_, e) => e.Cancel = true;
        core.NewWindowRequested += (_, e) => e.Handled = true;
        core.DownloadStarting += (_, e) => e.Cancel = true;
        core.PermissionRequested += (_, e) => e.State = CoreWebView2PermissionState.Deny;
        core.AddWebResourceRequestedFilter("*", CoreWebView2WebResourceContext.All);
        core.WebResourceRequested += (_, e) =>
        {
            if (Uri.TryCreate(e.Request.Uri, UriKind.Absolute, out var uri)
                && uri.Scheme == "https" && uri.Host == Host && uri.IsDefaultPort)
                return;
            e.Response = core.Environment.CreateWebResourceResponse(null, 403, "Forbidden", "");
        };
        await core.AddScriptToExecuteOnDocumentCreatedAsync("""
            if (window === window.top && location.origin === "https://rc-transcript.invalid") {
              Object.defineProperty(window, "webkit", { value: Object.freeze({
                messageHandlers: Object.freeze({ researchTranscript: Object.freeze({
                  postMessage: data => window.chrome.webview.postMessage(data)
                }) })
              }) });
              document.addEventListener("DOMContentLoaded", () => {
                document.getElementById("reveal-note").textContent = "在资源管理器中显示";
              });
            }
            """);
        core.WebMessageReceived += async (_, e) =>
        {
            if (e.Source != StartPage || e.WebMessageAsJson.Length > 300_000) return;
            using var message = JsonDocument.Parse(e.WebMessageAsJson);
            var root = message.RootElement;
            if (root.ValueKind != JsonValueKind.Object) return;
            if (root.TryGetProperty("ready", out var started) && started.ValueKind == JsonValueKind.True)
            {
                ready = true;
                await UpdateThemeAsync(dark);
                if (currentSnapshot != null) await RenderAsync(currentSnapshot);
                return;
            }
            if (ready) Interaction?.Invoke(root.Clone());
        };
        core.Navigate(StartPage);
    }

    internal Task PushAsync(string session, IReadOnlyList<TranscriptRow> rows, string emptyGuidance, int jump)
    {
        var order = new string[rows.Count];
        for (var i = 0; i < order.Length; i++) order[i] = rows[i].Id;
        var snapshot = JsonSerializer.Serialize(new { session, rows, order, emptyGuidance, jump }, Json);
        if (currentSnapshot == snapshot) return Task.CompletedTask;
        currentSnapshot = snapshot;
        return ready ? RenderAsync(snapshot) : Task.CompletedTask;
    }

    private Task<string> RenderAsync(string snapshot) =>
        view.CoreWebView2.ExecuteScriptAsync("window.ResearchTranscript.update(" + snapshot + ");");

    internal Task UpdateThemeAsync(bool value)
    {
        dark = value;
        view.DefaultBackgroundColor = value ? System.Drawing.Color.FromArgb(18, 24, 33) : System.Drawing.Color.FromArgb(247, 249, 252);
        if (view.CoreWebView2 != null)
            view.CoreWebView2.Profile.PreferredColorScheme = value
                ? CoreWebView2PreferredColorScheme.Dark : CoreWebView2PreferredColorScheme.Light;
        return Task.CompletedTask;
    }

    internal Task NoteSavedAsync(string message, string session, string? revealId = null) => ready
        ? view.CoreWebView2.ExecuteScriptAsync("window.ResearchTranscript.noteSaved("
            + JsonSerializer.Serialize(message, Json) + "," + JsonSerializer.Serialize(session, Json) + ","
            + JsonSerializer.Serialize(revealId ?? "", Json) + ");")
        : Task.CompletedTask;

    public void Dispose() => view.Dispose();
}
