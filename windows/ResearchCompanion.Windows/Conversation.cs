using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Microsoft.Win32;

namespace ResearchCompanion.Windows;

internal sealed partial class ResearchWindow
{
    private BridgeClient? connection;
    private string? workspace;
    private string? session;
    private string? blockedSession;
    private JsonElement lastConversation;
    private ModelChoice? chosenModel;
    private List<ModelChoice> models = new();
    private readonly Dictionary<string, SourceReceipt> receipts = new(StringComparer.Ordinal);
    private readonly Dictionary<string, string> drafts = new(StringComparer.Ordinal);
    private readonly Dictionary<string, ReplyNote> notes = new(StringComparer.Ordinal);
    private readonly Dictionary<string, string> savedNotes = new(StringComparer.Ordinal);

    private sealed record ModelChoice(string Name, string Provider, string Model, string? Effort)
    {
        internal Dictionary<string, string> Wire()
        {
            var options = new Dictionary<string, string> { ["provider"] = Provider, ["model"] = Model };
            if (Effort != null) options["reasoningEffort"] = Effort;
            return options;
        }
        public override string ToString() => Name;
    }

    private sealed record SourceReceipt(string RequestId, string Title, string Text, string Scope,
        string? Url, IReadOnlyList<DocumentExcerpt> Pages, bool DispatchVerified = false,
        string? AppSourceLink = null, bool PositionVerified = false);
    private sealed record ReplyNote(string Text, string? Question, SourceReceipt? Source);

    private async Task ConnectAsync()
    {
        if (busy) return;
        SetBusy(true);
        status.Text = "正在检查科研桥…";
        BridgeClient? newClient = null;
        try
        {
            newClient = await BridgeClient.ConnectAsync(lifetime.Token);
            var workspaceResponse = await newClient.RequestAsync("workspaces", null, lifetime.Token);
            var visible = Array(workspaceResponse, "workspaces").ToList();
            if (visible.Count != 1 || Text(visible[0], "id") is not string validWorkspace)
                throw new InvalidDataException("科研桥未报告唯一科研工作区。请检查 DSH 插件。");
            if (connection != null) await connection.DisposeAsync();
            connection = newClient;
            newClient = null;
            if (workspace != validWorkspace)
            {
                workspace = validWorkspace;
                session = null;
                lastConversation = default;
                receipts.Clear();
                chosenModel = null;
                models.Clear();
                UpdateModelButton();
                blockedSession = null;
            }
            await RefreshModelsAsync();
            if (session != null) await RefreshCurrentConversationAsync();
            if (session == null && workspace == settings.Workspace && settings.Session != null)
            {
                try
                {
                    var restored = await connection.RequestAsync("conversation", Target(settings.Session), lifetime.Token);
                    session = settings.Session;
                    lastConversation = restored;
                    await RenderAsync();
                }
                catch (BridgeRequestException) { session = null; }
            }
            status.Text = models.Count == 0 ? "DSH 已连接。请在 DSH 配置可用的账号模型。" : "DSH 已连接";
        }
        catch
        {
            if (newClient != null) await newClient.DisposeAsync();
            throw;
        }
        finally { SetBusy(false); }
    }

    private async Task RefreshModelsAsync()
    {
        if (connection == null) return;
        JsonElement reply = await connection.RequestAsync("modelCatalog", null, lifetime.Token);
        var result = new List<ModelChoice>();
        foreach (var group in Array(Field(reply, "catalog"), "groups"))
        {
            var provider = Text(group, "id");
            if (provider is not ("chatgpt" or "chatgpt-sub" or "deepseek-account")) continue;
            foreach (var model in Array(group, "models"))
            {
                string? id = Text(model, "id");
                if (id == null) continue;
                var name = Text(model, "name") ?? id;
                if (provider == "deepseek-account") name += " · DeepSeek 账号";
                var efforts = Array(Field(model, "reasoning"), "efforts").ToList();
                if (efforts.Count == 0) result.Add(new(name, provider, id, null));
                foreach (var effort in efforts)
                    if (Text(effort, "id") is string value)
                        result.Add(new(name + " · " + (Text(effort, "name") ?? value), provider, id, value));
            }
        }
        models = result;
        if (chosenModel != null && !models.Contains(chosenModel)) chosenModel = null;
        UpdateModelButton();
    }

