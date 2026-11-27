using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace ResearchCompanion.Windows;

internal sealed record DocumentEvidenceTurn(
    IReadOnlyList<IReadOnlyList<DocumentExcerpt>> Segments, IReadOnlyList<int> MissingPages,
    string Coverage, string? Guidance = null, bool IsTranslation = false, bool SelectionOnly = false,
    bool RequiresMoreEvidence = false)
{
    internal string PlanningFeedback => "【已读取的证据】\n" + PdfEvidence.BoundPlanningText(
        string.Join("\n\n", Segments.SelectMany(segment => segment)
            .Select(item => $"【文件第 {item.Page} 页】\n{item.Text}")), 5_900);
}

internal sealed class DocumentPlanningNeededException(string message) : InvalidOperationException(message);

internal sealed partial class PdfEvidence
{
    private const int MaterialLimit = 24_000;
    private const int AnalysisSegmentLimit = 7_200;
    private const int TranslationSegmentLimit = 10_000;
    private const int MaxTurnSegments = 40;
    private const int MinimumPartialBody = 80;
    private static readonly Regex TranslateRequest = Pattern(@"翻译|译[成为出]|翻[成为]|\btranslat(?:e|ion)\b");
    private static readonly Regex ExactRequest = Pattern(
        @"摘[录出]|抄[录出]|照录|提取|逐字|读出|逐段|逐句|逐页|逐条|精确引用|准确引用|原文引用|只(?:给|要|看)原文|必须完整|不得遗漏|不遗漏|不要(?:总结|分析)|无需(?:总结|分析)|\b(?:quote|transcribe|extract|verbatim|read|word for word|without omissions|paragraph by paragraph|sentence by sentence)\b");
    private static readonly Regex FormulaOrDefinition = Pattern(
        @"公式|原式|方程|算式|推导|变量|定义|等式|定理|引理|符号|参数.{0,5}(?:含义|表示|定义)|\b(?:formulae?|formulas|equations?|derivations?|variables?|theorems?|lemmas?|proof|definitions?|symbols?)\b|\b(?:what\s+does\s+(?:the\s+)?(?:parameter|[a-z])\b.{0,28}|parameters?\b.{0,24})(?:mean|denote|represent)\b");
    private static readonly Regex WholeDocument = Pattern(
        @"整篇|全文|整份|全部页|\b(?:whole|entire|full)\s+(?:PDF|paper|document|text)\b|\ball\s+pages\b");
    private static readonly Regex Comparison = Pattern(@"比较|对比|区别|关系|\b(?:compar(?:e|ison)|relationship|difference)\b");
    private static readonly Regex CaptionOnly = Pattern(
        @"(?:只|仅)(?:需|要|看|翻译|摘录)?[^。!?]{0,24}图注|\b(?:caption\s+only|(?:only|just)\s+(?:(?:translate|quote|read)\s+)?(?:the\s+)?caption)\b");
    private static readonly Regex FollowUp = Pattern(
        @"^\s*(?:它|这一?个|那一?个|这(?:个|里|条|张|一式|个图)|上式|前式|上一(?:式|公式|张图)|前一(?:式|公式)|(?:the previous|this|that|it|how does it)\b)");
    private static readonly Regex RelativeObject = Pattern(
        @"(?:这|那|上一|前一)(?:一|个|张)?(?:公式|方程|式|图|表)|上式|前式|\b(?:this|that|previous|last|another)\s+(?:figure|chart|table|formula|equation)\b");
    private static readonly Regex OnlySelection = Pattern(
        @"(?:只|仅)(?:用|看|翻译|根据|依据|解释)(?:本次|当前|所选)?选区|\b(?:only|just)\s+(?:use|read|translate|explain)\s+(?:the\s+)?(?:selected text|selection)\b|\b(?:the\s+)?selection only\b");
    private static readonly Regex UserImageClause = Pattern(
        @"用户(?:提供的?|附加的?)?(?:附图|图片|图像|截屏|截图)|(?:本轮|随附|上传|附加|提供)(?:的|过的)?(?:附图|图片|图像|截屏|截图)|\b(?:attached|uploaded|user[- ]provided)\s+(?:images?|photos?|pictures?|screenshots?)\b");
    private static readonly Regex FileClause = Pattern(
        @"原文|论文|本文|文献|文档|文件|选区|页码|第\s*\d+\s*页|\b(?:PDF|paper|document|excerpt|selection|source\s+text|pages?\s*\d+)\b");
    private static readonly Regex FormulaShape = Pattern(
        @"^\s*(?:[\p{L}\p{N}_∑∫√∂∇]|\([\p{L}\p{N}]+\))(?=[\s_(=≈≡≤≥+\-*/^])");
    private static readonly Regex Heading = Pattern(
        @"^\s*(?:(?:\d{1,2}(?:\.\d{1,2}){0,3}\.?\s+|第\s*\d+\s*[章节]\s*)\p{L}|\b(?:abstract|introduction|method(?:s|ology)?|results|discussion|conclusions?|appendix|references)\b[\s:：]*$|(?:摘要|引言|方法|结果|讨论|结论|附录|参考文献)[\s:：]*$)");
    private static readonly Regex SectionAddress = Pattern(
        @"\b(?:section|chapter)\s+(?<id>\d{1,2}(?:\.\d{1,2}){0,3})(?![\d.])|第\s*(?<id>\d{1,2}(?:\.\d{1,2}){0,3})\s*[章节]");
    private static readonly Regex HeadingNumber = Pattern(
        @"^\s*(?:第\s*)?(?<id>\d{1,2}(?:\.\d{1,2}){0,3})(?:\.\s+|\s+[^\d]|[章节])");
    private static readonly string[][] Concepts =
    [
        ["方法", "技术", "method", "methods", "approach", "algorithm", "technique", "framework"],
        ["传统", "常规", "baseline", "conventional", "traditional", "standard"],
        ["贡献", "创新", "contribution", "contributions", "propose", "proposed", "introduce", "novel"],
        ["局限", "限制", "不足", "limitation", "limitations", "limited", "however", "future"],
        ["结果", "实验", "results", "experiments", "experimental", "evaluation", "measured"],
        ["准确性", "精度", "accuracy", "accurate", "error", "precision"],
        ["加速", "效率", "速度", "speedup", "performance", "runtime", "faster"],
        ["计算复杂度", "复杂度", "complexity", "asymptotic", "flops"],
        ["梯度下降", "gradient", "descent"], ["收敛", "convergence", "converge"],
        ["摘要", "abstract"], ["引言", "introduction"], ["结论", "conclusion", "conclusions"],
        ["讨论", "discussion"], ["附录", "appendix"]
    ];

