using System;
using System.Collections.Generic;
using System.Text.Json.Serialization;
using System.Threading.Tasks;

namespace ResearchCompanion.Windows;

internal sealed record TranscriptRow(string Id, string Role, string Text, bool CanOpenSource = false,
    string? SourceDisplay = null, string? SourceTitle = null, string? SourcePage = null,
    string? SourceDetails = null, string? SourceWarning = null, string? Original = null, bool Streaming = false)
{
    [JsonPropertyName("appendAfterUTF16")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public int? AppendAfterUtf16 { get; init; }
}

internal sealed record TranscriptPatch(string Session, IReadOnlyList<TranscriptRow> Rows, int Jump,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] IReadOnlyList<string>? Order,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? EmptyGuidance);

// The window owns this queue on its dispatcher. Only a successful WebView
// update advances the base for the next patch.
internal sealed class TranscriptDelivery(Func<TranscriptPatch, Task<bool>> send)
{
    private Snapshot? requested;
    private Snapshot? applied;
    private Task? inFlight;
    private int generation;
    private bool ready;

    internal Task PushAsync(string session, IReadOnlyList<TranscriptRow> rows, string emptyGuidance, int jump)
    {
        requested = new(session, rows, emptyGuidance, jump);
        return ProcessAsync();
    }

    internal Task ReadyAsync()
    {
        ready = true;
        return ProcessAsync();
    }

    internal void Reset()
    {
        ready = false;
        applied = null;
        generation++;
    }

    private Task ProcessAsync()
    {
        if (!ready || requested == null) return Task.CompletedTask;
        if (inFlight is { IsCompleted: false }) return inFlight;
        return inFlight = DrainAsync();
    }

    private async Task DrainAsync()
    {
        while (ready && requested is { } target && !ReferenceEquals(target, applied))
        {
            var document = generation;
            var patch = target.ChangesAfter(applied);
            if (patch != null)
            {
                bool accepted = await SendAsync(patch, document);
                if (document != generation) continue;
                if (!accepted)
                {
                    // A rejected continuation must be replayed from full text.
                    // Include the latest request if it arrived during delivery.
                    target = requested!;
                    accepted = await SendAsync(target.ChangesAfter(null)!, document);
                    if (document != generation) continue;
                    if (!accepted)
                    {
                        applied = null;
                        throw new InvalidOperationException("会话内容未能显示。请刷新会话后重试。");
                    }
                }
            }
            applied = target;
        }
    }

    private async Task<bool> SendAsync(TranscriptPatch patch, int document)
    {
        try { return await send(patch); }
        catch (Exception) when (document != generation) { return false; }
        catch
        {
            applied = null;
            throw;
        }
    }

    private sealed record Snapshot(string Session, IReadOnlyList<TranscriptRow> Rows, string EmptyGuidance, int Jump)
    {
        internal TranscriptPatch? ChangesAfter(Snapshot? previous)
        {
            if (previous?.Session != Session) previous = null;
            var earlierRows = new Dictionary<string, TranscriptRow>(StringComparer.Ordinal);
            if (previous != null)
            {
                foreach (var row in previous.Rows)
                    earlierRows[row.Id] = row;
            }

            var changed = new List<TranscriptRow>();
            bool orderChanged = previous == null || Rows.Count != previous.Rows.Count;
            for (var i = 0; i < Rows.Count; i++)
            {
                var row = Rows[i];
                if (!orderChanged && previous!.Rows[i].Id != row.Id) orderChanged = true;
                if (!earlierRows.TryGetValue(row.Id, out var before))
                {
                    changed.Add(row);
                    continue;
                }
                if (before == row) continue;
                if (row.Streaming && before.Streaming && before.Text.Length > 0 &&
                    before.Text.Length < row.Text.Length && !char.IsHighSurrogate(before.Text[^1]) &&
                    row.Text.StartsWith(before.Text, StringComparison.Ordinal))
                {
                    changed.Add(row with { Text = row.Text[before.Text.Length..], AppendAfterUtf16 = before.Text.Length });
                    continue;
                }
                changed.Add(row);
            }

            string? guidance = previous?.EmptyGuidance == EmptyGuidance ? null : EmptyGuidance;
            if (changed.Count == 0 && !orderChanged && guidance == null && previous?.Jump == Jump) return null;
            string[]? order = null;
            if (orderChanged)
            {
                order = new string[Rows.Count];
                for (var i = 0; i < Rows.Count; i++) order[i] = Rows[i].Id;
            }
            return new(Session, changed, Jump, order, guidance);
        }
    }
}
