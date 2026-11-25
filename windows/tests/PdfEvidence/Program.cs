using System.Globalization;
using System.Runtime.InteropServices;
using System.Text;
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
            (60, 663, "RC-WIN: Frozen source two.")),
        Sheet((60, 717, "End at Copper rotation."), (60, 690, "Repeated end anchor.")),
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
    await Reject(() => document.RetrieveAsync("解释公式（1）"), "暂未核验", "unsupported visual target");
    await Reject(() => document.RetrieveAsync("第 1 页和第 2 页"), "多个页段", "disjoint scope");
    await Reject(() => document.RetrieveAsync("读取第 1、3 页"), "多个页段", "compact disjoint scope");
    Verify((await document.RetrieveAsync("读取首页"))[0].Page == 1, "first page alias");
    Verify((await document.RetrieveAsync("查找 Frozen source"))[0].Text.Contains("Frozen source"), "lexical excerpts");

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

    var mixed = Fixture("mixed-layout.pdf");
    MakePdf(mixed, [columnContent + Sheet((60, 680,
        "This inserted object spans the gutter and separates two different layout bands on the same sheet."))]);
    var complicated = await PdfEvidence.OpenAsync(mixed);
    await Reject(() => complicated.RetrieveAsync("读取第 1 页"), "栏序", "spanning object blocks ordering");

    var rotated = Fixture("rotated.pdf");
    MakePdf(rotated, [Sheet((95, 150, "Offset and rotated marker."))], "[0 0 420 325]",
        "/CropBox [50 40 380 300] /Rotate 90");
    var geometry = await PdfEvidence.OpenAsync(rotated);
    var region = (await geometry.RetrieveAsync("读取第 1 页"))[0].Regions[0];
    var preview = await geometry.RenderPageAsync(1, width: 460);
    Verify(preview.Width == 460 && preview.Height > preview.Width && preview.Stride == preview.Width * 4 &&
        DarkFraction(preview, region) > 0.04, "rotated CropBox source rectangle agrees with preview pixels");

    var notes = Fixture("notes.md");
    await File.WriteAllTextAsync(notes, "# A test\n科研摘要：线索原文。\n准确核验。\n");
    var markdown = await PdfEvidence.OpenAsync(notes);
    var excerpt = (await markdown.RetrieveAsync("从「线索」到「核验。」"))[0];
    Verify(excerpt.Text == "线索原文。\n准确核验。" && excerpt.Regions.Count == 0,
        "Unicode text anchors with no PDF coordinates");
    await File.WriteAllTextAsync(notes, "# A test\n科研摘要：线索原文。\n改后核验。\n");
    await Reject(() => markdown.RetrieveAsync("概括"), "内容已更新", "same-length edits invalidate a receipt");
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