    internal Task ValidateCurrentAsync(CancellationToken cancellationToken) =>
        Task.Run(() => VerifyFile(cancellationToken), cancellationToken);

    internal Task<DocumentEvidenceTurn> RetrieveTurnAsync(string question, string? selection = null,
        IReadOnlyList<DocumentExcerpt>? priorEvidence = null, bool includingUserImages = false,
        CancellationToken cancellationToken = default) =>
        Task.Run(() =>
        {
            VerifyFile(cancellationToken);
            var turn = RetrieveTurn(question, selection, priorEvidence, includingUserImages, cancellationToken);
            VerifyFile(cancellationToken);
            return turn;
        }, cancellationToken);

    internal Task<IReadOnlyDictionary<string, object?>> PlanningDocumentAsync(string? selection,
        IReadOnlyList<string>? history, string? feedback, CancellationToken ct) =>
        Task.Run<IReadOnlyDictionary<string, object?>>(() =>
        {
            if (!IsPdf) throw new InvalidDataException("当前文件不是可按页核对的 PDF。");
            VerifyFile(ct);
            var fields = new Dictionary<string, object?>
            {
                ["id"] = Fingerprint, ["title"] = BoundPlanningText(Title, 512), ["pages"] = PageCount
            };
            var outline = ReadPages(1, PageCount, ct)
                .SelectMany(page => page.Lines.Where(line => Readable(line, true) && IsHeading(line.Content.Text))
                    .Select(line => $"文件页 {page.Number} · {BoundPlanningText(line.Content.Text, 220)}"))
                .Distinct(StringComparer.Ordinal).Take(32).ToArray();
            if (outline.Length != 0) fields["outline"] = outline;
            if (!string.IsNullOrWhiteSpace(selection)) fields["selection"] = BoundPlanningText(selection, 1200);
            if (history is { Count: > 0 })
                fields["history"] = history.Where(item => !string.IsNullOrWhiteSpace(item)).TakeLast(4)
                    .Select(item => BoundPlanningText(item, 800)).ToArray();
            if (!string.IsNullOrWhiteSpace(feedback)) fields["feedback"] = BoundPlanningText(feedback, 6000);
            VerifyFile(ct);
            return fields;
        }, ct);

    internal Task<DocumentEvidenceTurn> ApplyPlanningResultAsync(JsonElement plan, string question, string? selection = null,
        DocumentEvidenceTurn? prior = null, bool includingUserImages = false, CancellationToken cancellationToken = default) =>
        Task.Run(() =>
        {
            VerifyFile(cancellationToken);
            if (!IsPdf || plan.ValueKind != JsonValueKind.Object)
                throw new InvalidDataException("无法核对科研桥返回的文档查询。");
            var result = ApplyPlan(plan, question, selection, prior, includingUserImages, cancellationToken);
            VerifyFile(cancellationToken);
            return result;
        }, cancellationToken);

