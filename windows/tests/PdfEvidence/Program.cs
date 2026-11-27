using System.Globalization;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using ResearchCompanion.Windows;

if (args.Length != 1 || !File.Exists(args[0]))
{
    Console.Error.WriteLine("Pass the path to the pinned PDFium shared library for this host.");
    return 2;
}
var library = NativeLibrary.Load(Path.GetFullPath(args[0]));
NativeLibrary.SetDllImportResolver(typeof(PdfEvidence).Assembly, (name, _, _) =>
    name == "pdfium.dll" ? library : IntPtr.Zero);

var scratch = Directory.CreateTempSubdirectory("rc-pdf-checks-");
try
{
    string Fixture(string file) => Path.Combine(scratch.FullName, file);

    var passage = Fixture("passage.pdf");
    MakePdf(passage, [
        Sheet((60, 717, "RC-WIN: Frozen source one."), (60, 690, "Begin reading at Golden lens."),
            (60, 663, "Middle evidence one.")),
        Sheet((60, 717, "Middle evidence two."), (60, 690, "End at Copper rotation."),
            (60, 663, "RC-WIN: Frozen source two."), (60, 636, "Algorithm 1 initializes a reference point."),
            (60, 609, "Figure 3 compares ordinary evidence with the reference point.")),
        Sheet((60, 717, "End at Copper rotation."), (60, 690, "Repeated end anchor."),
            (60, 663, "Algorithm 10 is described by Figure 30.")),
        "80 200 274 127 re f\n"
    ]);
    var document = await PdfEvidence.OpenAsync(passage);
    Verify(document.PageCount == 4 && document.Title == "Synthetic Transit Evidence", "metadata and page count");
    var page = (await document.RetrieveAsync("读取第 1 页"))[0];
    Verify(page.Page == 1 && page.Text.Contains("Middle evidence one.") && page.Regions.Count == 3,
        "explicit page receipt and three source rows");
    var range = await document.RetrieveAsync("第 1–2 页，从「Golden lens.」到「Copper rotation.」");
    Verify(range.Count == 2 && range[0].Text == "Golden lens.\nMiddle evidence one." &&
        range[1].Text == "Middle evidence two.\nEnd at Copper rotation.", "exact two-page range");
    await Reject(() => document.RetrieveAsync("从「Golden lens.」到「Copper rotation.」"), "多个", "ambiguous anchor");
    await Reject(() => document.RetrieveAsync("从 Golden lens. 到 Copper rotation."), "起止原句", "unparsed range");
    await Reject(() => document.RetrieveAsync("读第 4 页"), "没有可核验", "page without readable text");
    await Reject(() => document.RetrieveAsync("解释公式（1）"), "未能定位", "missing visual target");
    var visual = Fixture("visual.pdf");
    MakePdf(visual, [Sheet((60, 720, "Research fixture"), (55, 405, "Figure 1. Blue sample chart."),
        (70, 280, @"y = 37x + 2        \(3\)"), (55, 170, "Table 2. Fixture results.")) + "0 0 0 rg 85 441 120 175 re f\n"]);
    var figures = await PdfEvidence.OpenAsync(visual);
    var figure = (await figures.RetrieveAsync("解释第 1 页 Figure 1"))[0];
    Verify(figure.VisualRegion != null && figure.Text.Contains("Blue sample chart"), "unique numbered figure and crop");
    var crop = await figures.RenderCropAsync(1, figure.VisualRegion!.Value);
    Verify(crop.Width > 500 && crop.Height > 150 && DarkFraction(crop, new(0.15, 0.15, 0.2, 0.65)) > 0.05,
        "figure crop contains original dark pixels");
    var equation = (await figures.RetrieveAsync("说明公式（3）"))[0];
    Verify(equation.VisualRegion is { Height: < 0.16 } && equation.Text.Contains("37x"), "equation region and exact registered text");
    var separated = Fixture("separated-equation.pdf");
    const string wideEquation = "BT /F1 24 Tf 110 500 Td (y = 37x + 2        \\(3\\)) Tj ET\n";
    const string separateEquationObjects = "BT /F1 15 Tf 54 500 Td (y = 37 * x + 2) Tj ET\n" +
        "BT /F1 15 Tf 429 500 Td (\\(4\\)) Tj ET\n";
    MakePdf(separated, [wideEquation, separateEquationObjects]);
    var displays = await PdfEvidence.OpenAsync(separated);
    var wide = (await displays.RetrieveAsync("说明第 1 页公式（3）"))[0];
    Verify(wide.Text == "y = 37x + 2 (3)" && wide.Regions.Count == 2 &&
        wide.VisualRegion is { Height: < 0.12 } wideCrop &&
        wideCrop.X < wide.Regions[0].X && wideCrop.Right > wide.Regions[1].Right,
        "one PDF text object with a right-separated equation number");
    var distinctObjects = (await displays.RetrieveAsync("Explain equation (4)"))[0];
    Verify(distinctObjects.Text == "y = 37 * x + 2 (4)" && distinctObjects.Regions.Count == 2 &&
        distinctObjects.VisualRegion is { Height: < 0.12 } rowCrop && rowCrop.Right > 0.72,
        "two same-baseline PDF text objects provide a complete equation crop");
    await Reject(() => displays.RetrieveAsync("说明第 1 页左栏公式（3）"), "未能定位",
        "a separated equation cannot establish an explicit column");

    Verify((await figures.RetrieveAsync("解释 Table 2"))[0].VisualRegion != null, "numbered table region");
    var recognized = await PdfEvidence.OpenAsync(passage, recognize: (preview, ct) =>
        Task.FromResult<IReadOnlyList<PdfOcrLine>>([new("OCR orchard sample", new(0.14, 0.20, 0.56, 0.04))]));
    var recognition = await recognized.RecognizeMissingPagesAsync();
    var scanned = (await recognized.RetrieveAsync("读第 4 页"))[0];
    Verify(recognition is { MissingPages: 1, RecognizedPages: 1 } && scanned.Recognition != null &&
        scanned.Text == "OCR orchard sample" && scanned.Regions.Count == 1, "OCR source survives indexing and carries geometry");
    await Reject(() => document.RetrieveAsync("第 1 页和第 2 页"), "多个页段", "disjoint scope");
    await Reject(() => document.RetrieveAsync("读取第 1、3 页"), "多个页段", "compact disjoint scope");
    Verify((await document.RetrieveAsync("读取首页"))[0].Page == 1, "first page alias");
    Verify((await document.RetrieveAsync("查找 Frozen source"))[0].Text.Contains("Frozen source"), "lexical excerpts");
    const string ordinaryQuestion = "解释一下算法1和图3";
    const string referenceFollowUp = "固定参考点u如何确定，人为规定？";
    Verify(!PdfEvidence.RequiresExactEvidence(ordinaryQuestion) && !PdfEvidence.RequiresExactEvidence(referenceFollowUp) &&
        !PdfEvidence.RequiresExactEvidence("无需翻译，解释图3") &&
        !PdfEvidence.RequiresExactEvidence("介绍这个翻译方法的限制"), "discussion questions stay outside strict evidence policy");
    Verify(PdfEvidence.RequiresExactEvidence("逐字引用图3的图注") &&
        PdfEvidence.RequiresExactEvidence("精确引用论文对 u 的定义") &&
        PdfEvidence.RequiresExactEvidence("将第 4 页逐段译成中文") &&
        PdfEvidence.RequiresExactEvidence("只依据本文给出回答") &&
        PdfEvidence.RequiresExactEvidence("从「Golden lens.」到「Copper rotation.」"),
        "strict policy includes exact quotation, translation, source-only and anchored ranges");
    var discussion = await document.RetrieveForDiscussionAsync(ordinaryQuestion);
    Verify(discussion.Segments[0].Any(item => item.Page == 2 && item.ObjectLabel == "Figure 3" && item.VisualRegion != null) &&
        discussion.Segments[0].Any(item => item.Page == 2 && item.Text.Contains("Algorithm 1") &&
            item.Text.Contains("Figure 3") && item.Regions.Count > 0), "discussion combines .4.2 crop and related verified source text");
    Verify(discussion.Segments[0].All(item => item.Page != 3), "numbered discussion cannot match a different reference prefix");
    var reference = await document.RetrieveForDiscussionAsync(referenceFollowUp);
    Verify(reference.Segments[0].Any(item => item.Page == 2 && item.Text.Contains("reference point") &&
        item.Fingerprint == document.Fingerprint), "cross-language follow-up obtains current version-bound excerpts");
    var mixedScope = await document.RetrieveForDiscussionAsync("概括第 3–4 页");
    Verify(mixedScope.Segments[0].All(item => item.Page == 3) && mixedScope.MissingPages.SequenceEqual([4]),
        "ordinary page discussion keeps only available source in the requested scope");
    Verify((await document.RetrieveForDiscussionAsync("固定参考轴和训练批次的关系？")).Segments.Count == 0 &&
        (await document.RetrieveForDiscussionAsync("说明第 4 页")).Segments.Count == 0,
        "absence of evidence keeps a discussion source-less");
    await Reject(() => document.RetrieveForDiscussionAsync("逐字引用图3的图注"), "精确核对",
        "discussion fallback cannot admit an exact request");
    await Reject(() => document.RetrieveTurnAsync("逐字摘录从「THE ORCHARD CONTROL TAG 781321」到「UNPRINTED MOREAU SENTINEL 845917」的原文。"),
        "未匹配", "exact absent anchors fail closed");
    var partialTurn = await document.RetrieveTurnAsync("总结全文的研究发现");
    Verify(partialTurn.Segments.Count == 1 && partialTurn.MissingPages.SequenceEqual([4]) &&
        partialTurn.Segments[0].Select(excerpt => excerpt.Page).SequenceEqual([1, 2, 3]) &&
        partialTurn.Coverage.Contains("部分证据") && partialTurn.Guidance?.Contains("第 4 页") == true,
        "ordinary synthesis submits verified material only and labels missing pages");
    await Reject(() => document.RetrieveTurnAsync("逐字翻译第 1–4 页"), "没有可核验",
        "exact translation refuses a gap in the requested pages");
    await Reject(() => document.RetrieveTurnAsync("说明第 4 页"), "没有可核对",
        "partial analysis refuses a scope with no verified prose");
    var direct = await figures.RetrieveTurnAsync("说明公式（3）");
    var captionOnly = await figures.RetrieveTurnAsync("只翻译 Figure 1 的图注");
    Verify(captionOnly.Segments[0].Single().VisualRegion == null && captionOnly.Segments[0].Single().Regions.Count == 1,
        "explicit caption-only reading excludes the original graphic but retains the jump");
    var followUp = await figures.RetrieveTurnAsync("这个公式有什么作用？", priorEvidence: direct.Segments[0]);
    Verify(followUp.Segments[0].Single().ObjectLabel == "Equation (3)" &&
        followUp.Segments[0].Single().VisualRegion == direct.Segments[0].Single().VisualRegion,
        "same attached file re-resolves a prior object with original crop");
    try
    {
        await document.RetrieveTurnAsync("这个公式有什么作用？", priorEvidence: direct.Segments[0]);
        throw new InvalidOperationException("FAIL follow-up borrowed another fingerprint");
    }
    catch (DocumentPlanningNeededException)
    {
        Console.WriteLine("PASS object follow-up does not borrow another fingerprint");
    }

    var imageClause = await document.RetrieveTurnAsync(
        "Translate the attached image. Summarize the PDF.", includingUserImages: true);
    Verify(!imageClause.IsTranslation && imageClause.MissingPages.SequenceEqual([4]),
        "image-only command does not downgrade partial PDF evidence");
    var selectedOnly = await document.RetrieveTurnAsync("只用本次选区", selection: "Golden lens.");
    Verify(selectedOnly.SelectionOnly && selectedOnly.Segments.Count == 0,
        "explicit selection-only turn does not read document text");

    var planning = await document.PlanningDocumentAsync("Golden lens.", ["Frozen source"], null, CancellationToken.None);
    Verify((string?)planning["id"] == document.Fingerprint && (int?)planning["pages"] == 4 &&
        !planning.ContainsKey("path"), "planner receives verified identity and no local file path");
    using var searchPlan = JsonDocument.Parse("""{"action":"search","query":"Frozen source","needsMore":true}""");
    var feedback = await document.ApplyPlanningResultAsync(searchPlan.RootElement,
        "Translate the reading", "Golden lens. Copper rotation.");
    Verify(feedback.RequiresMoreEvidence && feedback.PlanningFeedback.StartsWith("【已读取的证据】"),
        "planner search is feedback and not a final exact translation");
    using var useEvidencePlan = JsonDocument.Parse("""{"action":"useEvidence"}""");
    await Reject(() => document.ApplyPlanningResultAsync(useEvidencePlan.RootElement, "Translate the reading", prior: feedback),
        "没有足够", "unverified translation scope cannot be promoted to final evidence");
    using var rangePlan = JsonDocument.Parse("""
        {"action":"range","start":"Golden lens.","end":"Copper rotation.","pageStart":1,"pageEnd":2,"excludeStart":true,"excludeEnd":true}
        """);
    var plannedRange = await document.ApplyPlanningResultAsync(rangePlan.RootElement,
        "Translate the reading", "Golden lens. Copper rotation.", feedback);
    Verify(!plannedRange.RequiresMoreEvidence && plannedRange.IsTranslation &&
        plannedRange.Segments[0].Select(excerpt => excerpt.Text).SequenceEqual(["Middle evidence one.", "Middle evidence two.\nEnd at"]),
        "grounded planner endpoints and exact exclusion re-read original pages");
    await Reject(() => document.ApplyPlanningResultAsync(rangePlan.RootElement, "Translate the reading"),
        "逐字核验", "plan cannot invent an endpoint without grounding");
    using var unrelatedPagesPlan = JsonDocument.Parse("""{"action":"pages","pageStart":3,"pageEnd":4}""");
    var preservedScope = await document.ApplyPlanningResultAsync(unrelatedPagesPlan.RootElement, "逐字翻译第 1–2 页");
    Verify(preservedScope.Segments[0].Select(excerpt => excerpt.Page).SequenceEqual([1, 2]),
        "planner may not broaden a user's explicit native page scope");

    var sectionsPath = Fixture("verified-sections.pdf");
    MakePdf(sectionsPath, [Sheet((60, 730, "1 Introduction"), (60, 705, "Excluded opening."),
        (60, 675, "2 Results"), (60, 650, "Included first result.")),
        Sheet((60, 730, "2.1 Detailed results"), (60, 705, "Included detailed result."),
            (60, 675, "3 Conclusion"), (60, 650, "Excluded conclusion."))]);
    var sections = await PdfEvidence.OpenAsync(sectionsPath);
    var section = await sections.RetrieveTurnAsync("翻译第 2 章");
    Verify(section.Segments[0].Select(item => item.Page).SequenceEqual([1, 2]) &&
        section.Segments[0].All(item => item.Text.Contains("Included") && !item.Text.Contains("Excluded")),
        "numbered heading anchors preserve sections and nested headings");

    var longPath = Fixture("long-evidence.pdf");
    MakePdf(longPath, Enumerable.Range(1, 18).Select(number => Sheet((487, 34, $"Physical page {number}")) + Sheet(Enumerable.Range(1, 24)
        .Select(row => (60, 755 - row * 27,
            $"Page {number:D2} row {row:D2} orchard results for the researched study keep the original data unchanged."))
        .ToArray())).ToArray());
    var longFile = await PdfEvidence.OpenAsync(longPath);
    var overview = await longFile.RetrieveTurnAsync("概括整篇论文的结果");
    Verify(overview.Segments.Count == 1 && overview.Coverage.Contains("未覆盖完整正文") &&
        overview.Segments[0].Any(item => item.Page == 1) && overview.Segments[0].Any(item => item.Page == 18),
        "ordinary long-paper overview favors a single representative turn");
    var longAnalysis = await longFile.RetrieveTurnAsync("完整读取第 1–4 页原文，不得遗漏，并总结所有证据的主要结果。");
    Verify(longAnalysis.Segments.Count == 2 && longAnalysis.Segments.All(segment =>
        segment.Sum(item => item.Text.Length + 100) <= 7_200) &&
        longAnalysis.Segments.SelectMany(segment => segment).Last().Text.EndsWith("Physical page 4"),
        "long exact analysis splits in two and places PDF page furniture in printed order");
    var longTranslation = await longFile.RetrieveTurnAsync("Translate the whole PDF.");
    Verify(longTranslation.Segments.Count > 1 && longTranslation.Segments.All(segment =>
        segment.Sum(item => item.Text.Length + 100) <= 10_000) &&
        longTranslation.Segments.SelectMany(segment => segment).Select(item => item.Page)
            .Distinct().SequenceEqual(Enumerable.Range(1, 18)),
        "complete long translation has ordered bounded segments without truncation");

    var aligned = Fixture("columns.pdf");
    var columnContent = Sheet(
        (60, 750, "Aligned columns in a synthetic fixture."),
        (60, 715, "Left: alpha creates sufficient width."), (334, 715, "Right: violet creates sufficient width."),
        (60, 692, "Left: bravo has ordinary text."), (334, 692, "Right: violet has ordinary text."),
        (60, 669, "Left: charlie has useful evidence."), (334, 669, "Right: violet has useful evidence."),
        (60, 646, "Left: delta finishes the left block."), (334, 646, "Right: violet finishes the right block."));
    MakePdf(aligned, [columnContent]);
    var columns = await PdfEvidence.OpenAsync(aligned);
    var ordered = (await columns.RetrieveAsync("读取第 1 页"))[0];
    Verify(ordered.Text.IndexOf("Left: delta", StringComparison.Ordinal) <
        ordered.Text.IndexOf("Right: violet", StringComparison.Ordinal), "interleaved objects restored by column");
    var left = (await columns.RetrieveAsync("读取第 1 页左栏"))[0];
    Verify(left.Text.Contains("Left: charlie") && !left.Text.Contains("Right"), "left column isolation");
    var crossColumn = Fixture("column-equation.pdf");
    MakePdf(crossColumn, [columnContent + separateEquationObjects.Replace(" 500 Td", " 620 Td", StringComparison.Ordinal)]);
    var columnEquation = await PdfEvidence.OpenAsync(crossColumn);
    await Reject(() => columnEquation.RetrieveAsync("Explain equation (4)"), "未能定位",
        "separated runs cannot bind a number across a detected column layout");

    var mixed = Fixture("mixed-layout.pdf");
    MakePdf(mixed, [columnContent + Sheet((60, 680,
        "This inserted object spans the gutter and separates two different layout bands on the same sheet."))]);
    var complicated = await PdfEvidence.OpenAsync(mixed);
    await Reject(() => complicated.RetrieveAsync("读取第 1 页"), "栏序", "spanning object blocks ordering");
    var mappedNeighbors = await complicated.RetrieveForDiscussionAsync("Explain charlie");
    Verify(mappedNeighbors.Segments[0].Count > 1 && mappedNeighbors.Segments[0].Any(item => item.Text.Contains("charlie")) &&
        mappedNeighbors.Segments[0].All(item => !item.Text.Contains("Right") && item.Regions.Count == 1),
        "ambiguous-page discussion keeps independently mapped neighbors without traversing columns");

    var rotated = Fixture("rotated.pdf");
    MakePdf(rotated, [Sheet((95, 150, "Offset and rotated marker."))], "[0 0 420 325]",
        "/CropBox [50 40 380 300] /Rotate 90");
    var geometry = await PdfEvidence.OpenAsync(rotated);
    var region = (await geometry.RetrieveAsync("读取第 1 页"))[0].Regions[0];
    var preview = await geometry.RenderPageAsync(1, width: 460);
    Verify(preview.Width == 460 && preview.Height > preview.Width && preview.Stride == preview.Width * 4 &&
        DarkFraction(preview, region) > 0.04, "rotated CropBox source rectangle agrees with preview pixels");

    var recoveryDir = Fixture("recovery");
    var recovery = new SessionRecovery(recoveryDir, "desktop-target-a", "workspace-a", "session-a");
    var scopedModel = new SavedResearchModel("deepseek-account", "deepseek-v4-flash", null);
    var savedFile = new SavedResearchFile(passage, document.Fingerprint, RecognizeScans: true, Include: false);
    recovery.Update(_ => new(scopedModel, savedFile));
    var reloaded = new SessionRecovery(recoveryDir, "desktop-target-a", "workspace-a", "session-a").Read();
    Verify(reloaded.Model == scopedModel && reloaded.File == savedFile &&
        reloaded.Model.Matches("deepseek-account", "deepseek-v4-flash", null) &&
        !reloaded.Model.Matches("deepseek-account", "deepseek-v4-flash", "high"),
        "restart record retains exact session model and disabled material context");
    Verify(new SessionRecovery(recoveryDir, "desktop-target-b", "workspace-a", "session-a").Read() == new SavedResearchSession() &&
        new SessionRecovery(recoveryDir, "desktop-target-a", "workspace-b", "session-a").Read() == new SavedResearchSession() &&
        new SessionRecovery(recoveryDir, "desktop-target-a", "workspace-a", "session-b").Read() == new SavedResearchSession() &&
        new SessionRecovery(recoveryDir, "desktop-target-a", "workspace-a", null).Read() == new SavedResearchSession(),
        "explicit selection never survives a workspace, host or session change");
    recovery.Update(state => state with { File = null });
    Verify(recovery.Read() == new SavedResearchSession(scopedModel), "detaching a file retains only the scoped model");
    if (OperatingSystem.IsWindows())
    {
        Task<IReadOnlyList<PdfOcrLine>> Ocr(PagePreview preview, CancellationToken ct) =>
            Task.FromResult<IReadOnlyList<PdfOcrLine>>([new("Restored local OCR", new(0.14, 0.20, 0.56, 0.04))]);
        var reopened = await SessionRecovery.OpenFileAsync(savedFile, Ocr, CancellationToken.None);
        var restoredOcr = (await reopened.RetrieveAsync("读第 4 页"))[0];
        Verify(reopened.Fingerprint == document.Fingerprint && restoredOcr.Text == "Restored local OCR" &&
            restoredOcr.Recognition != null, "matching local PDF restores its OCR request");
        await Reject(() => SessionRecovery.OpenFileAsync(savedFile with { Fingerprint = new string('0', 64) },
            Ocr, CancellationToken.None), "内容已更新", "changed PDF is excluded before recognition");
        await Reject(() => SessionRecovery.OpenFileAsync(savedFile with { Path = Path.GetFileName(passage) },
            Ocr, CancellationToken.None), "不再是本机", "relative reference is excluded from restore");
        await Reject(() => SessionRecovery.OpenFileAsync(savedFile with { Path = passage + ":alternate" },
            Ocr, CancellationToken.None), "不再是本机", "alternate stream is excluded from restore");
    }

    var notes = Fixture("notes.md");
    await File.WriteAllTextAsync(notes, "# A test\n科研摘要：线索原文。\n准确核验。\n");
    var markdown = await PdfEvidence.OpenAsync(notes);
    var excerpt = (await markdown.RetrieveAsync("从「线索」到「核验。」"))[0];
    Verify(excerpt.Text == "线索原文。\n准确核验。" && excerpt.Regions.Count == 0,
        "Unicode text anchors with no PDF coordinates");
    await File.WriteAllTextAsync(notes, "# A test\n科研摘要：线索原文。\n改后核验。\n");
    await Reject(() => markdown.RetrieveAsync("概括"), "内容已更新", "same-length edits invalidate a receipt");
    Verify((await markdown.RetrieveForDiscussionAsync("概括")).Segments.Count == 0,
        "changed attachment never contributes stale discussion evidence");
    return 0;
}
finally
{
    scratch.Delete(recursive: true);
}