    private Task PickModelAsync()
    {
        if (busy) return Task.CompletedTask;
        if (models.Count == 0) throw new InvalidOperationException("没有可用账号模型。请先连接 DSH 并核对账号。");
        var menu = new ContextMenu();
        foreach (var model in models)
        {
            var item = new MenuItem { Header = model.Name, IsCheckable = true, IsChecked = chosenModel == model };
            item.Click += (_, _) =>
            {
                if (model.Provider == "deepseek-account" && MessageBox.Show(this,
                    "是否为本会话使用 DeepSeek 账号模型？请求可能消耗账号余额。",
                    "选择模型", MessageBoxButton.YesNo) != MessageBoxResult.Yes)
                    return;
                chosenModel = model;
                UpdateModelButton();
            };
            menu.Items.Add(item);
        }
        modelButton.ContextMenu = menu;
        menu.PlacementTarget = modelButton;
        menu.IsOpen = true;
        return Task.CompletedTask;
    }

    private void UpdateModelButton()
    {
        modelButton.Content = chosenModel?.Name ?? "选择模型";
        RefreshSendButton();
    }

    private void SetBusy(bool value)
    {
        busy = value;
        cancel.Visibility = waiting != null && value ? Visibility.Visible : Visibility.Collapsed;
        foreach (var button in buttons)
            if (button != cancel && button != send && button != pin)
                button.IsEnabled = !value;
        include.IsEnabled = !value;
        composer.IsReadOnly = value;
        RefreshSendButton();
    }

    private void RefreshSendButton() => send.IsEnabled = !busy && connection != null && workspace != null
        && chosenModel != null && !string.IsNullOrWhiteSpace(composer.Text) &&
        (session == null || blockedSession != session);

    private Dictionary<string, object?> Target(string id) =>
        new() { ["workspaceId"] = workspace!, ["sessionId"] = id };