    private sealed record TurnAddress(string Question, Match Anchor, bool HasPages, int First, int Last,
        int Column, string? Section, bool WantsObject)
    {
        internal bool Explicit => Anchor.Success || HasPages || Column != 0 || Section != null || WantsObject;
    }

    private static string Instruction(string question, bool includingUserImages)
    {
        if (string.IsNullOrWhiteSpace(question) || question.Length > 8_000)
            throw new InvalidDataException("请输入不超过 8000 字的取证问题。");
        if (!includingUserImages) return question;
        var clauses = Regex.Split(question, @"[。！!？?；;\r\n]|(?<=\.)\s+(?=[A-Z])")
            .Where(clause => !UserImageClause.IsMatch(clause) || FileClause.IsMatch(clause)).ToArray();
        return clauses.Any(clause => !string.IsNullOrWhiteSpace(clause)) ? string.Join("\n", clauses) : question;
    }

    private TurnAddress Address(string question)
    {
        var anchors = Anchors.Matches(question);
        if (anchors.Count > 1) throw new InvalidDataException("请每次只指定一组起止原句。");
        var anchor = anchors.Count == 0 ? Match.Empty : anchors[0];
        var outside = anchor.Success ? question.Remove(anchor.Index, anchor.Length) : question;
        var page = PageAddress.Matches(outside);
        var alias = PageAliases.Matches(outside);
        var section = SectionAddress.Matches(outside);
        bool hasPages = page.Count + alias.Count != 0;
        var remainder = SectionAddress.Replace(PageAliases.Replace(PageAddress.Replace(outside, ""), ""), "");
        if (page.Count + alias.Count > 1 || section.Count > 1 || DisjointPages.IsMatch(outside) ||
            UnsupportedAddress.IsMatch(remainder))
            throw new InvalidDataException("无法核对多个页段或该页码格式。请指定一个物理页码或连续页段。");
        int first = 1, last = PageCount;
        if (page.Count == 1)
        {
            string from = page[0].Groups["first"].Value;
            string to = page[0].Groups["last"].Value;
            if (!int.TryParse(from, NumberStyles.None, CultureInfo.InvariantCulture, out first) ||
                !int.TryParse(to.Length == 0 ? from : to, NumberStyles.None, CultureInfo.InvariantCulture, out last) ||
                first < 1 || last < first || last > PageCount)
                throw new InvalidDataException($"请求页位超出文件页 1–{PageCount}。");
        }
        else if (alias.Count == 1) first = last = alias[0].Groups["first"].Success ? 1 : PageCount;
        bool left = LeftColumn.IsMatch(outside), right = RightColumn.IsMatch(outside);
        if (left && right) throw new InvalidDataException("请一次只指定一栏，以便核对原文顺序。");
        if (!anchor.Success && UnparsedRange.IsMatch(remainder))
            throw new InvalidDataException("无法确定起止原句。请使用两个完整的引号内端点，或指定页码。");
        bool target = !anchor.Success && (VisualObject.IsMatch(outside) || NumberedObject.IsMatch(outside) ||
            RelativeObject.IsMatch(outside));
        return new(outside, anchor, hasPages, first, last, left ? 1 : right ? 2 : 0,
            section.Count == 1 ? section[0].Groups["id"].Value : null, target);
    }

