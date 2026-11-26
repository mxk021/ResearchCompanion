using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace ResearchCompanion.Windows;

// Page rectangles are normalized to the top-left of PDFium's rendered crop box.
internal readonly record struct PdfRegion(double X, double Y, double Width, double Height)
{
    internal double Right => X + Width;
    internal double Bottom => Y + Height;
}

internal sealed record DocumentExcerpt(
    string FilePath, string Title, int Page, string Text, IReadOnlyList<PdfRegion> Regions, string Fingerprint,
    PdfRegion? VisualRegion = null, string? Recognition = null);

internal sealed record PdfOcrLine(string Text, PdfRegion Region);
internal sealed record PdfOcrProgress(int Page, int PageCount);
internal sealed record PdfOcrResult(int MissingPages, int RecognizedPages);

internal sealed record PagePreview(int Page, int Width, int Height, int Stride, byte[] Pixels);

internal sealed class PdfEvidence
{
    private const int MaxFileBytes = 120 * 1024 * 1024;
    private const int MaxTextFileBytes = 4 * 1024 * 1024;
    private const int MaxPages = 600;
    private const int MaxPageCharacters = 120_000;
    private const int MaxIndexedCharacters = 2_000_000;
    private const int MaxExcerpt = 48_000;
    private const int MaxPageRange = 16;
    private static readonly object NativeLock = new();
    private static bool initialized;

    private static readonly Regex Anchors = Pattern(
        """(?:从|\bfrom\s+)\s*[“「"](?<start>[^”」"]+)[”」"]\s*(?:到|至|\bto\b|\bthrough\b)\s*[“「"](?<end>[^”」"]+)[”」"]""");
    private static readonly Regex PageAddress = Pattern(
        """(?:第\s*)?(?<first>\d{1,4})(?:\s*(?:页\s*)?[-–—到至]\s*(?:第\s*)?(?<last>\d{1,4}))?\s*页|\b(?:pages?\s+|p\.\s*)(?<first>\d{1,4})(?:\s*(?:[-–—]|to|through)\s*(?<last>\d{1,4}))?(?!\d)""");
    private static readonly Regex PageAliases = Pattern("""(?<first>首页|第一页|\bfirst\s+page\b)|末页|最后一页|\blast\s+page\b""");
    private static readonly Regex DisjointPages = Pattern(
        """\d(?:\s*页)?\s*(?:[,，、]|[和及与])\s*(?:第\s*)?\d{1,4}\s*页|\bpages?\s+\d{1,4}\s*(?:,|and)\s*\d""");
    private static readonly Regex UnsupportedAddress = Pattern(
        """\b(?:page|pages)\s+(?:\d|[ivxlcdm]+\b)|第\s*[〇零一二三四五六七八九十百千两\d]+\s*页|上[一]?页|下[一]?页|\b(?:previous|next|following)\s+page\b|\b(?:section|chapter)\s+\d|第[〇零一二三四五六七八九十百千两\d]+[章节]""");
    private static readonly Regex UnparsedRange = Pattern(
        """从[^\n。]{3,}(?:到|至)[^\n。]{3,}|\bfrom\s+.{3,}\s+(?:to|through)\s+.{3,}""");
    private static readonly Regex VisualObject = Pattern(
        """(?:图表|图注|子图|原图|公式|原式|数学式|方程)|(?:图|表|式)\s*[A-Za-z]?[（(]?\s*[\d一二三四五六七八九十]|\b(?:figure|fig\.|eq\.|equation|formula|table|caption)\s*[A-Za-z]?\s*[\d(]""");
    private static readonly Regex NumberedObject = Pattern(
        @"(?<type>\bfig(?:ure)?\.?|\btable|\beq(?:uation)?\.?|[图表式]|公式|方程)\s*[（(]?(?<id>[A-Za-z]?\d+(?:[.-]\d+)*)(?![A-Za-z0-9]|[.-]\d)");
    private static readonly Regex EquationTag = Pattern(@"[（(]\s*(?<id>[A-Za-z]?\d+(?:[.-]\d+)*)\s*[)）]\s*$");
    private static readonly Regex EquationInk = Pattern(@"[=≈≡≤≥∑∫√×÷]");
    private static readonly Regex LeftColumn = Pattern(@"左\s*(?:侧|边)?\s*栏|\bleft(?:[- ]hand)?\s+column\b");
    private static readonly Regex RightColumn = Pattern(@"右\s*(?:侧|边)?\s*栏|\bright(?:[- ]hand)?\s+column\b");
    private static readonly Regex Terms = Pattern(@"[\p{IsCJKUnifiedIdeographs}]+|[\p{L}\p{N}]{2,}");
    private static readonly Regex Summary = Pattern(@"总结|概述|摘要|主要内容|讲了什么|\bsummari[sz](?:e|ation)\b|\bsummary\b");
    private static readonly HashSet<string> StopWords = new(StringComparer.OrdinalIgnoreCase)
    {
        "the", "and", "for", "what", "about", "how", "why", "this", "does", "with", "of", "is", "to",
        "in", "it", "please", "extract", "quote", "explain", "describe", "translate", "these", "document",
        "请问", "请说", "论文", "文献", "解释", "说明", "翻译", "根据", "如何", "为什么",
        "什么", "本文", "文中", "问题", "看看", "介绍", "哪些", "是否", "原文", "请解", "给出"
    };

    private readonly byte[] bytes;
    private readonly PageText?[] pages;
    private readonly object indexLock = new();
    private readonly SemaphoreSlim recognitionLock = new(1, 1);
    private Func<PagePreview, CancellationToken, Task<IReadOnlyList<PdfOcrLine>>>? recognizer;
    private int cachedCharacters;

    private PdfEvidence(string filePath, string title, byte[] bytes, int pageCount, bool isPdf)
    {
        FilePath = filePath;
        Title = title;
        Fingerprint = Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
        this.bytes = bytes;
        pages = new PageText[pageCount];
        IsPdf = isPdf;
    }

    public string FilePath { get; }
    public string Title { get; }
    public string Fingerprint { get; }
    public int PageCount => pages.Length;
    public bool IsPdf { get; }