    private async Task SendAsync()
    {
        if (busy || connection == null || workspace == null || chosenModel == null || string.IsNullOrWhiteSpace(composer.Text))
            return;
        if (session != null && blockedSession == session)
            throw new InvalidOperationException("上一轮提交状态尚未确认。请先在 DSH 核对，或另开新会话。");

        using var cancelToken = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        waiting = cancelToken;
        var ct = waiting.Token;
        var client = connection;
        var choice = chosenModel;
        string question = composer.Text.Trim();
        if (question.Length > 16_000)
        {
            waiting = null;
            throw new InvalidDataException("问题过长，请拆分后发送。");
        }
        bool submitting = false;
        bool admitted = false;
        SetBusy(true);
        try
        {
            status.Text = "正在核对材料…";
            string requestId = "dsh-pet-" + Guid.NewGuid();
            var source = include.IsChecked == true ? await PrepareSourceAsync(question, requestId, ct) : null;
            if (session == null)
            {
                var createdId = Guid.NewGuid().ToString();
                var fields = Target(createdId);
                fields["title"] = PlainLabel(question, 80);
                var created = await client.RequestAsync("createSession", fields, ct);
                if (Text(created, "sessionId") != createdId) throw new InvalidDataException("科研桥返回了不同的会话标识。");
                session = createdId;
            }
            else
            {
                var current = await client.RequestAsync("conversation", Target(session), ct);
                if (Flag(current, "running")) throw new InvalidOperationException("此会话仍在运行，请等待当前任务完成。");
            }
            var id = session;
            var modelRequest = Target(id);
            modelRequest["selection"] = choice.Wire();
            await client.RequestAsync("researchSelectModel", modelRequest, ct);
            var request = new Dictionary<string, object?>(modelRequest)
            {
                ["requestId"] = requestId, ["text"] = question, ["mode"] = "ask",
                ["includeContext"] = source != null
            };
            if (source != null)
            {
                var material = new Dictionary<string, string>
                {
                    ["source"] = source.Pages.Count > 0 ? "PDF/文本" : "Windows 选区",
                    ["title"] = PlainLabel(source.Title, 512),
                    ["scope"] = PlainLabel(source.Scope, 512),
                    ["text"] = source.Text
                };
                if (source.Pages.Count == 1) material["page"] = $"文件第 {source.Pages[0].Page} 页";
                if (source.Url != null) material["url"] = source.Url;
                request["material"] = material;
                receipts[requestId] = source;
            }
            status.Text = "正在提交给 DSH…";
            submitting = true;
            var accepted = await client.RequestAsync("researchPrompt", request, ct);
            if (!Flag(accepted, "accepted")) throw new InvalidDataException("科研桥未返回可确认的提交回执。");
            admitted = true;
            composer.Clear();
            SaveSettings();
            ++jump;
            status.Text = "已提交 · 等待回复";
            var deadline = DateTime.UtcNow.AddMinutes(6);
            var verify = Target(id);
            verify["requestId"] = requestId;
            while (DateTime.UtcNow < deadline)
            {
                var reply = await client.RequestAsync("conversation", verify, ct);
                if (source != null && VerifyDispatch(Field(reply, "dispatchEvidence"), source, choice))
                {
                    var verified = source with { DispatchVerified = true };
                    receipts[requestId] = verified;
                    SaveReceipt(id, verified);
                    source = null;
                }
                lastConversation = reply;
                await RenderAsync();
                bool hasReply = Array(reply, "messages").Any(item =>
                    Text(item, "role") == "assistant" && Text(Field(item, "reply"), "requestId") == requestId);
                if (!Flag(reply, "running") && hasReply)
                {
                    status.Text = "回复完成";
                    return;
                }
                if (Text(reply, "error") is string failure && !Flag(reply, "running"))
                {
                    status.Text = "DSH 返回错误 · " + failure;
                    return;
                }
                await Task.Delay(850, ct);
            }
            status.Text = "已提交，等待超时。请刷新会话或在 DSH 查看进度。";
        }
        catch (BridgeRequestException error)
        {
            status.Text = admitted ? "已提交，后续读取失败 · " + error.Message : "科研桥拒绝请求 · " + error.Message;
        }
        catch (OperationCanceledException)
        {
            if (submitting && !admitted) blockedSession = session;
            status.Text = admitted ? "已停止等待。DSH 可能仍在处理。" :
                submitting ? "已停止等待，提交结果尚未确认。请在 DSH 核对。" : "已取消，未提交。";
        }
        catch (Exception error) when (submitting)
        {
            if (!admitted) blockedSession = session;
            status.Text = (admitted ? "已提交，后续读取失败 · " : "提交状态无法确认 · ") + error.Message;
        }
        finally
        {
            waiting = null;
            SetBusy(false);
        }
    }