    private DocumentEvidenceTurn RetrieveTurn(string question, string? selection, IReadOnlyList<DocumentExcerpt>? prior,
        bool includingUserImages, CancellationToken ct)
    {
        var instruction = Instruction(question, includingUserImages);
        bool translate = TranslateRequest.IsMatch(instruction);
        if (OnlySelection.IsMatch(instruction))
        {
            if (string.IsNullOrWhiteSpace(selection)) throw new InvalidDataException("本轮仅限选区，当前没有可用选区。");
            return new([], [], "仅本次选区", IsTranslation: translate, SelectionOnly: true);
        }
        if (!IsPdf)
            return PackExact(Retrieve(instruction, ct), "相关文件原文", translate, TurnLimit(selection), false);

        var address = Address(instruction);
        var requested = ExplicitObjectLabels(address.Question);
        if (address.Anchor.Success) requested = [];
        if (address.Section != null && (address.Anchor.Success || address.WantsObject))
            throw new InvalidDataException("无法同时核对章节和原句或对象边界。请缩小到对应文件页。");
        bool followUp = !address.Explicit && FollowUp.IsMatch(instruction);
        if ((followUp || RelativeObject.IsMatch(instruction)) && requested.Count == 0 && prior != null)
        {
            requested = prior.Where(item => item.Fingerprint == Fingerprint && item.ObjectLabel != null)
                .Select(item => item.ObjectLabel!).Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
            if (requested.Count > 1 && !Comparison.IsMatch(instruction))
                throw new DocumentPlanningNeededException("上一轮有多个文档对象。请指明本轮要核对的编号。");
        }

        int limit = TurnLimit(selection);
        if (requested.Count > 0)
        {
            if (requested.Count == 1 && Comparison.IsMatch(instruction) &&
                Regex.IsMatch(instruction, @"(?:另一个|上一|前一|上个|previous|another|other)\s*", RegexOptions.IgnoreCase))
                throw new DocumentPlanningNeededException("比较要求尚未定位第二个文档对象。请指明编号，或核对取证计划。");
            return ReadObjects(requested, address, translate, limit, ct);
        }
        if (address.WantsObject)
            throw new DocumentPlanningNeededException("尚未定位图、表或公式。请给出明确编号，或核对取证计划。");

        bool whole = WholeDocument.IsMatch(instruction);
        if (translate && !whole && !address.Explicit)
            throw new DocumentPlanningNeededException("翻译需要可核对的原文范围。请指定位置，或核对取证计划。");
        var segmentLimit = Math.Min(limit, translate ? TranslationSegmentLimit : AnalysisSegmentLimit);
        var indexed = ReadPages(address.First, address.Last, ct);
        if (address.Anchor.Success)
            return PackExact(ExactPassage(indexed, address.Anchor.Groups["start"].Value, address.Anchor.Groups["end"].Value,
                address.Column, segmentLimit: segmentLimit), "已核验的连续原文范围", translate, limit, true);
        if (address.Section is { } section)
            return PackExact(ReadSection(indexed, section, address.Column, segmentLimit), "已核验的章节原文", translate, limit, true);
        if (address.Column != 0 && !address.HasPages)
            throw new InvalidDataException("请同时指定需要核对的栏位和文件页。");

        bool partial = AllowsPartial(instruction, address);
        if (!partial)
        {
            if (address.HasPages || whole)
                return PackExact(ReadStrictPages(indexed, address.Column, segmentLimit), "已核验的连续文件页", translate, limit, true);
            if (ExactRequest.IsMatch(instruction))
                throw new DocumentPlanningNeededException("请给出引文的完整端点或文件页。");
            return PackExact(RelevantPassages(indexed, SearchQuestion(instruction, selection), 0), "相关原文摘录", translate, limit, false);
        }
        return Synthesize(indexed, instruction, selection, prior, limit, whole || address.HasPages, ct);
    }

    private static bool AllowsPartial(string instruction, TurnAddress address) =>
        !TranslateRequest.IsMatch(instruction) && !ExactRequest.IsMatch(instruction) &&
        !FormulaOrDefinition.IsMatch(instruction) && !address.Anchor.Success && address.Column == 0 &&
        address.Section == null && !address.WantsObject;

    private static int TurnLimit(string? selection)
    {
        int available = MaterialLimit - (selection?.Length ?? 0) - 750;
        if (available <= 512) throw new InvalidDataException("选区太长，无法同时带入文件摘录。请缩小选区。");
        return available;
    }

    private static string ObjectLabel(string type, string id) => type switch
    {
        "figure" => "Figure " + id, "table" => "Table " + id, _ => "Equation (" + id + ")"
    };

    private static IReadOnlyList<string> ExplicitObjectLabels(string text) =>
        NumberedObject.Matches(text).Select(match => ObjectLabel(ObjectType(match.Groups["type"].Value), match.Groups["id"].Value))
            .Distinct(StringComparer.OrdinalIgnoreCase).ToArray();

    private DocumentEvidenceTurn ReadObjects(IReadOnlyList<string> labels, TurnAddress address, bool translate,
        int limit, CancellationToken ct)
    {
        if (labels.Count is < 1 or > 4) throw new InvalidDataException("请指定 1–4 个明确编号的图、表或公式。");
        var indexed = ReadPages(address.First, address.Last, ct);
        bool captionOnly = CaptionOnly.IsMatch(address.Question);
        var evidence = labels.SelectMany(label => LocateVisualObject(indexed, label, address.Column))
            .Select(item => captionOnly && item.ObjectLabel?.StartsWith("Figure ", StringComparison.Ordinal) == true
                ? item with { VisualRegion = null } : item).ToArray();
        return PackExact(evidence, "已核验的文档对象 · " + string.Join("、", labels), translate, limit, false);
    }

    private IReadOnlyList<DocumentExcerpt> ReadStrictPages(PageText[] pagesRead, int column, int limit)
    {
        var all = new List<DocumentExcerpt>();
        foreach (var original in pagesRead)
        {
            var page = column == 0 ? original : original.ForColumn(column);
            all.AddRange(SplitVerified(page, 0, page.Text.Length, limit));
        }
        return all;
    }