static void Verify(bool passed, string name)
{
    if (!passed) throw new InvalidOperationException("FAIL " + name);
    Console.WriteLine("PASS " + name);
}

static async Task Reject(Func<Task> request, string messageFragment, string name)
{
    try { await request(); }
    catch (InvalidDataException error) when (error.Message.Contains(messageFragment, StringComparison.Ordinal))
    {
        Console.WriteLine("PASS " + name);
        return;
    }
    throw new InvalidOperationException("FAIL " + name);
}

static double DarkFraction(PagePreview preview, PdfRegion region)
{
    var dark = 0;
    var total = 0;
    for (var y = (int)(region.Y * preview.Height); y < (int)(region.Bottom * preview.Height); y++)
    for (var x = (int)(region.X * preview.Width); x < (int)(region.Right * preview.Width); x++)
    {
        if (preview.Pixels[y * preview.Stride + x * 4] < 100) dark++;
        total++;
    }
    return total == 0 ? 0 : (double)dark / total;
}

static string Sheet(params (int X, int Y, string Text)[] lines) =>
    string.Concat(lines.Select(line =>
        $"BT /F1 12 Tf {line.X} {line.Y} Td ({line.Text}) Tj ET\n"));

static void MakePdf(string filename, string[] pages, string mediaBox = "[0 0 612 792]", string pageOptions = "")
{
    var objectText = new List<string>
    {
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Count " + pages.Length + " /Kids [" +
            string.Join(' ', Enumerable.Range(0, pages.Length).Select(page => $"{4 + page * 2} 0 R")) + "] >>",
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
    };
    for (var i = 0; i < pages.Length; i++)
    {
        objectText.Add($"<< /Type /Page /Parent 2 0 R /MediaBox {mediaBox} {pageOptions} " +
            $"/Resources << /Font << /F1 3 0 R >> >> /Contents {5 + i * 2} 0 R >>");
        objectText.Add($"<< /Length {pages[i].Length} >>\nstream\n{pages[i]}endstream");
    }
    objectText.Add("<< /Title (Synthetic Transit Evidence) >>");
    var data = new StringBuilder("%PDF-1.4\n");
    var offsets = new List<int>();
    for (var i = 0; i < objectText.Count; i++)
    {
        offsets.Add(data.Length);
        data.Append($"{i + 1} 0 obj\n{objectText[i]}\nendobj\n");
    }
    var xref = data.Length;
    data.Append($"xref\n0 {objectText.Count + 1}\n0000000000 65535 f \n");
    foreach (var offset in offsets)
        data.Append(offset.ToString("D10", CultureInfo.InvariantCulture)).Append(" 00000 n \n");
    data.Append($"trailer\n<< /Size {objectText.Count + 1} /Root 1 0 R /Info {objectText.Count} 0 R >>\n");
    data.Append($"startxref\n{xref}\n%%EOF\n");
    File.WriteAllText(filename, data.ToString(), Encoding.ASCII);
}
