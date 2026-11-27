using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Windows.Graphics.Imaging;
using Windows.Media.Ocr;
using Windows.Storage.Streams;

namespace ResearchCompanion.Windows;

internal static class WindowsPdfOcr
{
    internal static async Task<IReadOnlyList<PdfOcrLine>> RecognizeAsync(PagePreview page, CancellationToken ct)
    {
        var engine = OcrEngine.TryCreateFromUserProfileLanguages()
            ?? OcrEngine.AvailableRecognizerLanguages.Select(OcrEngine.TryCreateFromLanguage).FirstOrDefault(item => item != null)
            ?? throw new InvalidDataException("Windows 没有已安装的 OCR 语言。请先添加所需的文本识别语言。");
        if (page.Width > OcrEngine.MaxImageDimension || page.Height > OcrEngine.MaxImageDimension)
            throw new InvalidDataException("原页像素超过 Windows OCR 上限。");

        using var bitmap = new SoftwareBitmap(BitmapPixelFormat.Bgra8, page.Width, page.Height, BitmapAlphaMode.Ignore);
        using var writer = new DataWriter();
        writer.WriteBytes(page.Pixels);
        bitmap.CopyFromBuffer(writer.DetachBuffer());
        var result = await engine.RecognizeAsync(bitmap).AsTask(ct).ConfigureAwait(false);
        return result.Lines.Where(line => line.Words.Count > 0).Select(line =>
        {
            double left = Math.Max(0, line.Words.Min(word => word.BoundingRect.Left)) / page.Width;
            double top = Math.Max(0, line.Words.Min(word => word.BoundingRect.Top)) / page.Height;
            double right = Math.Min(page.Width, line.Words.Max(word => word.BoundingRect.Right)) / page.Width;
            double bottom = Math.Min(page.Height, line.Words.Max(word => word.BoundingRect.Bottom)) / page.Height;
            return new PdfOcrLine(line.Text, new PdfRegion(left, top, right - left, bottom - top));
        }).ToArray();
    }
}