    public static async Task<PdfEvidence> OpenAsync(string path, CancellationToken cancellationToken = default,
        Func<PagePreview, CancellationToken, Task<IReadOnlyList<PdfOcrLine>>>? recognize = null)
    {
        var file = await Task.Run(() => Open(path, cancellationToken), cancellationToken).ConfigureAwait(false);
        file.recognizer = recognize;
        return file;
    }

    public async Task<PdfOcrResult> RecognizeMissingPagesAsync(IProgress<PdfOcrProgress>? progress = null,
        CancellationToken cancellationToken = default)
    {
        if (!IsPdf || recognizer == null) throw new InvalidDataException("没有可用的本机 PDF OCR。");
        await recognitionLock.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await Task.Run(() => VerifyFile(cancellationToken), cancellationToken).ConfigureAwait(false);
            int missing = 0;
            int recognized = 0;
            for (int number = 1; number <= PageCount; number++)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var page = await Task.Run(() => ReadPages(number, number, cancellationToken)[0], cancellationToken).ConfigureAwait(false);
                progress?.Report(new(number, PageCount));
                if (page.Recognition != null)
                {
                    missing++;
                    recognized++;
                    continue;
                }
                if (page.Text.Any(char.IsLetterOrDigit)) continue;
                missing++;
                var bitmap = await Task.Run(() => WithPdf(bytes, pdf => Render(pdf, number, 2200, cancellationToken), cancellationToken),
                    cancellationToken).ConfigureAwait(false);
                var lines = await recognizer(bitmap, cancellationToken).ConfigureAwait(false);
                var contents = lines.Where(line => !string.IsNullOrWhiteSpace(line.Text) && ValidRegion(line.Region))
                    .Select(line => new LineContent(line.Text.Trim(), line.Region, false)).ToArray();
                if (contents.Length == 0) continue;
                var ocr = OrderPage(number, contents, false) with { Recognition = "本机 OCR，需核对原页" };
                if (ocr.Text.Length is 0 or > MaxPageCharacters) continue;
                lock (indexLock)
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    int prior = pages[number - 1]?.Text.Length ?? 0;
                    if (cachedCharacters - prior + ocr.Text.Length > MaxIndexedCharacters)
                        throw new InvalidDataException("OCR 文本达到索引上限，请将材料拆分后重试。");
                    pages[number - 1] = ocr;
                    cachedCharacters += ocr.Text.Length - prior;
                }
                recognized++;
            }
            await Task.Run(() => VerifyFile(cancellationToken), cancellationToken).ConfigureAwait(false);
            return new(missing, recognized);
        }
        finally { recognitionLock.Release(); }
    }

    public async Task<PagePreview> RenderCropAsync(int page, PdfRegion region, CancellationToken cancellationToken = default)
    {
        if (!ValidRegion(region)) throw new InvalidDataException("原页裁图区域无效。");
        var preview = await RenderPageAsync(page, 1900, cancellationToken).ConfigureAwait(false);
        return await Task.Run(() =>
        {
            int left = (int)Math.Floor(region.X * preview.Width);
            int top = (int)Math.Floor(region.Y * preview.Height);
            int width = Math.Min(preview.Width, (int)Math.Ceiling(region.Right * preview.Width)) - left;
            int height = Math.Min(preview.Height, (int)Math.Ceiling(region.Bottom * preview.Height)) - top;
            int stride = checked(width * 4);
            var pixels = new byte[checked(stride * height)];
            for (int y = 0; y < height; y++)
            {
                cancellationToken.ThrowIfCancellationRequested();
                Buffer.BlockCopy(preview.Pixels, (top + y) * preview.Stride + left * 4, pixels, y * stride, stride);
            }
            return new PagePreview(page, width, height, stride, pixels);
        }, cancellationToken).ConfigureAwait(false);
    }

    private static bool ValidRegion(PdfRegion region) =>
        region.X >= 0 && region.Y >= 0 && region.Width > 0 && region.Height > 0 &&
        region.Right <= 1.0000001 && region.Bottom <= 1.0000001;

    public Task<IReadOnlyList<DocumentExcerpt>> RetrieveAsync(
        string question, CancellationToken cancellationToken = default) =>
        Task.Run(() => Retrieve(question, cancellationToken), cancellationToken);

    public Task<PagePreview> RenderPageAsync(int page, int width = 1152, CancellationToken cancellationToken = default) =>
        Task.Run(() =>
        {
            if (!IsPdf || page < 1 || page > PageCount)
                throw new InvalidDataException("没有可预览的 PDF 页。");
            VerifyFile(cancellationToken);
            return WithPdf(bytes, document => Render(document, page, width, cancellationToken), cancellationToken);
        }, cancellationToken);

    private static PdfEvidence Open(string path, CancellationToken cancellationToken)
    {
        var fullPath = Path.GetFullPath(path);
        var extension = Path.GetExtension(fullPath).ToLowerInvariant();
        var isPdf = extension == ".pdf";
        if (!isPdf && extension is not (".txt" or ".text" or ".md" or ".markdown"))
            throw new InvalidDataException("请选择 PDF、纯文本或 Markdown 文件。");

        var limit = isPdf ? MaxFileBytes : MaxTextFileBytes;
        using var stream = File.Open(fullPath, FileMode.Open, FileAccess.Read, FileShare.Read);
        var length = stream.Length;
        if (length <= 0 || length > limit)
            throw new InvalidDataException($"文件为空或超过 Windows 候选版的 {limit / (1024 * 1024)} MB 上限。");
        var content = new byte[(int)length];
        for (var offset = 0; offset < content.Length;)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var count = stream.Read(content, offset, Math.Min(64 * 1024, content.Length - offset));
            if (count == 0) throw new InvalidDataException("读取过程中原文件已改变，请重新选择文件。");
            offset += count;
        }
        if (stream.Length != length)
            throw new InvalidDataException("读取过程中原文件已改变，请重新选择文件。");

        var title = Path.GetFileNameWithoutExtension(fullPath);
        if (!isPdf)
        {
            var result = new PdfEvidence(fullPath, title, content, 1, false);
            var lines = DecodeText(content).ReplaceLineEndings("\n").Split('\n')
                .Select(line => new LineContent(line, null, false)).ToArray();
            result.pages[0] = PageText.Assemble(1, lines, false);
            return result;
        }

        return WithPdf(content, document =>
        {
            var pageCount = Native.FPDF_GetPageCount(document);
            if (pageCount <= 0 || pageCount > MaxPages)
                throw new InvalidDataException($"PDF 页数不可读取或超过 Windows 候选版的 {MaxPages} 页上限。");
            return new PdfEvidence(fullPath, ReadTitle(document) ?? title, content, pageCount, true);
        }, cancellationToken);
    }

    private IReadOnlyList<DocumentExcerpt> Retrieve(string question, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(question) || question.Length > 8000)
            throw new InvalidDataException("请输入不超过 8000 字的取证问题。");
        VerifyFile(cancellationToken);

        var anchors = Anchors.Matches(question);
        if (anchors.Count > 1)
            throw new InvalidDataException("请每次只指定一组起止原句。");
        var outsidePassage = anchors.Count == 0 ? question : question.Remove(anchors[0].Index, anchors[0].Length);
        var requestedPages = PageAddress.Matches(outsidePassage);
        var aliases = PageAliases.Matches(outsidePassage);
        var addressCount = requestedPages.Count + aliases.Count;
        var remainder = PageAliases.Replace(PageAddress.Replace(outsidePassage, string.Empty), string.Empty);
        var wantsObject = IsPdf && (VisualObject.IsMatch(outsidePassage) || NumberedObject.IsMatch(outsidePassage));
        if (IsPdf && (addressCount > 1 || DisjointPages.IsMatch(outsidePassage) || UnsupportedAddress.IsMatch(remainder)))
            throw new InvalidDataException("无法核对多个页段、章节编号或该页码格式。请使用一个阿拉伯数字页码或连续页段，如第 2–4 页。");

        var first = 1;
        var last = PageCount;
        if (IsPdf && requestedPages.Count == 1)
        {
            var firstValue = requestedPages[0].Groups["first"].Value;
            var lastValue = requestedPages[0].Groups["last"].Value;
            if (!int.TryParse(firstValue, out first) ||
                !int.TryParse(string.IsNullOrEmpty(lastValue) ? firstValue : lastValue, out last) ||
                first < 1 || last < first || last > PageCount || last - first >= MaxPageRange)
                throw new InvalidDataException($"请求页位超出 1–{PageCount}，或连续页数超过 {MaxPageRange}。");
        }
        else if (IsPdf && aliases.Count == 1)
        {
            first = last = aliases[0].Groups["first"].Success ? 1 : PageCount;
        }
        var left = IsPdf && LeftColumn.IsMatch(outsidePassage);
        var right = IsPdf && RightColumn.IsMatch(outsidePassage);
        if (left && right) throw new InvalidDataException("请一次只指定一栏，以便核对原文顺序。");
        var column = left ? 1 : right ? 2 : 0;
        if (anchors.Count == 0 && UnparsedRange.IsMatch(remainder))
            throw new InvalidDataException("无法确定起止原句。可改用从「起点原句」到「终点原句」，也可指定页码。");

        var indexed = ReadPages(first, last, cancellationToken);
        IReadOnlyList<DocumentExcerpt> result = wantsObject
            ? LocateVisualObject(indexed, outsidePassage, column)
            : anchors.Count == 1
                ? ExactPassage(indexed, anchors[0], column)
            : addressCount > 0 && IsPdf
                ? ExplicitPages(indexed, column)
                : RelevantPassages(indexed, outsidePassage, column);
        VerifyFile(cancellationToken);
        return result;
    }

    private IReadOnlyList<DocumentExcerpt> LocateVisualObject(PageText[] indexed, string question, int column)
    {
        var requested = NumberedObject.Matches(question).Select(match =>
            (Type: ObjectType(match.Groups["type"].Value), Id: match.Groups["id"].Value.ToLowerInvariant())).Distinct().ToArray();
        if (requested.Length != 1)
            throw new InvalidDataException("请指定一个图、表或公式的明确编号。可同时指定物理页码。");
        var target = requested[0];
        var matches = new List<DocumentExcerpt>();
        foreach (var original in indexed)
        {
            var page = column == 0 ? original : original.ForColumn(column);
            foreach (var line in page.Lines)
            {
                if (line.Content is not { Fault: false, Region: PdfRegion location }) continue;
                string text = line.Content.Text.Trim();
                var label = NumberedObject.Match(text);
                var tag = target.Type == "equation" ? EquationTag.Match(text) : Match.Empty;
                bool isLabel = label.Success && label.Index == 0 && ObjectType(label.Groups["type"].Value) == target.Type
                    && label.Groups["id"].Value.Equals(target.Id, StringComparison.OrdinalIgnoreCase);
                bool isEquation = tag.Success && tag.Groups["id"].Value.Equals(target.Id, StringComparison.OrdinalIgnoreCase)
                    && EquationInk.IsMatch(text[..tag.Index]);
                if (!isLabel && !isEquation) continue;
                if (isLabel && target.Type == "equation" && !EquationInk.IsMatch(text)) continue;

                var region = location;
                if (target.Type != "equation")
                {
                    // Include the adjacent original-page area as well as its identified caption.
                    // The page crop remains available for visual verification of the object's extent.
                    var preceding = page.Lines.Select(item => item.Content.Region)
                        .Where(item => item.HasValue && item.Value.Bottom <= location.Y - 0.025)
                        .Select(item => item!.Value.Bottom).DefaultIfEmpty(0).Max();
                    var top = Math.Max(preceding, location.Y - 0.48);
                    var bottom = Math.Min(1, location.Bottom + 0.03);
                    if (target.Type == "table" && location.Y < 0.85)
                    {
                        top = Math.Max(0, location.Y - 0.025);
                        bottom = Math.Min(1, location.Bottom + 0.34);
                    }
                    region = new PdfRegion(column == 2 ? 0.47 : 0.02, top,
                        column == 0 ? 0.96 : 0.51, bottom - top);
                }
                else
                {
                    var x = Math.Max(0, region.X - 0.025);
                    var y = Math.Max(0, region.Y - 0.022);
                    region = new PdfRegion(x, y, Math.Min(1, region.Right + 0.025) - x,
                        Math.Min(1, region.Bottom + 0.022) - y);
                }
                var excerpt = VerifiedExcerpt(page, line.Start, line.End, mayUseIsolatedLine: true);
                matches.Add(excerpt with { VisualRegion = region });
            }
        }
        return matches.Count switch
        {
            1 => matches,
            0 => throw new InvalidDataException("未能定位编号对应的图注、表注或公式。扫描页请先识别，或缩小页码范围后重试。"),
            _ => throw new InvalidDataException("同一编号存在多个可能的位置，请指定物理页码后重试。")
        };
    }

    private static string ObjectType(string label)
    {
        var value = label.ToLowerInvariant();
        if (value == "图" || value.StartsWith("fig", StringComparison.Ordinal)) return "figure";
        if (value == "表" || value == "table") return "table";
        return "equation";
    }

    private PageText[] ReadPages(int first, int last, CancellationToken cancellationToken)
    {
        lock (indexLock)
        {
            cancellationToken.ThrowIfCancellationRequested();
            PageText[] GetPages(IntPtr document)
            {
                var result = new PageText[last - first + 1];
                var size = 0;
                for (var page = first; page <= last; page++)
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    var item = pages[page - 1];
                    if (item is null)
                    {
                        item = ReadPage(document, page, cancellationToken);
                        if (cachedCharacters + item.Text.Length <= MaxIndexedCharacters)
                        {
                            pages[page - 1] = item;
                            cachedCharacters += item.Text.Length;
                        }
                    }
                    size = checked(size + item.Text.Length);
                    if (size > MaxIndexedCharacters)
                        throw new InvalidDataException("文档文字超过一次可核验的上限。请缩小页段。");
                    result[page - first] = item;
                }
                return result;
            }

            if (!IsPdf || pages.Skip(first - 1).Take(last - first + 1).All(page => page is not null))
                return GetPages(IntPtr.Zero);
            return WithPdf(bytes, GetPages, cancellationToken);
        }
    }

    private IReadOnlyList<DocumentExcerpt> ExactPassage(PageText[] indexed, Match anchors, int column)
    {
        var startText = FoldWhitespace(anchors.Groups["start"].Value).Value;
        var endText = FoldWhitespace(anchors.Groups["end"].Value).Value;
        if (startText.Length == 0 || endText.Length == 0 || startText.Length > 1000 || endText.Length > 1000)
            throw new InvalidDataException("起止原句均须有文字且不超过 1000 字。");

        var source = column == 0 ? indexed : indexed.Select(page => page.ForColumn(column)).ToArray();
        var starts = new List<(int PageIndex, int Offset, int End)>();
        var ends = new List<(int PageIndex, int Offset, int End)>();
        for (var pageIndex = 0; pageIndex < source.Length; pageIndex++)
        {
            var text = FoldWhitespace(source[pageIndex].Text);
            AddMatches(starts, pageIndex, text, startText);
            AddMatches(ends, pageIndex, text, endText);
        }
        if (starts.Count != 1 || ends.Count != 1)
            throw new InvalidDataException(starts.Count == 0 || ends.Count == 0
                ? "至少一个起止原句未匹配。核对 PDF 原文，或缩小已知页段后重试。"
                : "起止原句匹配到多个位置。请增加原句长度或指定页段。");

        var start = starts[0];
        var end = ends[0];
        if (end.PageIndex < start.PageIndex ||
            (end.PageIndex == start.PageIndex && end.Offset < start.End) ||
            end.PageIndex - start.PageIndex >= MaxPageRange)
            throw new InvalidDataException("起止原句位置先后有冲突，或跨页范围过长。");

        var excerpts = new List<DocumentExcerpt>();
        for (var i = start.PageIndex; i <= end.PageIndex; i++)
        {
            var page = source[i];
            var lo = i == start.PageIndex ? start.Offset : 0;
            var hi = i == end.PageIndex ? end.End : page.Text.Length;
            excerpts.Add(VerifiedExcerpt(page, lo, hi));
        }
        RequireBounded(excerpts);
        return excerpts;
    }

    private IReadOnlyList<DocumentExcerpt> ExplicitPages(PageText[] indexed, int column)
    {
        var excerpts = indexed.Select(page => column == 0 ? page : page.ForColumn(column))
            .Select(page => VerifiedExcerpt(page, 0, page.Text.Length)).ToArray();
        RequireBounded(excerpts);
        return excerpts;
    }

    private IReadOnlyList<DocumentExcerpt> RelevantPassages(PageText[] indexed, string question, int column)
    {
        if (indexed.Length == 1 && !IsPdf && indexed[0].Text.Length <= 6800)
            return new[] { VerifiedExcerpt(indexed[0], 0, indexed[0].Text.Length) };

        var keywords = SearchTerms(question).Distinct(StringComparer.OrdinalIgnoreCase).Take(60).ToArray();
        var wantsSummary = Summary.IsMatch(question);
        var ranked = new List<(PageText Page, int Line, int Score)>();
        foreach (var source in indexed)
        {
            var page = column == 0 ? source : source.ForColumn(column);
            var bestIndex = -1;
            var bestScore = 0;
            for (var i = 0; i < page.Lines.Length; i++)
            {
                var line = page.Lines[i];
                if (line.Content.Fault || string.IsNullOrWhiteSpace(line.Content.Text)) continue;
                var score = keywords.Count(word => line.Content.Text.Contains(word, StringComparison.OrdinalIgnoreCase));
                if (score > bestScore || bestIndex < 0 && wantsSummary)
                {
                    bestIndex = i;
                    bestScore = score;
                }
            }
            if (bestIndex >= 0) ranked.Add((page, bestIndex, bestScore));
        }

        var result = new List<DocumentExcerpt>();
        foreach (var match in ranked.OrderByDescending(x => x.Score).ThenBy(x => x.Page.Number).Take(5))
        {
            var (page, center, _) = match;
            var first = center;
            var last = center;
            var basis = page.Lines[center].Content;
            if (!page.Ambiguous)
            {
                while (first > 0 && center - first < 3 &&
                    CanExtend(page.Lines[first - 1].Content, basis)) first--;
                while (last + 1 < page.Lines.Length && last - center < 5 &&
                    CanExtend(page.Lines[last + 1].Content, basis)) last++;
            }
            var lo = page.Lines[first].Start;
            var hi = page.Lines[last].End;
            if (hi - lo > MaxExcerpt)
                throw new InvalidDataException("定位到的连续文字太长，请限定原句起点和终点。");
            result.Add(VerifiedExcerpt(page, lo, hi, mayUseIsolatedLine: page.Ambiguous));
        }
        if (result.Count == 0)
            throw new InvalidDataException("没有匹配且可核验的文档文字。请尝试原文关键词、页码或重新选择含文字层的 PDF。");
        RequireBounded(result);
        return result;
    }

    private DocumentExcerpt VerifiedExcerpt(PageText page, int start, int end, bool mayUseIsolatedLine = false)
    {
        if (page.Ambiguous && !mayUseIsolatedLine)
            throw new InvalidDataException($"第 {page.Number} 页的栏序或浮动区无法核对。可选取原文再提问。");
        if (end <= start || page.Text.AsSpan(start, end - start).Trim().IsEmpty)
            throw new InvalidDataException($"第 {page.Number} 页没有可核验的文字层或目标栏。可先对扫描页执行本机 OCR。");

        var lines = page.Lines.Where(line => line.Start < end && line.End > start).ToArray();
        if (lines.Any(line => line.Content.Fault))
            throw new InvalidDataException($"第 {page.Number} 页有无法映射的原文字形。请打开原页核对。");
        var regions = lines.Select(line => line.Content.Region).Where(region => region.HasValue)
            .Select(region => region.GetValueOrDefault()).ToArray();
        if (IsPdf && regions.Length == 0)
            throw new InvalidDataException($"第 {page.Number} 页的摘录未取得可核验的页内位置。");
        return new DocumentExcerpt(FilePath, Title, page.Number, page.Text[start..end].Trim(), regions, Fingerprint,
            Recognition: page.Recognition);
    }

    private void VerifyFile(CancellationToken cancellationToken)
    {
        try
        {
            using var stream = File.Open(FilePath, FileMode.Open, FileAccess.Read, FileShare.Read);
            if (stream.Length != bytes.Length)
                throw new InvalidDataException("原文件内容已更新，请重新选择文件后重试。");
            using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            var buffer = new byte[64 * 1024];
            int count;
            while ((count = stream.Read(buffer)) > 0)
            {
                cancellationToken.ThrowIfCancellationRequested();
                hash.AppendData(buffer, 0, count);
            }
            if (!string.Equals(Convert.ToHexString(hash.GetHashAndReset()), Fingerprint, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("原文件内容已更新，请重新选择文件后重试。");
        }
        catch (Exception exception) when ((exception is IOException or UnauthorizedAccessException) &&
            exception is not InvalidDataException)
        {
            throw new InvalidDataException("原文件无法读取。请恢复文件位置或权限后重试。", exception);
        }
    }

    private static bool CanExtend(LineContent candidate, LineContent basis) =>
        !candidate.Fault && candidate.Column == basis.Column;

    private static void RequireBounded(IReadOnlyList<DocumentExcerpt> excerpts)
    {
        if (excerpts.Sum(excerpt => excerpt.Text.Length) > MaxExcerpt)
            throw new InvalidDataException("已确认的原文范围太长。请分批读页，当前范围未截断或发送。");
    }

    private static IEnumerable<string> SearchTerms(string text)
    {
        foreach (Match match in Terms.Matches(text))
        {
            var word = match.Value;
            if (word[0] is >= '\u4e00' and <= '\u9fff')
            {
                for (var i = 0; i + 1 < word.Length; i++)
                {
                    var pair = word.Substring(i, 2);
                    if (!StopWords.Contains(pair)) yield return pair;
                }
            }
            else if (word.Length >= 3 && !StopWords.Contains(word)) yield return word;
        }
    }

    private static (string Value, List<int> Offsets) FoldWhitespace(string input)
    {
        var text = new StringBuilder(input.Length);
        var offsets = new List<int>(input.Length);
        for (var i = 0; i < input.Length; i++)
        {
            var current = input[i];
            if (char.IsWhiteSpace(current))
            {
                if (text.Length == 0 || text[^1] == ' ') continue;
                current = ' ';
            }
            text.Append(current);
            offsets.Add(i);
        }
        if (text.Length > 0 && text[^1] == ' ')
        {
            text.Length--;
            offsets.RemoveAt(offsets.Count - 1);
        }
        return (text.ToString(), offsets);
    }

    private static void AddMatches(List<(int PageIndex, int Offset, int End)> matches, int pageIndex,
        (string Value, List<int> Offsets) text, string anchor)
    {
        for (var i = 0; i <= text.Value.Length - anchor.Length && matches.Count < 2;)
        {
            var match = text.Value.IndexOf(anchor, i, StringComparison.OrdinalIgnoreCase);
            if (match < 0) return;
            matches.Add((pageIndex, text.Offsets[match], text.Offsets[match + anchor.Length - 1] + 1));
            i = match + 1;
        }
    }

    private static string DecodeText(byte[] content)
    {
        try
        {
            var bom = content.AsSpan().StartsWith(new byte[] { 0xef, 0xbb, 0xbf }) ? 3 : 0;
            var text = content.AsSpan().StartsWith(Encoding.Unicode.Preamble)
                ? new UnicodeEncoding(false, true, true).GetString(content, 2, content.Length - 2)
                : content.AsSpan().StartsWith(Encoding.BigEndianUnicode.Preamble)
                    ? new UnicodeEncoding(true, true, true).GetString(content, 2, content.Length - 2)
                    : new UTF8Encoding(false, true).GetString(content, bom, content.Length - bom);
            if (text.Contains('\0')) throw new InvalidDataException("文件包含二进制内容。请选择有效的纯文本或 Markdown。");
            return text;
        }
        catch (DecoderFallbackException exception)
        {
            throw new InvalidDataException("无法辨认文字编码。请将文件保存为 UTF-8 或带 BOM 的 UTF-16 后重试。", exception);
        }
    }

    private static Regex Pattern(string expression) =>
        new(expression, RegexOptions.IgnoreCase | RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(300));

    private sealed record LineContent(string Text, PdfRegion? Region, bool Fault, int Column = 0);
    private sealed record TextLine(LineContent Content, int Start, int End);

    private sealed record PageText(int Number, string Text, TextLine[] Lines, bool Ambiguous, string? Recognition = null)
    {
        public static PageText Assemble(int number, IEnumerable<LineContent> contents, bool ambiguous)
        {
            var text = new StringBuilder();
            var ranges = new List<TextLine>();
            foreach (var content in contents)
            {
                if (ranges.Count > 0) text.Append('\n');
                var start = text.Length;
                text.Append(content.Text);
                ranges.Add(new TextLine(content, start, text.Length));
            }
            return new PageText(number, text.ToString(), ranges.ToArray(), ambiguous);
        }

        public PageText ForColumn(int column)
        {
            var ordered = Lines.Where(line => line.Content.Column == column).Select(line => line.Content);
            return Assemble(Number, ordered, Ambiguous) with { Recognition = Recognition };
        }
    }

    private static PageText ReadPage(IntPtr document, int pageNumber, CancellationToken cancellationToken)
    {
        var page = Native.FPDF_LoadPage(document, pageNumber - 1);
        if (page == IntPtr.Zero) throw new InvalidDataException($"无法打开 PDF 第 {pageNumber} 页。");
        try
        {
            var text = Native.FPDFText_LoadPage(page);
            if (text == IntPtr.Zero) return PageText.Assemble(pageNumber, Array.Empty<LineContent>(), false);
            try
            {
                var count = Native.FPDFText_CountChars(text);
                if (count > MaxPageCharacters)
                    throw new InvalidDataException($"第 {pageNumber} 页文字超过 Windows 候选版的核验上限。");
                var (lines, separatedRuns) = ReadLines(page, text, count, cancellationToken);
                return OrderPage(pageNumber, lines, separatedRuns);
            }
            finally { Native.FPDFText_ClosePage(text); }
        }
        finally { Native.FPDF_ClosePage(page); }
    }

    private static (LineContent[] Lines, bool SeparatedRuns) ReadLines(
        IntPtr page, IntPtr text, int count, CancellationToken cancellationToken)
    {
        var projection = DeviceProjection.FromPage(page);
        var result = new List<LineContent>();
        var line = new StringBuilder();
        PdfRegion? region = null;
        PdfRegion? previous = null;
        var fault = false;
        var separatedRuns = false;
        var newLine = false;

        void CloseLine()
        {
            if (line.Length > 0 || result.Count > 0)
            {
                var lineText = line.ToString();
                var lacksPosition = region is null && !string.IsNullOrWhiteSpace(lineText);
                result.Add(new LineContent(lineText, region, fault || lacksPosition));
            }
            line.Clear();
            region = null;
            previous = null;
            fault = false;
        }

        for (var index = 0; index < count; index++)
        {
            if (index % 256 == 0) cancellationToken.ThrowIfCancellationRequested();
            var value = Native.FPDFText_GetUnicode(text, index);
            if (value is '\r' or '\n')
            {
                if (value == '\r' || !newLine) CloseLine();
                newLine = value == '\r';
                continue;
            }
            newLine = false;
            var decoded = Rune.TryCreate((int)value, out var rune) && rune.Value is not (0 or 0xfffd) &&
                Native.FPDFText_HasUnicodeMapError(text, index) <= 0;
            var position = !Rune.IsWhiteSpace(rune) && Native.FPDFText_IsGenerated(text, index) <= 0 &&
                Native.FPDFText_GetCharBox(text, index, out var x1, out var x2, out var y1, out var y2) != 0
                ? projection.Project(x1, x2, y1, y2) : null;
            // PDFium can place two objects on the same text row. Record the
            // separated runs, then require a page-wide gutter before trusting
            // their reading order.
            if (position is { } current && previous is { } last &&
                last.Right < 0.52 && current.X > 0.46 && current.X - last.Right > 0.075 &&
                Math.Abs(current.Y - last.Y) < Math.Max(current.Height, last.Height))
            {
                while (line.Length > 0 && char.IsWhiteSpace(line[^1])) line.Length--;
                CloseLine();
                separatedRuns = true;
            }
            if (!decoded)
            {
                fault = true;
                line.Append('\ufffd');
            }
            else if (!Rune.IsControl(rune) || rune.Value == '\t') line.Append(rune.ToString());
            else fault = true;

            if (position is not { } box) continue;
            region = region is { } existing ? Union(existing, box) : box;
            previous = box;
        }
        CloseLine();
        return (result.ToArray(), separatedRuns);
    }

    private static PageText OrderPage(int number, LineContent[] lines, bool separatedRuns)
    {
        var withRegion = lines.Where(line => line.Region.HasValue && !string.IsNullOrWhiteSpace(line.Text)).ToArray();
        var divided = FindColumnSplit(withRegion);
        if (divided is null)
        {
            var uncertain = separatedRuns || withRegion.Zip(withRegion.Skip(1)).Any(pair =>
                pair.First.Region!.Value.Y - pair.Second.Region!.Value.Y > 0.12);
            return PageText.Assemble(number, lines, uncertain);
        }
        var (split, top, bottom) = divided.Value;
        var left = new List<LineContent>();
        var right = new List<LineContent>();
        var before = new List<LineContent>();
        var after = new List<LineContent>();
        var ambiguous = false;
        foreach (var line in withRegion)
        {
            var box = line.Region!.Value;
            if (box.Bottom < top - 0.012) before.Add(line);
            else if (box.Y > bottom + 0.012) after.Add(line);
            else if (box.Right <= split) left.Add(line with { Column = 1 });
            else if (box.X >= split) right.Add(line with { Column = 2 });
            else { before.Add(line); ambiguous = true; }
        }
        ambiguous |= withRegion.Any(line => line.Fault || HasRightToLeftText(line.Text)) ||
            withRegion.Length != lines.Count(line => !string.IsNullOrWhiteSpace(line.Text));
        if (ambiguous)
            return PageText.Assemble(number, lines, true);
        var ordered = before.OrderBy(Vertical).Concat(left.OrderBy(Vertical))
            .Concat(right.OrderBy(Vertical)).Concat(after.OrderBy(Vertical));
        return PageText.Assemble(number, ordered, false);
    }

    private static (double Split, double Top, double Bottom)? FindColumnSplit(LineContent[] lines)
    {
        var bestScore = 2;
        (double, double, double)? best = null;
        foreach (var split in new[] { 0.50, 0.47, 0.53, 0.44, 0.56 })
        {
            var left = lines.Select(line => line.Region!.Value)
                .Where(box => box.Right < split - 0.012 && box.Width > 0.13).ToArray();
            var right = lines.Select(line => line.Region!.Value)
                .Where(box => box.X > split + 0.012 && box.Width > 0.13).OrderBy(box => box.Y).ToArray();
            if (left.Length < 3 || right.Length < 3) continue;
            // Only overlapping rows establish columns; indented paragraphs on
            // separate parts of a normal page must not look like two columns.
            var leftSorted = left.OrderBy(box => box.Y);
            var aligned = 0;
            var rightIndex = 0;
            foreach (var line in leftSorted)
            {
                while (rightIndex < right.Length && right[rightIndex].Bottom < line.Y) rightIndex++;
                if (rightIndex < right.Length && right[rightIndex].Y <= line.Bottom) aligned++;
            }
            if (aligned <= bestScore) continue;
            bestScore = aligned;
            best = (split, Math.Min(left.Min(box => box.Y), right[0].Y),
                Math.Max(left.Max(box => box.Bottom), right.Max(box => box.Bottom)));
        }
        return best;
    }

    private static bool HasRightToLeftText(string text) =>
        text.Any(c => c is >= '\u0590' and <= '\u08ff');

    private static double Vertical(LineContent line) => line.Region?.Y ?? 0;

    private static PdfRegion Union(PdfRegion a, PdfRegion b)
    {
        var x = Math.Min(a.X, b.X);
        var y = Math.Min(a.Y, b.Y);
        return new PdfRegion(x, y, Math.Max(a.Right, b.Right) - x, Math.Max(a.Bottom, b.Bottom) - y);
    }

    // Use PDFium's page-to-rendered transform, which includes a non-zero crop
    // origin and intrinsic page rotations. Calibrate the affine transform once
    // per page, keeping all subsequent glyph projections managed.
    private readonly record struct DeviceProjection(double X, double Y, double XX, double XY, double YX, double YY)
    {
        private const int Scale = 32768;
        private const int Basis = 1024;

        internal static DeviceProjection FromPage(IntPtr page)
        {
            if (Native.FPDF_PageToDevice(page, 0, 0, Scale, Scale, 0, 0, 0, out var x, out var y) == 0 ||
                Native.FPDF_PageToDevice(page, 0, 0, Scale, Scale, 0, Basis, 0, out var xx, out var xy) == 0 ||
                Native.FPDF_PageToDevice(page, 0, 0, Scale, Scale, 0, 0, Basis, out var yx, out var yy) == 0)
                throw new InvalidDataException("无法换算该 PDF 页的文字位置。");
            return new DeviceProjection(x / (double)Scale, y / (double)Scale,
                (xx - x) / (double)(Scale * Basis), (xy - y) / (double)(Scale * Basis),
                (yx - x) / (double)(Scale * Basis), (yy - y) / (double)(Scale * Basis));
        }

        internal PdfRegion? Project(double x1, double x2, double y1, double y2)
        {
            if (!double.IsFinite(x1) || !double.IsFinite(x2) || !double.IsFinite(y1) || !double.IsFinite(y2))
                return null;
            var loX = X + Math.Min(x1 * XX, x2 * XX) + Math.Min(y1 * YX, y2 * YX);
            var hiX = X + Math.Max(x1 * XX, x2 * XX) + Math.Max(y1 * YX, y2 * YX);
            var loY = Y + Math.Min(x1 * XY, x2 * XY) + Math.Min(y1 * YY, y2 * YY);
            var hiY = Y + Math.Max(x1 * XY, x2 * XY) + Math.Max(y1 * YY, y2 * YY);
            loX = Math.Clamp(loX, 0, 1);
            loY = Math.Clamp(loY, 0, 1);
            hiX = Math.Clamp(hiX, 0, 1);
            hiY = Math.Clamp(hiY, 0, 1);
            return hiX > loX && hiY > loY ? new PdfRegion(loX, loY, hiX - loX, hiY - loY) : null;
        }
    }

    private static PagePreview Render(IntPtr document, int number, int requestedWidth, CancellationToken cancellationToken)
    {
        var page = Native.FPDF_LoadPage(document, number - 1);
        if (page == IntPtr.Zero) throw new InvalidDataException($"无法打开 PDF 第 {number} 页。");
        try
        {
            var naturalWidth = Native.FPDF_GetPageWidthF(page);
            var naturalHeight = Native.FPDF_GetPageHeightF(page);
            if (!float.IsFinite(naturalWidth) || !float.IsFinite(naturalHeight) || naturalWidth <= 0 || naturalHeight <= 0)
                throw new InvalidDataException("该 PDF 页的尺寸不可用。");
            var ratio = naturalHeight / (double)naturalWidth;
            var width = Math.Max(1, (int)Math.Min(Math.Clamp(requestedWidth, 180, 2400), 3200 / ratio));
            var height = Math.Clamp((int)Math.Ceiling(width * ratio), 1, 3200);
            if (width == 1 && ratio > 3200) throw new InvalidDataException("该 PDF 页的长宽比超出预览范围。");
            var bitmap = Native.FPDFBitmap_Create(width, height, 0);
            if (bitmap == IntPtr.Zero) throw new InvalidDataException("无法为 PDF 预览分配内存。");
            try
            {
                Native.FPDFBitmap_FillRect(bitmap, 0, 0, width, height, 0xffffffff);
                Native.FPDF_RenderPageBitmap(bitmap, page, 0, 0, width, height, 0, 0);
                cancellationToken.ThrowIfCancellationRequested();
                var stride = Native.FPDFBitmap_GetStride(bitmap);
                var buffer = Native.FPDFBitmap_GetBuffer(bitmap);
                if (buffer == IntPtr.Zero || stride != width * 4)
                    throw new InvalidDataException("PDF 预览返回了无法核验的像素格式。");
                var pixels = new byte[checked(stride * height)];
                Marshal.Copy(buffer, pixels, 0, pixels.Length);
                return new PagePreview(number, width, height, stride, pixels);
            }
            finally { Native.FPDFBitmap_Destroy(bitmap); }
        }
        finally { Native.FPDF_ClosePage(page); }
    }

    private static string? ReadTitle(IntPtr document)
    {
        var length = Native.FPDF_GetMetaText(document, "Title", null, 0);
        if (length is <= 2 or > 4096 || length % 2 != 0) return null;
        var data = new byte[(int)length];
        if (Native.FPDF_GetMetaText(document, "Title", data, length) != length) return null;
        var title = new string(Encoding.Unicode.GetString(data).Where(c => !char.IsControl(c)).ToArray()).Trim();
        return title.Length > 0 ? title : null;
    }

    private static T WithPdf<T>(byte[] data, Func<IntPtr, T> action, CancellationToken cancellationToken)
    {
        // PDFium documents and bitmaps are not thread-safe. The pinned file
        // bytes must remain valid until the document is closed.
        lock (NativeLock)
        {
            cancellationToken.ThrowIfCancellationRequested();
            try
            {
                if (!initialized)
                {
                    Native.FPDF_InitLibrary();
                    initialized = true;
                }
                var memory = GCHandle.Alloc(data, GCHandleType.Pinned);
                try
                {
                    var document = Native.FPDF_LoadMemDocument64(memory.AddrOfPinnedObject(), (nuint)data.Length, IntPtr.Zero);
                    if (document == IntPtr.Zero)
                        throw new InvalidDataException(Native.FPDF_GetLastError() == 4
                            ? "此 PDF 有密码保护。请选择已解锁的可读副本。"
                            : "PDFium 无法打开该文件。文件可能已损坏或格式不受支持。");
                    try { return action(document); }
                    finally { Native.FPDF_CloseDocument(document); }
                }
                finally { memory.Free(); }
            }
            catch (Exception exception) when (exception is DllNotFoundException or EntryPointNotFoundException or BadImageFormatException)
            {
                throw new InvalidDataException("无法加载随包分发的 x64 PDFium，请核对安装包和平台。", exception);
            }
        }
    }

    private static class Native
    {
        private const string Pdfium = "pdfium.dll";
        private const DllImportSearchPath Bundled = DllImportSearchPath.AssemblyDirectory | DllImportSearchPath.ApplicationDirectory;

        [DllImport(Pdfium, ExactSpelling = true), DefaultDllImportSearchPaths(Bundled)] internal static extern void FPDF_InitLibrary();
        [DllImport(Pdfium, ExactSpelling = true), DefaultDllImportSearchPaths(Bundled)] internal static extern IntPtr FPDF_LoadMemDocument64(IntPtr data, nuint length, IntPtr password);
        [DllImport(Pdfium, ExactSpelling = true), DefaultDllImportSearchPaths(Bundled)] internal static extern uint FPDF_GetLastError();
        [DllImport(Pdfium, ExactSpelling = true), DefaultDllImportSearchPaths(Bundled)] internal static extern void FPDF_CloseDocument(IntPtr document);
        [DllImport(Pdfium, ExactSpelling = true), DefaultDllImportSearchPaths(Bundled)] internal static extern int FPDF_GetPageCount(IntPtr document);
        [DllImport(Pdfium, ExactSpelling = true), DefaultDllImportSearchPaths(Bundled)] internal static extern IntPtr FPDF_LoadPage(IntPtr document, int index);
        [DllImport(Pdfium, ExactSpelling = true), DefaultDllImportSearchPaths(Bundled)] internal static extern void FPDF_ClosePage(IntPtr page);
        [DllImport(Pdfium, ExactSpelling = true), DefaultDllImportSearchPaths(Bundled)] internal static extern float FPDF_GetPageWidthF(IntPtr page);
        [DllImport(Pdfium, ExactSpelling = true), DefaultDllImportSearchPaths(Bundled)] internal static extern float FPDF_GetPageHeightF(IntPtr page);
        [DllImport(Pdfium, ExactSpelling = true), DefaultDllImportSearchPaths(Bundled)] internal static extern uint FPDF_GetMetaText(IntPtr document, [MarshalAs(UnmanagedType.LPStr)] string tag, [Out] byte[]? buffer, uint length);
        [DllImport(Pdfium, ExactSpelling = true), DefaultDllImportSearchPaths(Bundled)] internal static extern IntPtr FPDFText_LoadPage(IntPtr page);
        [DllImport(Pdfium, ExactSpelling = true), DefaultDllImportSearchPaths(Bundled)] internal static extern void FPDFText_ClosePage(IntPtr text);
        [DllImport(Pdfium, ExactSpelling = true), DefaultDllImportSearchPaths(Bundled)] internal static extern int FPDFText_CountChars(IntPtr text);
        [DllImport(Pdfium, ExactSpelling = true), DefaultDllImportSearchPaths(Bundled)] internal static extern uint FPDFText_GetUnicode(IntPtr text, int index);
        [DllImport(Pdfium, ExactSpelling = true), DefaultDllImportSearchPaths(Bundled)] internal static extern int FPDFText_IsGenerated(IntPtr text, int index);
        [DllImport(Pdfium, ExactSpelling = true), DefaultDllImportSearchPaths(Bundled)] internal static extern int FPDFText_HasUnicodeMapError(IntPtr text, int index);
        [DllImport(Pdfium, ExactSpelling = true), DefaultDllImportSearchPaths(Bundled)] internal static extern int FPDFText_GetCharBox(IntPtr text, int index, out double left, out double right, out double bottom, out double top);
        [DllImport(Pdfium, ExactSpelling = true), DefaultDllImportSearchPaths(Bundled)] internal static extern int FPDF_PageToDevice(IntPtr page, int x, int y, int width, int height, int rotation, double pageX, double pageY, out int deviceX, out int deviceY);
        [DllImport(Pdfium, ExactSpelling = true), DefaultDllImportSearchPaths(Bundled)] internal static extern IntPtr FPDFBitmap_Create(int width, int height, int alpha);
        [DllImport(Pdfium, ExactSpelling = true), DefaultDllImportSearchPaths(Bundled)] internal static extern int FPDFBitmap_FillRect(IntPtr bitmap, int left, int top, int width, int height, uint color);
        [DllImport(Pdfium, ExactSpelling = true), DefaultDllImportSearchPaths(Bundled)] internal static extern IntPtr FPDFBitmap_GetBuffer(IntPtr bitmap);
        [DllImport(Pdfium, ExactSpelling = true), DefaultDllImportSearchPaths(Bundled)] internal static extern int FPDFBitmap_GetStride(IntPtr bitmap);
        [DllImport(Pdfium, ExactSpelling = true), DefaultDllImportSearchPaths(Bundled)] internal static extern void FPDFBitmap_Destroy(IntPtr bitmap);
        [DllImport(Pdfium, ExactSpelling = true), DefaultDllImportSearchPaths(Bundled)] internal static extern void FPDF_RenderPageBitmap(IntPtr bitmap, IntPtr page, int x, int y, int width, int height, int rotation, int flags);
    }
}
