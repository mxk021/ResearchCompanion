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
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Microsoft.Win32;

namespace ResearchCompanion.Windows;

internal sealed partial class ResearchWindow
{
    private const int MaxSourceImageBytes = 48 * 1024 * 1024;
    private const int MaxSourcePixels = 80_000_000;
    private const int MaxWireImageBytes = 8 * 1024 * 1024;
    private static readonly HashSet<string> SupportedImageExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        ".png", ".jpg", ".jpeg", ".tif", ".tiff", ".heic", ".heif", ".webp", ".gif", ".bmp"
    };
    private readonly List<DraftImage> draftImages = [];
    private readonly WrapPanel draftImagePanel = new() { Visibility = Visibility.Collapsed };

    private sealed record StoredImage(string Name, string MediaType, byte[] Bytes)
    {
        internal object Wire() => new { name = Name, mediaType = MediaType, data = Convert.ToBase64String(Bytes) };
    }
    private sealed record DraftImage(StoredImage Image, BitmapSource Thumbnail, int Width, int Height);
    private sealed record ImageInput(string Name, string? Path = null, byte[]? Bytes = null, BitmapSource? Bitmap = null);

    private sealed record ImageBudget(int Count, int Single, int Total, int Dimension, int Pixels, bool Png, bool Jpeg)
    {
        internal static ImageBudget Decode(JsonElement limits)
        {
            var formats = Array(limits, "mediaTypes").Select(v => v.ValueKind == JsonValueKind.String ? v.GetString() : null).ToArray();
            return new(
                Math.Clamp(Field(limits, "maxImagesPerMessage").TryReadInt() ?? 0, 0, 16),
                Math.Clamp(Field(limits, "maxImageBytes").TryReadInt() ?? 0, 0, MaxWireImageBytes),
                Math.Clamp(Field(limits, "maxMessageImageBytes").TryReadInt() ?? 0, 0, MaxWireImageBytes),
                Math.Clamp(Field(limits, "maxImageDimension").TryReadInt() ?? 4096, 0, 4096),
                Math.Clamp(Field(limits, "maxImagePixels").TryReadInt() ?? 16_777_216, 0, 16_777_216),
                formats.Contains("image/png"), formats.Contains("image/jpeg"));
        }

        internal void Check(IReadOnlyList<StoredImage> users, IReadOnlyList<SourceCrop> crops)
        {
            if (users.Count + crops.Count > Count ||
                users.Any(x => x.Bytes.Length > Single || (x.MediaType == "image/png" ? !Png : !Jpeg)) ||
                crops.Any(x => x.Bytes.Length > Single || !Png) ||
                users.Sum(x => (long)x.Bytes.Length) + crops.Sum(x => (long)x.Bytes.Length) > Total)
                throw new InvalidDataException("附图与原页裁图合计超出 DSH 限制，请减少图片或缩小文件范围。");
        }
    }

    private static bool ImageFile(string path) => SupportedImageExtensions.Contains(Path.GetExtension(path));

    private void ConfigureImageInput(Panel entry, Panel controls)
    {
        controls.Children.Add(Tool("附加图片…", PickDraftImagesAsync));
        entry.Children.Add(draftImagePanel);
        composer.AllowDrop = true;
        composer.PreviewDragOver += (_, e) =>
        {
            if (!e.Data.GetDataPresent(DataFormats.FileDrop, false)) return;
            e.Effects = !busy && e.Data.GetData(DataFormats.FileDrop, false) is string[] { Length: > 0 } files &&
                files.All(ImageFile) ? DragDropEffects.Copy : DragDropEffects.None;
            e.Handled = true;
        };
        composer.PreviewDrop += async (_, e) =>
        {
            if (e.Data.GetData(DataFormats.FileDrop, false) is not string[] { Length: > 0 } files ||
                !files.All(ImageFile)) return;
            e.Handled = true;
            await RunUiAsync(() => AddDraftImagesAsync(files.Select(InputFromFile).ToArray()));
        };
        composer.PreviewKeyDown += async (_, e) =>
        {
            if (busy || e.Key != Key.V || Keyboard.Modifiers != ModifierKeys.Control) return;
            IDataObject? data;
            try { data = Clipboard.GetDataObject(); }
            catch (System.Runtime.InteropServices.ExternalException) { return; }
            if (data == null || !HasImagePaste(data)) return;
            e.Handled = true;
            await RunUiAsync(() => PasteDraftImageAsync(data));
        };
        DataObject.AddPastingHandler(composer, async (_, e) =>
        {
            if (busy || !HasImagePaste(e.SourceDataObject)) return;
            e.CancelCommand();
            await RunUiAsync(() => PasteDraftImageAsync(e.SourceDataObject));
        });
    }

    private static bool HasImagePaste(IDataObject data) => data.GetDataPresent(DataFormats.FileDrop, false)
        ? data.GetData(DataFormats.FileDrop, false) is string[] { Length: > 0 } files && files.All(ImageFile)
        : data.GetDataPresent("PNG", false) || data.GetDataPresent(DataFormats.Bitmap, true);

    private async Task PasteDraftImageAsync(IDataObject data)
    {
        if (data.GetData(DataFormats.FileDrop, false) is string[] { Length: > 0 } files && files.All(ImageFile))
        {
            await AddDraftImagesAsync(files.Select(InputFromFile).ToArray());
            return;
        }
        if (data.GetDataPresent("PNG", false))
        {
            var bytes = data.GetData("PNG", false) switch
            {
                Stream png => ReadImageBytes(png),
                byte[] blob when blob.Length is > 0 and <= MaxSourceImageBytes => blob,
                _ => throw new InvalidDataException("无法读取剪贴板中的 PNG。")
            };
            await AddDraftImagesAsync([new("粘贴图片", Bytes: bytes)]);
            return;
        }
        if (data.GetData(DataFormats.Bitmap, true) is not BitmapSource bitmap ||
            !ValidDimensions(bitmap.PixelWidth, bitmap.PixelHeight, MaxSourcePixels) || !bitmap.CanFreeze)
            throw new InvalidDataException("无法读取剪贴板中的图片，或图片像素过多。");
        if (!bitmap.IsFrozen) bitmap = (BitmapSource)bitmap.GetAsFrozen();
        await AddDraftImagesAsync([new("粘贴图片", Bitmap: bitmap)]);
    }

    private static ImageInput InputFromFile(string path) => new(Path.GetFileNameWithoutExtension(path), Path: path);

    private async Task PickDraftImagesAsync()
    {
        if (busy) return;
        var dialog = new OpenFileDialog
        {
            Filter = "图片|*.png;*.jpg;*.jpeg;*.tif;*.tiff;*.heic;*.heif;*.webp;*.gif;*.bmp",
            CheckFileExists = true, Multiselect = true
        };
        if (dialog.ShowDialog(this) == true)
            await AddDraftImagesAsync(dialog.FileNames.Select(InputFromFile).ToArray());
    }

    private async Task AddDraftImagesAsync(IReadOnlyList<ImageInput> inputs)
    {
        if (busy) return;
        if (connection is not { } client) throw new InvalidOperationException("请先连接 DSH，再附加图片。");
        var limits = ImageBudget.Decode(client.AttachmentLimits);
        if (inputs.Count == 0 || inputs.Count > limits.Count - draftImages.Count || limits.Single <= 0)
            throw new InvalidDataException("超出本轮可附加的图片数量，或科研桥未提供图片支持。");
        SetBusy(true);
        try
        {
            var additions = await Task.Run(() =>
            {
                var prepared = new List<DraftImage>();
                foreach (var input in inputs)
                {
                    lifetime.Token.ThrowIfCancellationRequested();
                    prepared.Add(PrepareDraftImage(input, limits));
                }
                return prepared;
            }, lifetime.Token);
            limits.Check(draftImages.Concat(additions).Select(image => image.Image).ToArray(), []);
            draftImages.AddRange(additions);
            SaveDraftImages();
            status.Text = $"已附加 {draftImages.Count} 张图片";
        }
        finally
        {
            SetBusy(false);
            UpdateDraftImagePanel();
        }
    }

    private static byte[] ReadImageBytes(Stream stream)
    {
        if (stream.CanSeek && stream.Length is <= 0 or > MaxSourceImageBytes)
            throw new InvalidDataException("请选择不超过 48 MiB 的本机图片。");
        using var bytes = new MemoryStream();
        byte[] buffer = new byte[64 * 1024];
        int count;
        while ((count = stream.Read(buffer, 0, buffer.Length)) > 0)
        {
            if (bytes.Length + count > MaxSourceImageBytes) throw new InvalidDataException("图片原始数据过大。");
            bytes.Write(buffer, 0, count);
        }
        if (bytes.Length == 0) throw new InvalidDataException("图片数据为空。");
        return bytes.ToArray();
    }

    private static BitmapFrame DecodeImage(Stream bytes)
    {
        var decoder = BitmapDecoder.Create(bytes, BitmapCreateOptions.DelayCreation | BitmapCreateOptions.PreservePixelFormat,
            BitmapCacheOption.None);
        if (decoder.Frames.Count != 1 || !ValidDimensions(decoder.Frames[0].PixelWidth, decoder.Frames[0].PixelHeight, MaxSourcePixels))
            throw new InvalidDataException("请选择单帧图片，或减小原始像素数。");
        return decoder.Frames[0];
    }

    private static DraftImage PrepareDraftImage(ImageInput input, ImageBudget limits)
    {
        if (limits.Dimension <= 0 || limits.Pixels <= 0)
            throw new InvalidDataException("科研桥未提供有效的图片像素限制。");
        byte[]? bytes = input.Bytes;
        if (input.Path is not null)
        {
            using var file = new FileStream(input.Path, FileMode.Open, FileAccess.Read, FileShare.Read);
            bytes = ReadImageBytes(file);
        }
        using var raw = bytes != null ? new MemoryStream(bytes, writable: false) : null;
        var decoded = input.Bitmap ?? DecodeImage(raw!);
        var oriented = OrientImage(decoded);
        double scale = Math.Min(1, Math.Min((double)limits.Dimension / Math.Max(oriented.PixelWidth, oriented.PixelHeight),
            Math.Sqrt((double)limits.Pixels / ((long)oriented.PixelWidth * oriented.PixelHeight))));
        var image = ScaleImage(oriented, scale);
        bool originalJpeg = bytes is [255, 216, ..];
        foreach (bool png in new[] { !originalJpeg, originalJpeg })
        {
            if (png ? !limits.Png : !limits.Jpeg) continue;
            BitmapEncoder encoder = png ? new PngBitmapEncoder() : new JpegBitmapEncoder { QualityLevel = 93 };
            // Build a new WIC bitmap. The selected file's EXIF/GPS and container metadata do not travel.
            var pixels = new FormatConvertedBitmap(image, PixelFormats.Bgra32, null, 0);
            int stride = checked(pixels.PixelWidth * pixels.Format.BitsPerPixel / 8);
            var cleanPixels = new byte[checked(stride * pixels.PixelHeight)];
            pixels.CopyPixels(cleanPixels, stride, 0);
            if (!png)
                for (int i = 0; i < cleanPixels.Length; i += 4)
                {
                    int alpha = cleanPixels[i + 3];
                    if (alpha == 255) continue;
                    for (int channel = 0; channel < 3; channel++)
                        cleanPixels[i + channel] = (byte)((cleanPixels[i + channel] * alpha + 255 * (255 - alpha) + 127) / 255);
                    cleanPixels[i + 3] = 255;
                }
            var clean = BitmapSource.Create(pixels.PixelWidth, pixels.PixelHeight, 96, 96, pixels.Format, null, cleanPixels, stride);
            encoder.Frames.Add(BitmapFrame.Create(clean));
            using var output = new MemoryStream();
            encoder.Save(output);
            if (output.Length > limits.Single) continue;
            var label = PlainLabel(input.Name, 100) + (png ? ".png" : ".jpg");
            return new(new(label, png ? "image/png" : "image/jpeg", output.ToArray()),
                Thumbnail(clean), clean.PixelWidth, clean.PixelHeight);
        }
        throw new InvalidDataException("图片无法转换为科研桥接受的格式或超过单张大小上限。");
    }

    private static bool ValidDimensions(int width, int height, int limit) =>
        width > 0 && height > 0 && (long)width * height <= limit;

    private static BitmapSource OrientImage(BitmapSource input)
    {
        if (input is not BitmapFrame frame) return input;
        ushort orientation = 1;
        try
        {
            if (frame.Metadata is BitmapMetadata metadata)
                orientation = metadata.GetQuery("/app1/ifd/{ushort=274}") as ushort? ??
                    metadata.GetQuery("/ifd/{ushort=274}") as ushort? ?? 1;
        }
        catch (Exception error) when (error is NotSupportedException or ArgumentException) { }
        if (orientation is < 2 or > 8) return input;
        var transforms = new TransformGroup();
        if (orientation is 2 or 4 or 5 or 7)
            transforms.Children.Add(new ScaleTransform(orientation == 4 ? 1 : -1, orientation == 4 ? -1 : 1));
        if (orientation is 3 or >= 5)
            transforms.Children.Add(new RotateTransform(orientation switch { 3 => 180, 5 or 8 => 270, _ => 90 }));
        return new TransformedBitmap(input, transforms);
    }

    private static BitmapSource ScaleImage(BitmapSource input, double scale) =>
        scale >= 1 ? input : new TransformedBitmap(input, new ScaleTransform(scale, scale));

    private static BitmapSource Thumbnail(BitmapSource input)
    {
        var thumbnail = ScaleImage(input, Math.Min(1, 180d / Math.Max(input.PixelWidth, input.PixelHeight)));
        thumbnail.Freeze();
        return thumbnail;
    }

    private void UpdateDraftImagePanel()
    {
        draftImagePanel.Children.Clear();
        draftImagePanel.Visibility = draftImages.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        foreach (var item in draftImages)
        {
            var image = new Image { Source = item.Thumbnail, Width = 57, Height = 48, Stretch = Stretch.Uniform };
            var preview = new Button { Content = image, Margin = new Thickness(0, 2, 2, 3), ToolTip = item.Image.Name };
            AutoLabel(preview, "预览 " + item.Image.Name);
            preview.Click += (_, _) =>
            {
                using var data = new MemoryStream(item.Image.Bytes, writable: false);
                var source = BitmapFrame.Create(data, BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnLoad);
                Dialog(item.Image.Name, new Image { Source = source, Stretch = Stretch.Uniform, Margin = new Thickness(12) }, 680, 570).Show();
            };
            var remove = new Button { Content = "×", Margin = new Thickness(0, 2, 7, 3), IsEnabled = !busy };
            AutoLabel(remove, "移除 " + item.Image.Name);
            remove.Click += (_, _) =>
            {
                if (busy) return;
                draftImages.Remove(item);
                SaveDraftImages();
                UpdateDraftImagePanel();
            };
            draftImagePanel.Children.Add(preview);
            draftImagePanel.Children.Add(remove);
        }
        RefreshSendButton();
    }

    private string? DraftImagePath(string? id)
    {
        if (connection?.RecoveryHost is not { } host || workspace == null) return null;
        var key = Convert.ToHexStringLower(SHA256.HashData(JsonSerializer.SerializeToUtf8Bytes(new[] { host, workspace, id })));
        return Path.Combine(App.Profile, "DraftImages", key + ".json");
    }

    private void SaveDraftImages() => WriteDraftImages(DraftImagePath(session));

    private void WriteDraftImages(string? path)
    {
        if (path == null) return;
        try
        {
            if (draftImages.Count == 0) { File.Delete(path); return; }
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            WriteReceiptFile(path, JsonSerializer.SerializeToUtf8Bytes(draftImages.Select(x => x.Image)));
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            System.Diagnostics.Trace.TraceWarning("Could not save draft image attachments.");
        }
    }

    private async Task RestoreDraftImagesAsync(CancellationToken ct)
    {
        draftImages.Clear();
        if (DraftImagePath(session) is string path && File.Exists(path))
        {
            try
            {
                var restored = await Task.Run(() =>
                {
                    using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
                    if (file.Length > MaxWireImageBytes * 2L) throw new InvalidDataException("图片草稿过大。");
                    var data = JsonSerializer.Deserialize<StoredImage[]>(file) ?? [];
                    if (data.Length > 16 || data.Any(x => x?.Name is not { Length: > 0 and <= 110 } ||
                        x.Bytes is not { Length: > 0 } || x.MediaType is not ("image/png" or "image/jpeg")) ||
                        data.Sum(x => (long)x.Bytes.Length) > MaxWireImageBytes)
                        throw new InvalidDataException("图片草稿格式无效。");
                    return data.Select(x =>
                    {
                        ct.ThrowIfCancellationRequested();
                        using var stream = new MemoryStream(x.Bytes, writable: false);
                        var source = DecodeImage(stream);
                        if (!ValidDimensions(source.PixelWidth, source.PixelHeight, 16_777_216))
                            throw new InvalidDataException("图片草稿像素过多。");
                        return new DraftImage(x, Thumbnail(source), source.PixelWidth, source.PixelHeight);
                    }).ToArray();
                }, ct);
                draftImages.AddRange(restored);
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException or NotSupportedException)
            { status.Text = "部分图片草稿无法恢复，请重新附加。"; }
        }
        UpdateDraftImagePanel();
    }
}