    private async Task<SourceReceipt?> PrepareSourceAsync(string question, string requestId, CancellationToken ct)
    {
        var currentSelection = selection;
        var currentDocument = document;
        if (currentSelection == null && currentDocument == null) return null;
        bool useOnlySelection = question.Contains("只用选区", StringComparison.Ordinal)
            || question.Contains("只翻译选区", StringComparison.Ordinal)
            || question.Contains("仅根据选区", StringComparison.Ordinal);
        if (useOnlySelection && currentSelection == null)
            throw new InvalidDataException("本轮请求限于选区，但当前没有可用选区。");
        IReadOnlyList<DocumentExcerpt> pages = currentDocument == null || useOnlySelection
            ? System.Array.Empty<DocumentExcerpt>() : await currentDocument.RetrieveAsync(question, ct);
        var parts = pages.Select(page => $"【文件第 {page.Page} 页】\n{page.Text}").ToList();
        if (currentSelection != null)
            parts.Add((pages.Count == 0 ? "" : "【所选文字】\n") + currentSelection.Text);
        var text = string.Join("\n\n", parts);
        if (string.IsNullOrWhiteSpace(text) || text.Length > 24_000 || text.Contains('\0'))
            throw new InvalidDataException("本轮材料为空、格式无效或过长。请缩小读取范围。");
        var title = pages.Count > 0 ? pages[0].Title : currentSelection!.Title ?? currentSelection.Application;
        var scope = pages.Count > 0
            ? "文件页 " + string.Join("、", pages.Select(page => page.Page).Distinct()) + (currentSelection == null ? "" : "及所选文字")
            : currentSelection!.ProvenanceVerified ? "用户选区" : "用户选区 · 出处未核验";
        return new(requestId, title, text, scope,
            pages.Count == 0 && currentSelection!.ProvenanceVerified ? CleanSourceUrl(currentSelection.Url) : null, pages,
            AppSourceLink: pages.Count == 0 && currentSelection?.Application == "Zotero" &&
                currentSelection.ProvenanceVerified ? ZoteroLink(currentSelection.Url) : null,
            PositionVerified: pages.Count > 0 || currentSelection?.ProvenanceVerified == true);
    }