    private IReadOnlyList<DocumentExcerpt> ReadSection(PageText[] pagesRead, string section, int column, int limit)
    {
        var lines = pagesRead.Select(page => column == 0 ? page : page.ForColumn(column))
            .SelectMany(page => page.Lines.Select(line => (page, line, number: HeadingNumber.Match(line.Content.Text)))).ToArray();
        var headings = lines.Select((item, index) => (item, index))
            .Where(entry => Readable(entry.item.line, true) && entry.item.number.Success &&
                IsHeading(entry.item.line.Content.Text)).ToArray();
        var starts = headings.Where(entry => entry.item.number.Groups["id"].Value == section).ToArray();
        if (starts.Length != 1) throw new InvalidDataException("未能唯一核对章节标题。请指定更明确的页码或原句。");
        int start = starts[0].index;
        int end = headings.Where(entry => entry.index > start &&
            !entry.item.number.Groups["id"].Value.StartsWith(section + ".", StringComparison.Ordinal))
            .Select(entry => entry.index).DefaultIfEmpty(lines.Length).Min();
        // Include intermediate pages even when PDFium produced no lines for them.
        int firstPage = lines[start].page.Number;
        int lastPage = end < lines.Length ? lines[end].page.Number : pagesRead[^1].Number;
        var result = new List<DocumentExcerpt>();
        foreach (var original in pagesRead.Where(page => page.Number >= firstPage && page.Number <= lastPage))
        {
            var page = column == 0 ? original : original.ForColumn(column);
            int lo = page.Number == firstPage ? lines[start].line.Start : 0;
            int hi = page.Number == lastPage && end < lines.Length && lines[end].page.Number == lastPage
                ? lines[end].line.Start : page.Text.Length;
            if (hi == 0 && end < lines.Length && page.Number == lastPage) continue;
            result.AddRange(SplitVerified(page, lo, hi, limit));
        }
        return result;
    }

    private List<DocumentExcerpt> SplitVerified(PageText page, int start, int end, int limit, bool isolated = false)
    {
        _ = VerifiedExcerpt(page, start, end, mayUseIsolatedLine: isolated);
        int capacity = limit - 100;
        var result = new List<DocumentExcerpt>();
        while (start < end)
        {
            int cut = end;
            if (end - start > capacity)
            {
                cut = page.Text.LastIndexOf('\n', start + capacity, capacity);
                if (cut <= start) throw new InvalidDataException("原文单行超过会话容量。请缩小范围并核对原页。");
            }
            result.Add(VerifiedExcerpt(page, start, cut, mayUseIsolatedLine: isolated));
            start = cut + 1;
        }
        return result;
    }

    private static int EvidenceCost(DocumentExcerpt item) => item.Text.Length + 100;

    private static DocumentEvidenceTurn PackExact(IReadOnlyList<DocumentExcerpt> passages, string scope,
        bool translate, int limit, bool canSegment)
    {
        if (passages.Count == 0) throw new InvalidDataException("未取得可核对的原文。");
        int packetLimit = canSegment ? Math.Min(limit, translate ? TranslationSegmentLimit : AnalysisSegmentLimit) : limit;
        if (passages.Sum(EvidenceCost) <= packetLimit)
            return new([passages], [], scope, IsTranslation: translate);
        if (!canSegment)
            throw new InvalidDataException("核对后的材料超出单次容量。请缩小问题范围。");
        return new(Partition(passages, packetLimit), [], scope, IsTranslation: translate);
    }

    private static IReadOnlyList<IReadOnlyList<DocumentExcerpt>> Partition(IEnumerable<DocumentExcerpt> passages, int limit)
    {
        var segments = new List<IReadOnlyList<DocumentExcerpt>>();
        var current = new List<DocumentExcerpt>();
        int size = 0;
        foreach (var passage in passages)
        {
            int cost = EvidenceCost(passage);
            if (cost > limit) throw new InvalidDataException("原文片段超过单次容量。请缩小范围。");
            if (size + cost > limit)
            {
                segments.Add(current);
                current = new();
                size = 0;
            }
            current.Add(passage);
            size += cost;
        }
        if (current.Count > 0) segments.Add(current);
        if (segments.Count > MaxTurnSegments)
            throw new InvalidDataException($"材料需要超过 {MaxTurnSegments} 段处理。请缩小请求范围。");
        return segments;
    }

