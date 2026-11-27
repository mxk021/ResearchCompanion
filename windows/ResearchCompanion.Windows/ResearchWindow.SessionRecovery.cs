using System;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;

namespace ResearchCompanion.Windows;

internal sealed partial class ResearchWindow
{
    private bool documentOcrRequested;
    private bool attachedFileNeedsReview;
    private SavedZoteroAttachment? zoteroDocument;

    private SessionRecovery? RecoveryFor(string? id) =>
        connection?.RecoveryHost is string host && workspace is string workspaceId
            ? new(Path.Combine(App.Profile, "SessionRecovery"), host, workspaceId, id) : null;

    private static bool Matches(ModelChoice model, JsonElement bound) =>
        Text(bound, "provider") == model.Provider && Text(bound, "model") == model.Model &&
        Text(bound, "reasoningEffort") == model.Effort;

    private void RestoreSessionModel(JsonElement conversation)
    {
        if (session == null || RecoveryFor(session) is not { } recovery) return;
        var selected = Field(conversation, "selection");
        var offered = models.FirstOrDefault(model => Matches(model, selected));
        if (offered == null) return;
        if (offered.Provider != "deepseek-account" ||
            recovery.Read().Model?.Matches(offered.Provider, offered.Model, offered.Effort) == true)
        {
            chosenModel = offered;
            UpdateModelButton();
        }
    }

    private async Task ChooseSessionModelAsync(ModelChoice model)
    {
        if (busy || connection is not { } client) return;
        if (model.Provider == "deepseek-account" && MessageBox.Show(this,
            "是否为本会话使用 DeepSeek 账号模型？请求可能消耗账号余额。",
            "选择模型", MessageBoxButton.YesNo) != MessageBoxResult.Yes)
            return;
        SetBusy(true);
        try
        {
            if (session is string id) await BindSessionModelAsync(client, id, model, lifetime.Token);
            chosenModel = model;
            UpdateModelButton();
        }
        finally { SetBusy(false); }
    }

    private async Task BindSessionModelAsync(BridgeClient client, string id, ModelChoice model, CancellationToken ct)
    {
        var request = Target(id);
        request["selection"] = model.Wire();
        var response = await client.RequestAsync("researchSelectModel", request, ct);
        if (!Matches(model, Field(response, "selected")))
            throw new InvalidDataException("科研桥未确认所选会话模型，请重新选择。");
        RecoveryFor(id)?.Update(state => state with { Model = new(model.Provider, model.Model, model.Effort) });
    }

    private void ClearDocument()
    {
        document = null;
        zoteroDocument = null;
        attachedFileNeedsReview = false;
        documentOcrRequested = false;
    }

    private void SaveSessionFile()
    {
        if (document is not { } file) return;
        RecoveryFor(session)?.Update(state => state with
        {
            File = new(file.FilePath, file.Fingerprint, documentOcrRequested, include.IsChecked == true, zoteroDocument)
        });
    }

    private async Task RemoveSessionFileAsync()
    {
        ClearDocument();
        RecoveryFor(session)?.Update(state => state with { File = null });
        UpdateMaterial();
        await RenderAsync();
    }

    private async Task RestoreSessionFileAsync()
    {
        if (RecoveryFor(session)?.Read().File is not { } saved || document != null) return;
        zoteroDocument = saved.Zotero;
        try
        {
            status.Text = "正在核对会话已关联的文件…";
            var file = await SessionRecovery.OpenFileAsync(saved, WindowsPdfOcr.RecognizeAsync, lifetime.Token);
            include.IsChecked = saved.Include;
            document = file;
            documentOcrRequested = saved.RecognizeScans;
            attachedFileNeedsReview = false;
            status.Text = "已恢复会话及原文件。";
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException
            or NotSupportedException or COMException or InvalidOperationException)
        {
            attachedFileNeedsReview = true;
            include.IsChecked = saved.Include;
            status.Text = "无法核对已关联文件。请重新选择或移除此材料。";
        }
        UpdateMaterial();
    }

    private async Task AssociateZoteroDocumentAsync(WindowsZoteroPdf? locator)
    {
        if (locator == null || selection?.ZoteroPairingId is not { } pairing)
        {
            if (zoteroDocument != null) await RemoveSessionFileAsync();
            status.Text = "已读取 Zotero 选区。未自动关联本机 PDF。";
            return;
        }

        var association = new SavedZoteroAttachment(locator.Library, locator.AttachmentKey, locator.AttachmentId, pairing);
        bool sameFile = document?.IsPdf == true &&
            string.Equals(document.FilePath, locator.FilePath, StringComparison.OrdinalIgnoreCase);
        bool recognizeScans = sameFile && documentOcrRequested;
        try
        {
            status.Text = "正在核对 Zotero 的本机 PDF…";
            bool reuse = sameFile && locator.MatchesFile();
            if (reuse)
            {
                try { await document!.ValidateCurrentAsync(lifetime.Token); }
                catch (InvalidDataException) { reuse = false; }
            }
            if (!reuse)
            {
                var indexed = await locator.OpenAsync(lifetime.Token, WindowsPdfOcr.RecognizeAsync);
                if (recognizeScans) await indexed.RecognizeMissingPagesAsync(cancellationToken: lifetime.Token);
                document = indexed;
            }
            documentOcrRequested = recognizeScans;
            attachedFileNeedsReview = false;
            zoteroDocument = association;
            include.IsChecked = true;
            SaveSessionFile();
            status.Text = "已读取 Zotero 选区并关联同一 PDF。";
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException
            or NotSupportedException or COMException or InvalidOperationException)
        {
            if (zoteroDocument != null) await RemoveSessionFileAsync();
            status.Text = "已读取 Zotero 选区。无法核对该附件，请检查本机 PDF。";
        }
    }
}