    private static bool VerifyDispatch(JsonElement proof, SourceReceipt source, ModelChoice choice) =>
        Text(proof, "requestId") == source.RequestId &&
        string.Equals(Text(proof, "sha256"), Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(source.Text))), StringComparison.OrdinalIgnoreCase) &&
        Field(proof, "utf16Length").TryReadInt() == source.Text.Length &&
        Text(Field(proof, "selection"), "provider") == choice.Provider &&
        Text(Field(proof, "selection"), "model") == choice.Model &&
        Text(Field(proof, "selection"), "reasoningEffort") == choice.Effort;

    private async Task OpenSessionAsync(string? id)
    {
        if (busy) return;
        drafts[session ?? "empty"] = composer.Text;
        session = id;
        document = null;
        selection = null;
        chosenModel = null;
        lastConversation = default;
        receipts.Clear();
        composer.Text = drafts.GetValueOrDefault(id ?? "empty", "");
        SaveSettings();
        UpdateModelButton();
        UpdateMaterial();
        ++jump;
        if (id != null) await RefreshCurrentConversationAsync();
        else await RenderAsync();
    }

    private async Task RefreshCurrentConversationAsync()
    {
        if (session == null || connection == null) return;
        lastConversation = await connection.RequestAsync("conversation", Target(session), lifetime.Token);
        if (Text(lastConversation, "historyRevision") == null) throw new InvalidDataException("没有可用的会话数据。");
        await RenderAsync();
    }

    private async Task ShowHistoryAsync()
    {
        if (busy || workspace == null || connection == null) return;
        var title = new TextBox { Margin = new Thickness(0, 0, 5, 0), MinWidth = 150 };
        var material = new TextBox { Margin = new Thickness(0, 0, 5, 0), MinWidth = 140 };
        AutoLabel(title, "标题");
        AutoLabel(material, "材料");
        var archive = new ComboBox { ItemsSource = new[] { "全部", "未归档", "已归档" }, SelectedIndex = 0, MinWidth = 80 };
        var filter = new Button { Content = "查找" };
        var more = new Button { Content = "下一页", IsEnabled = false, Margin = new Thickness(0, 5, 0, 0) };
        var controls = new WrapPanel();
        foreach (var item in new UIElement[] { new TextBlock { Text = "标题 " }, title, new TextBlock { Text = "材料 " }, material, archive, filter })
            controls.Children.Add(item);
        var results = new ListBox { DisplayMemberPath = nameof(HistoryRow.Title), Margin = new Thickness(0, 8, 0, 0) };
        var view = new DockPanel { Margin = new Thickness(15) };
        DockPanel.SetDock(controls, Dock.Top);
        DockPanel.SetDock(more, Dock.Bottom);
        view.Children.Add(controls);
        view.Children.Add(more);
        view.Children.Add(results);
        var dialog = Dialog("科研会话历史", view, 555, 475);
        string? nextRevision = null;
        int? next = null;
        bool loading = false;
        string? selectionId = null;
        async Task Load(int offset)
        {
            if (loading) return;
            loading = true;
            try
            {
                var values = new Dictionary<string, object?> {
                    ["workspaceId"] = workspace, ["historyTitle"] = title.Text, ["historyMaterial"] = material.Text,
                    ["historyStatus"] = new[] { "all", "active", "archived" }[archive.SelectedIndex],
                    ["historyOffset"] = offset
                };
                if (offset > 0 && nextRevision != null) values["historyRevision"] = nextRevision;
                JsonElement reply = await connection.RequestAsync("researchHistory", values, lifetime.Token);
                results.ItemsSource = Array(reply, "matches").Select(item =>
                    new HistoryRow(Text(item, "sessionId") ?? "", Text(item, "title") ?? "未命名会话"))
                    .Where(item => item.Id.Length != 0).ToList();
                next = Field(reply, "nextOffset").TryReadInt();
                nextRevision = Text(reply, "revision");
                more.IsEnabled = next.HasValue && nextRevision != null;
            }
            finally { loading = false; }
        }
        filter.Click += async (_, _) => await RunUiAsync(() => Load(0));
        more.Click += async (_, _) => { if (next is int value) await RunUiAsync(() => Load(value)); };
        results.MouseDoubleClick += (_, _) =>
        {
            if (results.SelectedItem is HistoryRow row) { selectionId = row.Id; dialog.DialogResult = true; }
        };
        dialog.Loaded += async (_, _) => await RunUiAsync(() => Load(0));
        if (dialog.ShowDialog() == true && selectionId != null)
            await OpenSessionAsync(selectionId);
    }

    private sealed record HistoryRow(string Id, string Title);

    private async Task RenderAsync()
    {
        var rows = new List<TranscriptRow>();
        notes.Clear();
        foreach (var entry in Array(lastConversation, "messages"))
        {
            var role = Text(entry, "role");
            var id = Text(entry, "id");
            var text = Text(entry, "text");
            if (role is not ("user" or "assistant") || id == null || text == null) continue;
            id = role + ":" + id;
            if (role == "user")
            {
                rows.Add(new(id, role, DisplayQuestion(text), Original: text));
                notes[id] = new(text, null, null);
                continue;
            }
            var reply = Field(entry, "reply");
            var requestId = Text(reply, "requestId");
            var receipt = requestId != null && session != null ? ReadReceipt(session, requestId) : null;
            var material = Field(reply, "material");
            string? contextTitle = receipt?.Title ?? Text(material, "title");
            string? scope = receipt?.Scope ?? Text(material, "scope");
            notes[id] = new(text, Text(reply, "question"), receipt);
            rows.Add(new(id, role, text, CanOpenSource: receipt?.DispatchVerified == true &&
                (receipt.Pages.Count > 0 || receipt.Url != null || receipt.AppSourceLink != null), SourceDisplay: contextTitle, SourceTitle: contextTitle,
                SourcePage: receipt?.Pages.Count == 1 ? $"摘录页 {receipt.Pages[0].Page}" : null,
                SourceDetails: scope, SourceWarning: contextTitle == null ? null : receipt?.DispatchVerified != true
                    ? "模型输入与出处未完整核验" : receipt.PositionVerified ? null : "出处未核验"));
        }
        await transcript.PushAsync(session ?? "empty", rows, selection != null || document != null
            ? "材料已就绪。输入问题，或要求翻译、解释。" : "选取文字、选择文件，或直接输入问题。", jump);
    }

    private async Task HandleTranscriptAsync(JsonElement action)
    {
        try
        {
            if (Text(action, "openLink") is string web)
            {
                if (CleanSourceUrl(web) is string uri && MessageBox.Show(this, uri, "在浏览器中打开链接",
                    MessageBoxButton.OKCancel) == MessageBoxResult.OK) OpenExternal(uri);
                return;
            }
            if (Text(action, "copyTeX") is string tex && tex.Length <= 30_000) { Clipboard.SetText(tex); return; }
            if (Text(action, "session") != (session ?? "empty")) return;
            if (Text(action, "noteRevealID") is string reveal && savedNotes.TryGetValue(reveal, out var file) && File.Exists(file))
            {
                var explorer = new System.Diagnostics.ProcessStartInfo("explorer.exe") { UseShellExecute = false };
                explorer.ArgumentList.Add("/select," + file);
                System.Diagnostics.Process.Start(explorer);
                return;
            }
            if (Text(action, "copyID") is string copy && notes.TryGetValue(copy, out var message)) { Clipboard.SetText(message.Text); return; }
            string? evidence = Text(action, "directSourceID") ?? Text(action, "sourceID");
            if (evidence != null && notes.TryGetValue(evidence, out var source))
            {
                if (source.Source == null || !source.Source.DispatchVerified)
                    throw new InvalidDataException("没有可核对的本次发送收据。");
                if (Text(action, "sourceID") != null) ShowSourceExcerpt(source.Source);
                else if (source.Source.Pages.Count > 0) await OpenDocumentSourceAsync(source.Source);
                else if (CleanSourceUrl(source.Source.Url) is string address) OpenExternal(address);
                else if (ZoteroLink(source.Source.AppSourceLink) is string zotero) OpenExternal(zotero);
                return;
            }
            if (Text(action, "noteID") is string noteId && notes.TryGetValue(noteId, out var note))
                await ExportNoteAsync(note, Text(action, "selection"), Text(action, "noteMode"));
        }
        catch (Exception error) { status.Text = error.Message; }
    }

    private void ShowSourceExcerpt(SourceReceipt source)
    {
        var area = new TextBox
        {
            IsReadOnly = true, Text = source.Scope + "\n\n" + source.Text, Margin = new Thickness(12),
            TextWrapping = TextWrapping.Wrap, VerticalScrollBarVisibility = ScrollBarVisibility.Auto
        };
        Dialog(source.Title, area, 620, 525).ShowDialog();
    }

    private async Task OpenDocumentSourceAsync(SourceReceipt source)
    {
        DocumentExcerpt excerpt = source.Pages[0];
        var file = await PdfEvidence.OpenAsync(excerpt.FilePath, lifetime.Token);
        if (file.Fingerprint != excerpt.Fingerprint)
            throw new InvalidDataException("本地原文已变化，无法复用当时的页位。请查看已保存的摘录。");
        if (!file.IsPdf) { ShowSourceExcerpt(source); return; }

        var picker = new ComboBox { Margin = new Thickness(12), ItemsSource = source.Pages.Select(page => "文件第 " + page.Page + " 页").ToList() };
        var canvasHost = new ScrollViewer { HorizontalScrollBarVisibility = ScrollBarVisibility.Auto };
        var box = new DockPanel();
        DockPanel.SetDock(picker, Dock.Top);
        box.Children.Add(picker);
        box.Children.Add(canvasHost);
        var dialog = Dialog(source.Title, box, 790, 790);
        using var closing = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        int revision = 0;
        picker.SelectionChanged += async (_, _) =>
        {
            if (picker.SelectedIndex < 0) return;
            var requested = source.Pages[picker.SelectedIndex];
            int attempt = ++revision;
            try
            {
                var page = await file.RenderPageAsync(requested.Page, 1060, closing.Token);
                if (closing.IsCancellationRequested || revision != attempt) return;
                var canvas = new Canvas { Width = page.Width, Height = page.Height };
                canvas.Children.Add(new Image { Source = BitmapSource.Create(page.Width, page.Height, 96, 96,
                    PixelFormats.Bgr32, null, page.Pixels, page.Stride), Width = page.Width, Height = page.Height });
                foreach (var region in requested.Regions)
                {
                    var mark = new System.Windows.Shapes.Rectangle
                    {
                        Fill = new SolidColorBrush(Color.FromArgb(73, 255, 204, 64)),
                        Width = region.Width * page.Width, Height = region.Height * page.Height
                    };
                    Canvas.SetLeft(mark, region.X * page.Width);
                    Canvas.SetTop(mark, region.Y * page.Height);
                    canvas.Children.Add(mark);
                }
                canvasHost.Content = canvas;
            }
            catch (OperationCanceledException) when (closing.IsCancellationRequested) { }
            catch (Exception error) { canvasHost.Content = new TextBlock { Text = error.Message, TextWrapping = TextWrapping.Wrap }; }
        };
        picker.SelectedIndex = 0;
        dialog.Closed += (_, _) => closing.Cancel();
        dialog.ShowDialog();
    }

    private async Task ExportNoteAsync(ReplyNote note, string? selected, string? mode)
    {
        bool hasSelection = !string.IsNullOrWhiteSpace(selected);
        string body = hasSelection ? selected! : note.Text;
        if (body.Length > 250_000) throw new InvalidDataException("笔记内容过长。请选择更短的片段。");
        string? extra = null;
        if (mode == "supplement")
        {
            var edit = new TextBox { AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(12) };
            var buttons = new DockPanel();
            var confirm = new Button { Content = "继续保存", Margin = new Thickness(10), Height = 30 };
            DockPanel.SetDock(confirm, Dock.Bottom);
            buttons.Children.Add(confirm);
            buttons.Children.Add(edit);
            var modal = Dialog("添加补充", buttons, 490, 260);
            confirm.Click += (_, _) => modal.DialogResult = true;
            if (modal.ShowDialog() != true) return;
            extra = edit.Text.Trim();
        }
        var dialog = new SaveFileDialog { FileName = "科研笔记-" + DateTime.Now.ToString("yyyyMMdd-HHmm"),
            Filter = "Markdown 笔记|*.md", AddExtension = true, DefaultExt = ".md", OverwritePrompt = true };
        if (dialog.ShowDialog(this) != true) return;
        var markdown = new StringBuilder("# 科研笔记\n\n");
        if (!string.IsNullOrWhiteSpace(note.Question)) markdown.Append("## 提问\n\n").Append(note.Question).Append("\n\n");
        markdown.Append(hasSelection ? "## 回答选段\n\n" : "## 回答\n\n").Append(body).Append("\n\n");
        if (!string.IsNullOrWhiteSpace(extra)) markdown.Append("## 补充\n\n").Append(extra).Append("\n\n");
        if (note.Source?.DispatchVerified == true)
        {
            markdown.Append("## 原文出处\n\n").Append(note.Source.Title).Append(" · ")
                .Append(note.Source.Scope).Append('\n');
            if (note.Source.Url != null) markdown.Append(note.Source.Url).Append('\n');
            markdown.Append("\n").Append(note.Source.Text);
        }
        else markdown.Append("## 原文出处\n\n此条回答没有经过发送核对的原文收据。\n");
        var staged = Path.Combine(Path.GetDirectoryName(dialog.FileName)!, $".research-note-{Guid.NewGuid():N}.tmp");
        try
        {
            await using (var writer = new StreamWriter(new FileStream(staged, FileMode.CreateNew), new UTF8Encoding(false)))
                await writer.WriteAsync(markdown.ToString().AsMemory(), lifetime.Token);
            lifetime.Token.ThrowIfCancellationRequested();
            File.Move(staged, dialog.FileName, overwrite: true);
        }
        finally
        {
            if (File.Exists(staged)) File.Delete(staged);
        }
        string key = Guid.NewGuid().ToString("N");
        savedNotes[key] = dialog.FileName;
        await transcript.NoteSavedAsync("笔记已保存", session ?? "empty", key);
    }

    private string ReceiptPath(string id, string requestId)
    {
        string hash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(workspace + "\0" + id + "\0" + requestId)));
        return Path.Combine(App.Profile, "Receipts", hash + ".json");
    }

    private SourceReceipt? ReadReceipt(string id, string requestId)
    {
        if (receipts.TryGetValue(requestId, out var known)) return known;
        try
        {
            string path = ReceiptPath(id, requestId);
            if (!File.Exists(path) || new FileInfo(path).Length > 2_000_000) return null;
            var result = JsonSerializer.Deserialize<SourceReceipt>(File.ReadAllText(path));
            if (result?.RequestId == requestId && result.DispatchVerified) receipts[requestId] = result;
            return result?.RequestId == requestId && result.DispatchVerified ? result : null;
        }
        catch (IOException) { return null; }
        catch (JsonException) { return null; }
    }

    private void SaveReceipt(string id, SourceReceipt receipt)
    {
        string path = ReceiptPath(id, receipt.RequestId);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        string temporary = path + ".new";
        File.WriteAllText(temporary, JsonSerializer.Serialize(receipt));
        File.Move(temporary, path, overwrite: true);
    }

    private static string DisplayQuestion(string text)
    {
        const string marker = "\n\n【用户问题】\n";
        int position = text.IndexOf(marker, StringComparison.Ordinal);
        return position >= 0 && text.Contains("原文，JSON 引用数据】", StringComparison.Ordinal)
            ? text[(position + marker.Length)..].Trim() : text;
    }
    private static string PlainLabel(string value, int limit)
    {
        string sanitized = string.Join(" ", value.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        sanitized = new string(sanitized.Where(c => !char.IsControl(c)).ToArray());
        var end = Math.Min(sanitized.Length, limit);
        if (end != 0 && char.IsHighSurrogate(sanitized[end - 1])) end--;
        return end != 0 ? sanitized[..end] : "科研材料";
    }
    private static string? CleanSourceUrl(string? url) =>
        Uri.TryCreate(url, UriKind.Absolute, out var uri) && (uri.Scheme == "https" || uri.Scheme == "http")
        && string.IsNullOrEmpty(uri.UserInfo) && !uri.IsLoopback
        ? uri.GetLeftPart(UriPartial.Path) : null;
    private static string? ZoteroLink(string? url) => url != null &&
        System.Text.RegularExpressions.Regex.IsMatch(url,
            @"\Azotero://(?:select|open-pdf)/(?:library|groups/[0-9]{1,12})/items/[A-Z0-9]{8}(?:\?page=[1-9][0-9]{0,5})?\z")
        ? url : null;
    private static void OpenExternal(string uri) =>
        System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(uri) { UseShellExecute = true });
    private static JsonElement Field(JsonElement element, string key) =>
        element.ValueKind == JsonValueKind.Object && element.TryGetProperty(key, out var value) ? value : default;
    private static string? Text(JsonElement element, string key)
    {
        var field = Field(element, key);
        return field.ValueKind == JsonValueKind.String ? field.GetString() : null;
    }
    private static bool Flag(JsonElement element, string key) => Field(element, key).ValueKind == JsonValueKind.True;
    private static IEnumerable<JsonElement> Array(JsonElement element, string key)
    {
        var field = Field(element, key);
        return field.ValueKind == JsonValueKind.Array ? field.EnumerateArray().ToArray() : System.Array.Empty<JsonElement>();
    }
}

internal static class ConversationJson
{
    internal static int? TryReadInt(this JsonElement value) =>
        value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out int number) ? number : null;
}