    private DocumentEvidenceTurn Synthesize(PageText[] indexed, string question, string? selection,
        IReadOnlyList<DocumentExcerpt>? prior, int limit, bool preferOverview, CancellationToken ct)
    {
        var missing = indexed.Where(page => !page.Lines.Any(line => Readable(line, true))).Select(page => page.Number).ToArray();
        var incomplete = indexed.Where(page => !missing.Contains(page.Number) &&
            (page.Ambiguous || page.Lines.Any(line => !string.IsNullOrWhiteSpace(line.Content.Text) && !Readable(line, true))))
            .Select(page => page.Number).ToArray();
        bool hasGaps = missing.Length + incomplete.Length > 0;
        var omittedEquations = new HashSet<int>();
        var passages = new List<DocumentExcerpt>();
        foreach (var page in indexed)
        {
            ct.ThrowIfCancellationRequested();
            var fragments = page.Lines;
            int start = -1, end = -1;
            foreach (var line in fragments)
            {
                bool math = hasGaps && IsEquationLine(line.Content.Text);
                if (math) omittedEquations.Add(page.Number);
                if (Readable(line, true) && !math)
                {
                    if (start >= 0 && (line.End - start > 1400 || page.Ambiguous))
                    {
                        passages.Add(VerifiedExcerpt(page, start, end, mayUseIsolatedLine: page.Ambiguous));
                        start = -1;
                    }
                    if (start < 0) start = line.Start;
                    end = line.End;
                }
                else if (start >= 0 && !string.IsNullOrWhiteSpace(line.Content.Text))
                {
                    passages.Add(VerifiedExcerpt(page, start, end, mayUseIsolatedLine: page.Ambiguous));
                    start = -1;
                }
            }
            if (start >= 0) passages.Add(VerifiedExcerpt(page, start, end, mayUseIsolatedLine: page.Ambiguous));
        }
        if (passages.Count == 0)
            throw new InvalidDataException("没有可核对的正文。请先识别扫描页，或缩小要读取的范围。");

        bool fits = passages.Sum(EvidenceCost) <= limit;
        IReadOnlyList<DocumentExcerpt> chosen = fits
            ? passages : SamplePassages(passages, question, selection, prior, limit, preferOverview);
        if (chosen.Count == 0)
            throw new InvalidDataException("没有足够的可核对文件摘录。");
        if (hasGaps)
        {
            var body = chosen.Select(item => (item.Page, Length: BodyLength(item.Text))).Where(item => item.Length > 0).ToArray();
            if (body.Sum(item => item.Length) < MinimumPartialBody ||
                (fits && body.Select(item => item.Page).Distinct().Count() * 2 < indexed.Length))
                throw new InvalidDataException("部分原文无法核对，剩余正文不足以支持总结或分析。请缩小范围或核对原页。");
        }

        var gaps = new List<string>();
        if (missing.Length > 0) gaps.Add("文件第 " + PageList(missing) + " 页正文不可读");
        if (incomplete.Length > 0) gaps.Add("文件第 " + PageList(incomplete) + " 页部分字形或栏序不可核验");
        if (omittedEquations.Count > 0) gaps.Add("文件第 " + PageList(omittedEquations) + " 页行间公式原式待核对");
        bool sampled = !fits;
        string scope = sampled
            ? (preferOverview ? "按文件页取代表性原文 · 未覆盖完整正文" : "与问题相关的独立摘录 · 未覆盖完整正文")
            : "按文件页序带入已核验正文";
        if (gaps.Count > 0) scope += " · 部分证据 · " + BoundPlanningText(string.Join("；", gaps), 350);
        string? guidance = gaps.Count == 0 ? null :
            "【本轮仅有部分证据】仅用所附已核验摘录总结或分析，并说明结论的适用范围。未核验：" +
            BoundPlanningText(string.Join("；", gaps), 390) + "。不要补写缺失内容，也不要声称覆盖完整原文。";
        if (sampled)
            guidance = (guidance == null ? "" : guidance + "\n") + "本轮提供代表性或相关原文摘录。请引用对应文件页，说明摘录范围。";
        return new([chosen], missing.Concat(incomplete).Distinct().Order().ToArray(), scope, guidance);
    }

