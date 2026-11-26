using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace ResearchCompanion.Windows;

internal sealed record SavedResearchModel(string Provider, string Model, string? Effort)
{
    internal bool Matches(string? provider, string? model, string? effort) =>
        Provider == provider && Model == model && Effort == effort;
}

internal sealed record SavedResearchFile(string Path, string Fingerprint, bool RecognizeScans, bool Include);

internal sealed record SavedResearchSession(SavedResearchModel? Model = null, SavedResearchFile? File = null);

internal sealed class SessionRecovery(string directory, string host, string workspace, string? session)
{
    private const int MaxBytes = 16 * 1024;

    private string FilePath
    {
        get
        {
            byte[] key = JsonSerializer.SerializeToUtf8Bytes(new[] { host, workspace, session });
            return Path.Combine(directory, Convert.ToHexStringLower(SHA256.HashData(key)) + ".json");
        }
    }

    internal SavedResearchSession Read()
    {
        try
        {
            string path = FilePath;
            using var file = File.Open(path, FileMode.Open, FileAccess.Read, FileShare.Read);
            return file.Length > MaxBytes ? new() : JsonSerializer.Deserialize<SavedResearchSession>(file) ?? new();
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException)
        {
            return new();
        }
    }

    internal void Update(Func<SavedResearchSession, SavedResearchSession> change)
    {
        try
        {
            var state = change(Read());
            if (state.Model == null && state.File == null)
            {
                File.Delete(FilePath);
                return;
            }
            Directory.CreateDirectory(directory);
            string path = FilePath;
            string temporary = path + ".new";
            File.WriteAllBytes(temporary, JsonSerializer.SerializeToUtf8Bytes(state));
            File.Move(temporary, path, overwrite: true);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            System.Diagnostics.Trace.TraceWarning("Could not save local research session recovery.");
        }
    }

    internal static Task<PdfEvidence> OpenFileAsync(SavedResearchFile saved,
        Func<PagePreview, CancellationToken, Task<IReadOnlyList<PdfOcrLine>>> recognize, CancellationToken ct) =>
        Task.Run(async () =>
        {
            if (!IsLocalRegularFile(saved.Path))
                throw new InvalidDataException("已关联文件不再是本机可核对的文件。");
            var reopened = await PdfEvidence.OpenAsync(saved.Path, ct, recognize).ConfigureAwait(false);
            if (reopened.Fingerprint != saved.Fingerprint || !IsLocalRegularFile(saved.Path))
                throw new InvalidDataException("已关联文件内容已更新。");
            if (saved.RecognizeScans && reopened.IsPdf)
                await reopened.RecognizeMissingPagesAsync(cancellationToken: ct).ConfigureAwait(false);
            return reopened;
        }, ct);

    private static bool IsLocalRegularFile(string path)
    {
        if (string.IsNullOrWhiteSpace(path) || !Path.IsPathFullyQualified(path)) return false;
        string? root = Path.GetPathRoot(path);
        if (root is not { Length: 3 } || !char.IsAsciiLetter(root[0]) || root[1] != ':' ||
            root[2] != Path.DirectorySeparatorChar || path.AsSpan(2).Contains(':') ||
            !string.Equals(Path.GetFullPath(path), path, StringComparison.OrdinalIgnoreCase) ||
            new DriveInfo(root).DriveType != DriveType.Fixed)
            return false;

        var info = new FileInfo(path);
        if (!info.Exists || (info.Attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint | FileAttributes.Device)) != 0)
            return false;

        for (var parent = info.Directory; parent != null; parent = parent.Parent)
        {
            if (!parent.Exists || (parent.Attributes & FileAttributes.ReparsePoint) != 0)
                return false;
        }
        return true;
    }
}
