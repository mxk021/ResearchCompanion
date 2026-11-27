using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;
using System.Threading.Tasks;

namespace ResearchCompanion.Windows;

/// <summary>A local locator bound by Zotero to the authenticated selection.</summary>
public sealed record WindowsZoteroPdf(string Library, string AttachmentKey, long AttachmentId, string FilePath,
    long Bytes, long ModifiedMs)
{
    private const string Changed = "Zotero 取词后文件版本已变化或无法读取，请重新取词。";

    internal static string? LocalPath(string? path)
    {
        if (path is not { Length: >= 7 and <= 4096 } || !char.IsAsciiLetter(path[0]) || path[1] != ':' ||
            path[2] is not ('\\' or '/') || !path.EndsWith(".pdf", StringComparison.OrdinalIgnoreCase))
            return null;

        foreach (var character in path.AsSpan(2))
        {
            if (char.IsControl(character) || character is ':' or '<' or '>' or '|' or '?' or '*' or '"')
                return null;
        }

        var result = path.Replace('/', '\\');
        foreach (var part in result[3..].Split('\\'))
        {
            if (part.Length == 0 || part[^1] is '.' or ' ')
                return null;
        }
        return result;
    }

    internal bool MatchesFile()
    {
        if (LocalPath(FilePath) is not { } path || Bytes <= 0) return false;
        try
        {
            if (new DriveInfo(path[..3]).DriveType is not
                (DriveType.Fixed or DriveType.Removable or DriveType.CDRom or DriveType.Ram))
                return false;

            for (string? item = path; item is not null; item = Path.GetDirectoryName(item))
            {
                if ((File.GetAttributes(item) & FileAttributes.ReparsePoint) != 0)
                    return false;
            }

            var info = new FileInfo(path);
            if (!info.Exists || info.Length != Bytes) return false;
            var timestamp = new DateTimeOffset(info.LastWriteTimeUtc).ToUnixTimeMilliseconds();
            return ModifiedMs >= timestamp - 1 && ModifiedMs <= timestamp + 1;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            return false;
        }
    }

    internal async Task<PdfEvidence> OpenAsync(CancellationToken cancellationToken,
        Func<PagePreview, CancellationToken, Task<IReadOnlyList<PdfOcrLine>>>? recognizer = null)
    {
        await VerifyAsync(cancellationToken).ConfigureAwait(false);
        var result = await PdfEvidence.OpenAsync(FilePath, cancellationToken, recognizer).ConfigureAwait(false);
        await VerifyAsync(cancellationToken).ConfigureAwait(false);
        return result;
    }

    private Task VerifyAsync(CancellationToken cancellationToken) => Task.Run(() =>
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!MatchesFile()) throw new InvalidDataException(Changed);
    }, cancellationToken);
}