    private static IReadOnlyList<DocumentExcerpt> SamplePassages(List<DocumentExcerpt> passages, string question,
        string? selection, IReadOnlyList<DocumentExcerpt>? prior, int limit, bool preferOverview)
    {
        var query = SearchQuestion(question, selection);
        var terms = SearchTerms(query).Concat(Concepts
                .Where(group => group.Any(term => query.Contains(term, StringComparison.OrdinalIgnoreCase))).SelectMany(group => group))
            .Distinct(StringComparer.OrdinalIgnoreCase).Take(90).ToArray();
        var accessiblePrior = prior?.Where(item => item.Fingerprint == passages[0].Fingerprint).Select(item => item.Page).ToHashSet();
        var ranked = passages.Select((item, order) => (item, order,
            lexical: terms.Count(term => item.Text.Contains(term, StringComparison.OrdinalIgnoreCase)),
            nearby: accessiblePrior?.Contains(item.Page) == true ? 1 : 0)).ToArray();
        IEnumerable<(DocumentExcerpt item, int order, int lexical, int nearby)> ordered;
        if (!preferOverview && ranked.Any(value => value.lexical > 0 || value.nearby > 0))
            ordered = ranked.OrderByDescending(value => value.lexical * 2 + value.nearby).ThenBy(value => value.order);
        else
        {
            var groups = ranked.Where(value => EvidenceCost(value.item) <= limit).GroupBy(value => value.item.Page)
                .Select(group => group.ToArray()).ToArray();
            if (groups.Length == 0) return [];
            int firstExcerptCost = groups.Max(group => EvidenceCost(group[0].item));
            int count = Math.Min(groups.Length, Math.Max(1, limit / Math.Max(750, firstExcerptCost)));
            var spread = Enumerable.Range(0, count).Select(slot => groups[slot * (groups.Length - 1) / Math.Max(1, count - 1)]).ToArray();
            ordered = Enumerable.Range(0, spread.Max(group => group.Length))
                .SelectMany(index => spread.Where(group => index < group.Length).Select(group => group[index]));
        }
        int size = 0;
        var chosen = new List<(DocumentExcerpt item, int order)>();
        foreach (var entry in ordered)
        {
            int cost = EvidenceCost(entry.item);
            if (size + cost > limit) continue;
            chosen.Add((entry.item, entry.order));
            size += cost;
        }
        return chosen.OrderBy(value => value.order).Select(value => value.item).ToArray();
    }

    private DocumentEvidenceTurn ApplyPlan(JsonElement plan, string question, string? selection, DocumentEvidenceTurn? prior,
        bool includingUserImages, CancellationToken ct)
    {
        var instruction = Instruction(question, includingUserImages);
        var address = Address(instruction);
        bool translate = TranslateRequest.IsMatch(instruction);
        bool exact = translate || ExactRequest.IsMatch(instruction);
        bool partial = AllowsPartial(instruction, address);
        string action = PlanText(plan, "action", 20);
        int limit = TurnLimit(selection);
        var segmentLimit = Math.Min(limit, translate ? TranslationSegmentLimit : AnalysisSegmentLimit);
        if (action == "clarify") throw new InvalidDataException(PlanText(plan, "question", 512));
        if (address.Anchor.Success || address.HasPages || address.Section != null || address.Column != 0 ||
            OnlySelection.IsMatch(instruction) || WholeDocument.IsMatch(instruction))
            return RetrieveTurn(question, selection, null, includingUserImages, ct);
        bool priorVerified = prior != null && prior.Segments.Count > 0 && prior.Segments.SelectMany(items => items)
            .All(item => item.Fingerprint == Fingerprint && item.Page >= 1 && item.Page <= PageCount);
        if (address.WantsObject && action is "range" or "pages")
            throw new InvalidDataException("请用明确编号定位文档对象。文件页摘录不能代替图、表或公式。");

        switch (action)
        {
            case "selection":
                throw new InvalidDataException("文档查询不能把本轮文件取证替换为仅阅读选区。");
            case "useEvidence":
                return priorVerified && !prior!.RequiresMoreEvidence ? prior :
                    throw new InvalidDataException("当前没有足够的同一文件证据供回答。");
            case "object":
                var labels = ExplicitObjectLabels(PlanText(plan, "reference", 120));
                var explicitLabels = ExplicitObjectLabels(instruction);
                if (explicitLabels.Any(label => !labels.Contains(label, StringComparer.OrdinalIgnoreCase)))
                    throw new InvalidDataException("文档查询遗漏了用户明确指定的图、表或公式。");
                return ReadObjects(labels, address, translate, limit, ct);
            case "range":
                string start = PlanText(plan, "start", 1024), end = PlanText(plan, "end", 1024);
                IEnumerable<string> grounding = new[] { instruction, selection ?? "" };
                if (priorVerified) grounding = grounding.Concat(prior!.Segments.SelectMany(items => items).Select(item => item.Text));
                if (!GroundedAnchor(start, grounding) || !GroundedAnchor(end, grounding))
                    throw new InvalidDataException("无法将取证端点与问题、选区或已核对的原文逐字核验。");
                var range = ReadPlannedPages(plan, require: false, ct);
                return PackExact(ExactPassage(range, start, end, 0, PlanFlag(plan, "excludeStart"), PlanFlag(plan, "excludeEnd"),
                    segmentLimit), "已核验的连续原文范围", translate, limit, true);
            case "pages":
                var pagesRead = ReadPlannedPages(plan, require: true, ct);
                return partial ? Synthesize(pagesRead, instruction, selection, null, limit, true, ct) :
                    PackExact(ReadStrictPages(pagesRead, 0, segmentLimit), "已核验的连续文件页", translate, limit, true);
            case "whole":
                throw new InvalidDataException("本轮没有明确要求发送整篇文件。请指定要读取的范围。");
            case "search":
            case "combined":
                if (action == "combined" && string.IsNullOrWhiteSpace(selection))
                    throw new InvalidDataException("本轮没有可对照的选区。");
                string search = PlanText(plan, "query", 512);
                var indexed = ReadPages(1, PageCount, ct);
                IReadOnlyList<DocumentExcerpt> hits = RelevantPassages(indexed, SearchQuestion(search, selection), 0);
                if (priorVerified && action == "search") hits = prior!.Segments.SelectMany(items => items).Concat(hits)
                    .DistinctBy(item => (item.Page, item.Text)).ToArray();
                var evidence = PackExact(hits, "相关证据摘录 · 未覆盖完整正文", translate, limit, false);
                return evidence with { RequiresMoreEvidence = exact || address.WantsObject || FormulaOrDefinition.IsMatch(instruction) };
            default:
                throw new InvalidDataException("科研桥返回了无法执行的取证操作。");
        }
    }

