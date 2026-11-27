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
    private JsonElement activeStream;
    private int streamRevision = -1;
    private ModelChoice? chosenModel;
    private List<ModelChoice> models = new();
    private readonly Dictionary<string, SourceReceipt> receipts = new(StringComparer.Ordinal);
    private readonly Dictionary<string, string> drafts = new(StringComparer.Ordinal);
    private readonly Dictionary<string, ReplyNote> notes = new(StringComparer.Ordinal);
    private readonly Dictionary<string, string> savedNotes = new(StringComparer.Ordinal);

    private sealed record ModelChoice(string Name, string Provider, string Model, string? Effort, bool SupportsImages)
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
        string? AppSourceLink = null, bool PositionVerified = false, IReadOnlyList<CropReceipt>? Crops = null,
        string? ZoteroPairingId = null);
    private sealed record CropReceipt(int Page, string Sha256);
    private sealed record SourceCrop(CropReceipt Receipt, byte[] Bytes)
    {
        internal object Wire() => new
        {
            mediaType = "image/png", name = $"PDF-page-{Receipt.Page}.png", data = Convert.ToBase64String(Bytes)
        };
    }
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
            var priorHost = connection?.CurrentHost;
            if (connection != null) await connection.DisposeAsync();
            connection = newClient;
            newClient = null;
            bool scopeChanged = workspace != validWorkspace || priorHost != connection.CurrentHost;
            if (scopeChanged)
            {
                workspace = validWorkspace;
                session = null;
                lastConversation = default;
                receipts.Clear();
                activeStream = default;
                streamRevision = -1;
                chosenModel = null;
                models.Clear();
                UpdateModelButton();
                blockedSession = null;
                if (priorHost != null)
                {
                    ClearDocument();
                    selection = null;
                    UpdateMaterial();
                }
            }
            await RefreshModelsAsync();
            if (session != null) await RefreshCurrentConversationAsync();
            if (session == null && workspace == settings.Workspace && settings.Session != null &&
                (settings.RecoveryHost == null || settings.RecoveryHost == connection.RecoveryHost))
            {
                try
                {
                    var restored = await connection.RequestAsync("conversation", Target(settings.Session), lifetime.Token);
                    if (Text(restored, "historyRevision") == null) throw new InvalidDataException("没有可用的会话数据。");
                    session = settings.Session;
                    lastConversation = restored;
                    RestoreSessionModel(restored);
                    MergeStream(Field(restored, "stream"));
                    await RenderAsync();
                }
                catch (BridgeRequestException) { session = null; }
            }
            status.Text = models.Count == 0 ? "DSH 已连接。请在 DSH 配置可用的账号模型。" : "DSH 已连接";
            if (scopeChanged)
            {
                if (document == null) await RestoreSessionFileAsync();
                else SaveSessionFile();
                await RestoreDraftImagesAsync(lifetime.Token);
                await RenderAsync();
            }
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
                bool supportsImages = Array(model, "inputModalities").Any(item => item.ValueKind == JsonValueKind.String && item.GetString() == "image");
                if (efforts.Count == 0) result.Add(new(name, provider, id, null, supportsImages));
                foreach (var effort in efforts)
                    if (Text(effort, "id") is string value)
                        result.Add(new(name + " · " + (Text(effort, "name") ?? value), provider, id, value, supportsImages));
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
        var menu = ThemedMenu(modelButton);
        foreach (var model in models)
        {
            var item = new MenuItem { Header = model.Name, IsCheckable = true, IsChecked = chosenModel == model };
            item.Click += async (_, _) => await RunUiAsync(() => ChooseSessionModelAsync(model));
            menu.Items.Add(item);
        }
        modelButton.ContextMenu = menu;
        menu.IsOpen = true;
        return Task.CompletedTask;
    }

    private void UpdateModelButton()
    {
        modelButton.Content = chosenModel?.Name ?? "选择模型";
        modelButton.ToolTip = chosenModel?.Name;
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
        draftImagePanel.IsEnabled = !value;
        RefreshSendButton();
    }

    private void RefreshSendButton() => send.IsEnabled = !busy && connection != null && workspace != null
        && chosenModel != null && (!string.IsNullOrWhiteSpace(composer.Text) || draftImages.Count != 0) &&
        (session == null || blockedSession != session);

    private Dictionary<string, object?> Target(string id) =>
        new() { ["workspaceId"] = workspace!, ["sessionId"] = id };

    private async Task SendAsync()
    {
        if (busy || connection is not { } client || workspace == null || chosenModel is not { } choice)
            return;
        string question = composer.Text.Trim();
        if (question.Length == 0 && draftImages.Count == 0) return;
        if (question.Length == 0) question = "请说明所附图片中的主要内容。";
        if (question.Length > 16_000) throw new InvalidDataException("问题过长，请拆分后发送。");
        if (session != null && blockedSession == session)
            throw new InvalidOperationException("上一轮提交状态尚未确认。请先在 DSH 核对，或另开新会话。");

        using var cancelToken = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        waiting = cancelToken;
        var ct = waiting.Token;
        bool submitting = false;
        bool admitted = false;
        using var streamCancellation = CancellationTokenSource.CreateLinkedTokenSource(ct);
        Task? streamSubscription = null;
        streamRevision = -1;
        activeStream = default;
        SetBusy(true);
        try
        {
            var userImages = draftImages.Select(x => x.Image).ToArray();
            var limits = ImageBudget.Decode(client.AttachmentLimits);
            if (userImages.Length > 0 && (!choice.SupportsImages || draftImages.Any(x =>
                x.Width > limits.Dimension || x.Height > limits.Dimension ||
                !ValidDimensions(x.Width, x.Height, limits.Pixels))))
                throw new InvalidDataException("附图需要当前明确选择且支持图片的模型，并符合 DSH 的图片限制。");
            limits.Check(userImages, []);
            status.Text = "正在核对材料…";
            var evidence = await PrepareTurnEvidenceAsync(question, userImages.Length != 0, ct);
            if (evidence.Guidance != null && !client.SupportsPromptGuidance && !evidence.IsDiscussion)
                throw new InvalidDataException("本轮证据说明需要科研桥 0.2.8，消息未发送。");
            if (evidence.IsTranslation && userImages.Length != 0)
                throw new InvalidDataException("文档翻译与附图需分开处理。请移除图片，或在输入框提问图片中的内容。");

            var parts = evidence.Sources;
            bool batch = parts.Count > 1;
            if (batch && (!client.SupportsPdfBatch || parts.Count > 24 || userImages.Length > 0))
                throw new InvalidDataException("此范围需要分段。请确认已使用科研桥 0.2.8，并缩小范围或移除图片后再试。");
            if (parts.Any(x => x != null) && userImages.Length > 0 && !client.SupportsUserImages)
                throw new InvalidDataException("当前科研桥不支持附图与文献联合问答。请更新至 0.2.8。");

            string id = await EnsureTurnSessionAsync(client, question, ct);
            PdfBatchJournal? journal = null;
            if (batch)
            {
                journal = OpenPdfBatch(id, question, choice, evidence);
                string kind = evidence.IsTranslation ? "分段翻译" : "分段分析与汇总";
                int maxCalls = evidence.IsTranslation ? parts.Count : parts.Count * 2;
                if (choice.Provider != "chatgpt" && MessageBox.Show(this,
                    $"{kind}最多发送 {maxCalls} 次模型请求，可能消耗账号余额。是否继续？",
                    "处理长篇 PDF", MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes)
                {
                    status.Text = "问题和材料已保留。";
                    return;
                }
            }
            await BindSessionModelAsync(client, id, choice, ct);
            streamSubscription = client.SubscribeResearchAsync(id, state => Dispatcher.InvokeAsync(async () =>
            {
                if (!streamCancellation.IsCancellationRequested && ReferenceEquals(connection, client) && session == id &&
                    Field(state, "message").ValueKind == JsonValueKind.Object && MergeStream(state))
                    await RenderAsync();
            }).Task.Unwrap(), streamCancellation.Token);

            async Task<string> SubmitAsync(SourceReceipt? original, string? guidance, PdFBatchPart? step = null)
            {
                ct.ThrowIfCancellationRequested();
                submitting = admitted = false;
                var prior = step != null ? journal!.Find(step.Key) : null;
                string requestId = prior ?? "dsh-pet-" + Guid.NewGuid();
                var source = original is null ? null : original with { RequestId = requestId };
                IReadOnlyList<SourceCrop> crops = [];
                if (step == null && source?.Pages.Any(page => page.VisualRegion != null) == true)
                {
                    crops = await PrepareCropsAsync(document!, source, client, choice, ct);
                    source = source with
                    {
                        Scope = (crops.Count > 0 ? "文档对象 · 原页裁图 · " : "文档对象 · 文字证据 · ") + source.Scope,
                        Text = crops.Count > 0 ? source.Text : "【此轮仅附文字摘录。请说明无法从文字核对的原页图形或公式。】\n" + source.Text,
                        Crops = crops.Select(crop => crop.Receipt).ToArray()
                    };
                }
                if (source?.Text.Length > 24_000) throw new InvalidDataException("本轮材料过长，请缩小范围。");
                limits.Check(userImages, crops);

                if (prior == null)
                {
                    bool imageOnly = source == null && userImages.Length != 0;
                    var request = Target(id);
                    request["selection"] = choice.Wire();
                    request["requestId"] = requestId;
                    request["text"] = question;
                    if (imageOnly)
                        request["images"] = await Task.Run(() => userImages.Select(x => x.Wire()).ToArray(), ct);
                    else
                    {
                        request["mode"] = "ask";
                        request["includeContext"] = source != null;
                        if (step == null && evidence.IsDiscussion && client.SupportsDiscussionEvidence)
                            request["evidencePolicy"] = "discussion";
                        if (guidance != null && client.SupportsPromptGuidance) request["guidance"] = guidance;
                        if (step != null) request["pdfBatch"] = step.Wire(journal!.BatchId);
                        if (source != null)
                        {
                            request["material"] = WireMaterial(source);
                            if (crops.Count > 0) request["images"] = await Task.Run(() => crops.Select(crop => crop.Wire()).ToArray(), ct);
                            if (userImages.Length != 0)
                                request["userImages"] = await Task.Run(() => userImages.Select(x => x.Wire()).ToArray(), ct);
                        }
                    }
                    status.Text = step?.Label ?? "正在提交给 DSH…";
                    if (source?.Pages.Count > 0 && document is { } attached) await attached.ValidateCurrentAsync(ct);
                    if (step != null) journal!.Remember(step.Key, requestId);
                    submitting = true;
                    JsonElement accepted;
                    try { accepted = await client.RequestAsync(imageOnly ? "prompt" : "researchPrompt", request, ct); }
                    catch (BridgeRequestException) { if (step != null) journal!.Forget(step.Key); throw; }
                    if (!Flag(accepted, "accepted"))
                        throw new InvalidDataException("科研桥未返回可确认的提交回执。");
                    admitted = true;
                    if (step == null)
                    {
                        composer.Clear();
                        draftImages.Clear();
                        SaveDraftImages();
                        UpdateDraftImagePanel();
                        SaveSettings();
                        ++jump;
                    }
                }
                else admitted = true; // An unresolved part is queried by its exact ID and is never dispatched again.
                status.Text = step?.Label ?? "已提交 · 等待回复";
                var deadline = DateTime.UtcNow.AddMinutes(step == null ? 6 : 10);
                var verify = Target(id);
                verify["requestId"] = requestId;
                while (DateTime.UtcNow < deadline)
                {
                    var reply = await client.RequestAsync("conversation", verify, ct);
                    if (source != null && VerifyDispatch(Field(reply, "dispatchEvidence"), source, choice, userImages.Length))
                    {
                        var verified = source with { DispatchVerified = true };
                        receipts[requestId] = verified;
                        SaveReceipt(id, verified, crops);
                        source = null;
                    }
                    lastConversation = reply;
                    MergeStream(Field(reply, "stream"));
                    var assistant = Array(reply, "messages").LastOrDefault(item =>
                        Text(item, "role") == "assistant" && Text(Field(item, "reply"), "requestId") == requestId);
                    var completed = Field(reply, "completedPart");
                    string? answer = step != null && Text(completed, "requestId") == requestId
                        ? Text(completed, "text") : Text(assistant, "text");
                    if (assistant.ValueKind == JsonValueKind.Object) activeStream = default;
                    await RenderAsync();
                    if (!Flag(reply, "running") && !string.IsNullOrWhiteSpace(answer)) return answer;
                    if (!Flag(reply, "running") && Text(reply, "error") is string failure)
                        throw new InvalidOperationException("DSH 返回错误 · " + failure);
                    await Task.Delay(850, ct);
                }
                throw new TimeoutException("等待完整回复超时。请核对 DSH 会话状态后继续。");
            }

            if (journal != null)
            {
                await RunBatchAsync(evidence, SubmitAsync, ct);
                journal.Complete();
                composer.Clear();
                SaveSettings();
                ++jump;
                await RenderAsync();
            }
            else
            {
                await SubmitAsync(parts[0], evidence.Guidance);
            }
            status.Text = evidence.MissingDocumentEvidence ? "回复完成 · 本轮未取得可核对的文件摘录" : "回复完成";
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
        catch (Exception error) when (submitting || admitted)
        {
            if (!admitted) blockedSession = session;
            status.Text = (admitted ? "已提交，后续读取失败 · " : "提交状态无法确认 · ") + error.Message;
        }
        finally
        {
            streamCancellation.Cancel();
            try
            {
                if (streamSubscription != null) await streamSubscription;
            }
            catch (Exception error) when (error is IOException or OperationCanceledException or TimeoutException or JsonException) { }
            finally
            {
                waiting = null;
                SetBusy(false);
            }
        }
    }

    private async Task<string> EnsureTurnSessionAsync(BridgeClient client, string question, CancellationToken ct)
    {
        if (session is { } existing)
        {
            var current = await client.RequestAsync("conversation", Target(existing), ct);
            if (Flag(current, "running")) throw new InvalidOperationException("此会话仍在运行，请等待当前任务完成。");
            return existing;
        }
        var createdId = Guid.NewGuid().ToString();
        var fields = Target(createdId);
        fields["title"] = PlainLabel(question, 80);
        var created = await client.RequestAsync("createSession", fields, ct);
        if (Text(created, "sessionId") != createdId) throw new InvalidDataException("科研桥返回了不同的会话标识。");
        var draftRecovery = RecoveryFor(null);
        var oldImages = DraftImagePath(null);
        session = createdId;
        SaveSessionFile();
        draftRecovery?.Update(state => state with { File = null });
        if (draftImages.Count != 0)
        {
            SaveDraftImages();
            if (oldImages != null)
            {
                try { File.Delete(oldImages); }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
            }
        }
        SaveSettings();
        return createdId;
    }

    private bool MergeStream(JsonElement state)
    {
        int? revision = Field(state, "revision").TryReadInt();
        if (revision == null || revision < streamRevision) return false;
        var message = Field(state, "message");
        if (revision == streamRevision && message.ValueKind != JsonValueKind.Null) return false;
        streamRevision = revision.Value;
        activeStream = message;
        return true;
    }

    private static async Task<IReadOnlyList<SourceCrop>> PrepareCropsAsync(PdfEvidence file, SourceReceipt source,
        BridgeClient client, ModelChoice choice, CancellationToken cancellationToken)
    {
        if (!choice.SupportsImages || !client.SupportsDocumentImages) return [];
        var limits = client.AttachmentLimits;
        if (!Array(limits, "mediaTypes").Any(item => item.ValueKind == JsonValueKind.String && item.GetString() == "image/png"))
            return [];
        int maxImages = Math.Min(4, Field(limits, "maxImagesPerMessage").TryReadInt() ?? 0);
        int maxImageBytes = Field(limits, "maxImageBytes").TryReadInt() ?? 0;
        int maxTotalBytes = Field(limits, "maxMessageImageBytes").TryReadInt() ?? 0;
        var regions = source.Pages.Where(page => page.VisualRegion != null).ToList();
        if (regions.Count > maxImages)
            throw new InvalidDataException("本轮原页裁图超过模型限制，请缩小问题范围。");
        var crops = new List<SourceCrop>();
        long total = 0;
        foreach (var page in regions)
        {
            var preview = await file.RenderCropAsync(page.Page, page.VisualRegion!.Value, cancellationToken);
            var crop = await Task.Run(() =>
            {
                var bitmap = BitmapSource.Create(preview.Width, preview.Height, 96, 96,
                    PixelFormats.Bgr32, null, preview.Pixels, preview.Stride);
                var encoder = new PngBitmapEncoder();
                encoder.Frames.Add(BitmapFrame.Create(bitmap));
                using var encoded = new MemoryStream();
                encoder.Save(encoded);
                var bytes = encoded.ToArray();
                return new SourceCrop(new CropReceipt(page.Page, Convert.ToHexStringLower(SHA256.HashData(bytes))), bytes);
            }, cancellationToken);
            total += crop.Bytes.Length;
            if (crop.Bytes.Length > maxImageBytes || total > maxTotalBytes)
                throw new InvalidDataException("原页裁图超过 DSH 图像大小限制，请缩小问题范围。");
            crops.Add(crop);
        }
        return crops;
    }

    private static bool VerifyDispatch(JsonElement proof, SourceReceipt source, ModelChoice choice, int userImages) =>
        Text(proof, "requestId") == source.RequestId &&
        string.Equals(Text(proof, "sha256"), Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(source.Text))), StringComparison.OrdinalIgnoreCase) &&
        Field(proof, "utf16Length").TryReadInt() == source.Text.Length &&
        Text(Field(proof, "selection"), "provider") == choice.Provider &&
        Text(Field(proof, "selection"), "model") == choice.Model &&
        Text(Field(proof, "selection"), "reasoningEffort") == choice.Effort &&
        Array(proof, "userImages").Count() == userImages &&
        (source.Crops is not { Count: > 0 } crops ||
            Array(proof, "sourceImages").Select(item => item.ValueKind == JsonValueKind.String ? item.GetString() : null)
                .SequenceEqual(crops.Select(crop => crop.Sha256), StringComparer.OrdinalIgnoreCase) &&
            Array(proof, "images").Count() == crops.Count);

    private async Task OpenSessionAsync(string? id)
    {
        if (busy) return;
        drafts[session ?? "empty"] = composer.Text;
        session = id;
        activeStream = default;
        streamRevision = -1;
        ClearDocument();
        selection = null;
        draftImages.Clear();
        UpdateDraftImagePanel();
        chosenModel = null;
        lastConversation = default;
        receipts.Clear();
        composer.Text = drafts.GetValueOrDefault(id ?? "empty", "");
        SaveSettings();
        UpdateModelButton();
        UpdateMaterial();
        ++jump;
        SetBusy(true);
        try
        {
            if (id != null) await RefreshCurrentConversationAsync();
            await RestoreSessionFileAsync();
            await RestoreDraftImagesAsync(lifetime.Token);
            await RenderAsync();
        }
        finally { SetBusy(false); }
    }

    private async Task RefreshCurrentConversationAsync()
    {
        if (session == null || connection == null) return;
        lastConversation = await connection.RequestAsync("conversation", Target(session), lifetime.Token);
        if (Text(lastConversation, "historyRevision") == null) throw new InvalidDataException("没有可用的会话数据。");
        if (chosenModel == null) RestoreSessionModel(lastConversation);
        MergeStream(Field(lastConversation, "stream"));
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
                rows.Add(new(id, role, Flag(entry, "plainQuestion") ? text : DisplayQuestion(text), Original: text));
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
        if (Text(activeStream, "role") == "assistant" && Text(activeStream, "id") is string streamId &&
            Text(activeStream, "text") is { Length: > 0 } partial && !rows.Any(row => row.Id == "assistant:" + streamId))
            rows.Add(new("assistant:" + streamId, "assistant", partial, Streaming: true));
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
                else if (source.Source.Pages.Count > 0) await OpenVerifiedDocumentSourceAsync(source.Source);
                else if (CleanSourceUrl(source.Source.Url) is string address) OpenExternal(address);
                else if (ZoteroLink(source.Source.AppSourceLink) is string zotero)
                    selectionProvider.OpenZoteroSource(zotero, source.Source.ZoteroPairingId);
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
        var content = new DockPanel();
        if (session != null && source.Crops is { Count: > 0 })
        {
            var toolbar = new WrapPanel { Margin = new Thickness(12, 8, 12, 0) };
            foreach (var crop in source.Crops)
            {
                var button = new Button { Content = $"原页裁图 · 第 {crop.Page} 页", Margin = new Thickness(0, 0, 6, 0) };
                string receiptPath = ReceiptPath(session, source.RequestId);
                button.Click += async (_, _) => await RunUiAsync(() => ShowSavedCropAsync(source.Title, receiptPath, crop));
                toolbar.Children.Add(button);
            }
            DockPanel.SetDock(toolbar, Dock.Top);
            content.Children.Add(toolbar);
        }
        content.Children.Add(area);
        Dialog(source.Title, content, 620, 525).ShowDialog();
    }

    private async Task ShowSavedCropAsync(string title, string receiptPath, CropReceipt crop)
    {
        var path = CropPath(receiptPath, crop);
        if (!File.Exists(path) || new FileInfo(path).Length > 16 * 1024 * 1024)
            throw new InvalidDataException("已核对的原页裁图不可用。");
        var bytes = await File.ReadAllBytesAsync(path, lifetime.Token);
        if (!string.Equals(Convert.ToHexString(SHA256.HashData(bytes)), crop.Sha256, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("本地裁图已变化，无法核对。");
        using var data = new MemoryStream(bytes);
        var decoder = new PngBitmapDecoder(data, BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnLoad);
        var preview = new Image { Source = decoder.Frames[0], Stretch = Stretch.Uniform, Margin = new Thickness(12) };
        Dialog(title + $" · 文件第 {crop.Page} 页裁图", preview, 740, 660).ShowDialog();
    }

    private async Task OpenDocumentSourceAsync(SourceReceipt source)
    {
        DocumentExcerpt excerpt = source.Pages[0];
        var file = await PdfEvidence.OpenAsync(excerpt.FilePath, lifetime.Token);
        if (file.Fingerprint != excerpt.Fingerprint)
            throw new InvalidDataException("本地原文已变化，无法复用当时的页位。请查看已保存的摘录。");
        if (!file.IsPdf) { ShowSourceExcerpt(source); return; }
        ShowDocumentPages(file, source.Pages);
    }

    private void ShowDocumentPages(PdfEvidence file, IReadOnlyList<DocumentExcerpt>? excerpts)
    {
        IEnumerable<int> pages = excerpts == null
            ? Enumerable.Range(1, file.PageCount) : excerpts.Select(excerpt => excerpt.Page);
        var picker = new ComboBox
        {
            Margin = new Thickness(12), ItemsSource = pages.ToList(), ItemStringFormat = "文件第 {0} 页",
            Foreground = ColorBrush("#182235")
        };
        AutoLabel(picker, "PDF 页码");
        var canvasHost = new ScrollViewer { HorizontalScrollBarVisibility = ScrollBarVisibility.Auto };
        var box = new DockPanel();
        DockPanel.SetDock(picker, Dock.Top);
        box.Children.Add(picker);
        box.Children.Add(canvasHost);
        var dialog = Dialog(file.Title, box, 790, 790);
        using var closing = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        int revision = 0;
        picker.SelectionChanged += async (_, _) =>
        {
            if (picker.SelectedItem is not int pageNumber) return;
            var requested = excerpts?[picker.SelectedIndex];
            int attempt = ++revision;
            try
            {
                var page = await file.RenderPageAsync(pageNumber, 1060, closing.Token);
                if (closing.IsCancellationRequested || revision != attempt) return;
                double width = Math.Min(page.Width, Math.Max(320, dialog.ActualWidth > 0 ? dialog.ActualWidth - 38 : 740));
                double height = width * page.Height / page.Width;
                var canvas = new Canvas { Width = width, Height = height };
                canvas.Children.Add(new Image { Source = BitmapSource.Create(page.Width, page.Height, 96, 96,
                    PixelFormats.Bgr32, null, page.Pixels, page.Stride), Width = width, Height = height });
                IReadOnlyList<PdfRegion> regions = requested?.VisualRegion is PdfRegion visual
                    ? [visual] : requested?.Regions ?? [];
                foreach (var region in regions)
                {
                    var mark = new System.Windows.Shapes.Rectangle
                    {
                        Fill = new SolidColorBrush(Color.FromArgb(73, 255, 204, 64)),
                        Width = region.Width * width, Height = region.Height * height
                    };
                    Canvas.SetLeft(mark, region.X * width);
                    Canvas.SetTop(mark, region.Y * height);
                    canvas.Children.Add(mark);
                }
                canvasHost.Content = canvas;
                canvasHost.ScrollToTop();
                if (regions.Count > 0)
                    canvasHost.ScrollToVerticalOffset(Math.Max(0, regions[0].Y * height - 100));
            }
            catch (OperationCanceledException) when (closing.IsCancellationRequested) { }
            catch (Exception error)
            {
                if (!closing.IsCancellationRequested && revision == attempt)
                    canvasHost.Content = new TextBlock { Text = error.Message, TextWrapping = TextWrapping.Wrap };
            }
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

    private void SaveReceipt(string id, SourceReceipt receipt, IReadOnlyList<SourceCrop> crops)
    {
        string path = ReceiptPath(id, receipt.RequestId);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        foreach (var crop in crops)
            WriteReceiptFile(CropPath(path, crop.Receipt), crop.Bytes);
        WriteReceiptFile(path, JsonSerializer.SerializeToUtf8Bytes(receipt));
    }

    private static string CropPath(string receiptPath, CropReceipt crop)
    {
        if (crop.Sha256.Length != 64 || !crop.Sha256.All(Uri.IsHexDigit))
            throw new InvalidDataException("原页裁图校验值无效。");
        return Path.ChangeExtension(receiptPath, $"-{crop.Sha256.ToLowerInvariant()}.png");
    }

    private static void WriteReceiptFile(string path, byte[] bytes)
    {
        string temporary = path + ".new";
        File.WriteAllBytes(temporary, bytes);
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