    private PageText[] ReadPlannedPages(JsonElement plan, bool require, CancellationToken ct)
    {
        int PageNumber(string name, int fallback)
        {
            if (!plan.TryGetProperty(name, out var field) && !require) return fallback;
            if (field.ValueKind == JsonValueKind.Number && field.TryGetInt32(out int value) && value >= 1 && value <= PageCount)
                return value;
            throw new InvalidDataException("取证计划的页码超出当前 PDF。");
        }
        int first = PageNumber("pageStart", 1), last = PageNumber("pageEnd", PageCount);
        if (last < first) throw new InvalidDataException("取证计划中的文件页序反向。");
        return ReadPages(first, last, ct);
    }

    private static bool GroundedAnchor(string anchor, IEnumerable<string> sources)
    {
        string Normalized(string value) => FoldWhitespace(value.Normalize(NormalizationForm.FormKC)).Value;
        string exact = Normalized(anchor);
        return exact.Length > 0 && sources.Any(source => Normalized(source).Contains(exact, StringComparison.OrdinalIgnoreCase));
    }

    private static string PlanText(JsonElement plan, string key, int limit)
    {
        if (!plan.TryGetProperty(key, out var value) || value.ValueKind != JsonValueKind.String ||
            value.GetString() is not { Length: > 0 } text || text.Length > limit || text.Contains('\0') || string.IsNullOrWhiteSpace(text))
            throw new InvalidDataException("科研桥返回的取证参数为空或无效。");
        return text;
    }

    private static bool PlanFlag(JsonElement plan, string key)
    {
        if (!plan.TryGetProperty(key, out var value)) return false;
        if (value.ValueKind is JsonValueKind.True or JsonValueKind.False) return value.GetBoolean();
        throw new InvalidDataException("科研桥返回的端点设置无效。");
    }

    private static string SearchQuestion(string question, string? selection) =>
        string.IsNullOrWhiteSpace(selection) ? question : question + "\n" + BoundPlanningText(selection, 1200);

    private static bool Readable(TextLine line, bool pdf) => !line.Content.Fault &&
        !string.IsNullOrWhiteSpace(line.Content.Text) && (!pdf || line.Content.Region != null);

    private static bool IsHeading(string line) => line.Length <= 110 && Heading.IsMatch(line);

    private static bool IsEquationLine(string text) => EquationTag.IsMatch(text.Trim()) ||
        (FormulaShape.IsMatch(text) && EquationInk.IsMatch(text));

    private static int BodyLength(string text) => text.Split('\n').Where(line =>
        !IsHeading(line) && !IsEquationLine(line) &&
        !(NumberedObject.Match(line.TrimStart()) is { Success: true, Index: 0 }))
        .Sum(line => line.EnumerateRunes().Count(Rune.IsLetterOrDigit));

    private static string PageList(IEnumerable<int> pages)
    {
        var numbers = pages.Distinct().Order().ToArray();
        var groups = new List<string>();
        for (int i = 0; i < numbers.Length; i++)
        {
            int first = numbers[i];
            while (i + 1 < numbers.Length && numbers[i + 1] == numbers[i] + 1) i++;
            groups.Add(first == numbers[i] ? first.ToString(CultureInfo.InvariantCulture) : $"{first}–{numbers[i]}");
        }
        return string.Join("、", groups);
    }

    internal static string BoundPlanningText(string value, int limit)
    {
        string clean = value.Replace("\0", "", StringComparison.Ordinal).Trim();
        if (clean.Length <= limit) return clean;
        return clean[..(char.IsHighSurrogate(clean[limit - 1]) ? limit - 1 : limit)];
    }
}
