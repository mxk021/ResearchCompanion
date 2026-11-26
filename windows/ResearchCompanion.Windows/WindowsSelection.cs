using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Automation;
using System.Windows.Threading;
using Clipboard = System.Windows.Clipboard;
using TextDataFormat = System.Windows.TextDataFormat;

namespace ResearchCompanion.Windows;

public sealed record WindowsSelectionResult(
    string Text, string Application, string? Title, string? Url,
    bool ProvenanceVerified, bool ClipboardWasReplaced, string? ZoteroPairingId = null);

internal sealed class WindowsSelectionCaptureException(string message, bool canTryNativeCopy = false)
    : InvalidOperationException(message)
{
    internal bool CanTryNativeCopy { get; } = canTryNativeCopy;
}

/// <summary>Tracks window identity only. Selection and clipboard reads require an explicit capture.</summary>
public sealed class WindowsSelection : IDisposable
{
    private const int LocalLimit = 1_048_576;
    private static readonly TimeSpan DirectTimeout = TimeSpan.FromMilliseconds(650);
    private static readonly TimeSpan CopyTimeout = TimeSpan.FromMilliseconds(1200);
    private static readonly TimeSpan ClipboardSettle = TimeSpan.FromMilliseconds(120);
    private static readonly HttpClient ZoteroClient = new(new HttpClientHandler
    {
        AllowAutoRedirect = false,
        UseCookies = false,
        UseProxy = false,
        UseDefaultCredentials = false
    }) { Timeout = Timeout.InfiniteTimeSpan };

    private readonly Dispatcher _dispatcher = Dispatcher.CurrentDispatcher;
    private readonly int _ownerPid = Environment.ProcessId;
    private readonly Native.WinEventProc _observeForeground;
    private readonly nint _foregroundHook;
    private nint _previousExternal;
    private Attempt? _attempt;
    private Task<DirectRead>? _directRead;
    private long _copyIssuedAt;
    private bool _disposed;

    internal string? ZoteroPairingFile { get; set; }

    public WindowsSelection()
    {
        _observeForeground = ForegroundChanged;
        _foregroundHook = Native.SetWinEventHook(3, 3, 0, _observeForeground, 0, 0, 0);
        Observe();
    }

    public void Observe()
    {
        _dispatcher.VerifyAccess();
        RememberForeground(Native.GetForegroundWindow());
    }

    public async Task<WindowsSelectionResult> CaptureAsync(bool allowCopy, CancellationToken cancellationToken = default)
    {
        _dispatcher.VerifyAccess();
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (_attempt is not null)
            throw Failure("上次取词尚未结束，请稍后重试。");

        var foreground = Native.GetForegroundWindow();
        RememberForeground(foreground);
        var source = CaptureWindow(_previousExternal);
        if (source is null || (ProcessId(foreground) != _ownerPid && foreground != source.Window))
            throw Failure("未找到可核对的来源窗口。请先在原应用选取文字。");

        var attempt = new Attempt(source, ProcessId(foreground) == _ownerPid ? foreground : 0);
        _attempt = attempt;
        try
        {
            EnsureCurrent(attempt, cancellationToken);
            if (source.Application == "Zotero")
            {
                // Zotero's accessibility mirror can be offset from its PDF canvas selection.
                // The paired reader extension ties a request to the active attachment and tab.
                var zotero = await ReadZoteroAsync(attempt, cancellationToken);
                if (zotero is not null)
                    return zotero;
            }
            else
            {
                var direct = await ReadUiaAsync(attempt, cancellationToken);
                if (direct.Text is not null)
                    return new WindowsSelectionResult(direct.Text, source.Application, source.Title, null, true, false);
                if (direct.Error is not null)
                    throw Failure(direct.Error);
            }

            if (!allowCopy || !source.CopyAllowed)
                throw new WindowsSelectionCaptureException(
                    "当前控件未提供可读选区。可以在原应用复制后粘贴选区。",
                    canTryNativeCopy: !allowCopy && source.CopyAllowed);
            return await CopyAsync(attempt, cancellationToken);
        }
        finally
        {
            // Restore only after our own temporary handoff and while the exact source
            // is still in front. Never override another application selected by the user.
            if (attempt.ActivatedSource && !attempt.Interrupted && attempt.RestoreWindow != 0 &&
                ProcessId(attempt.RestoreWindow) == _ownerPid && SameSource(attempt.Source) &&
                Native.GetForegroundWindow() == attempt.Source.Window)
                Native.SetForegroundWindow(attempt.RestoreWindow);
            _attempt = null;
        }
    }

    public static WindowsSelectionResult FromManual(string text)
    {
        ValidateText(text);
        return new WindowsSelectionResult(text, "手动粘贴", null, null, false, false);
    }

    public void Dispose()
    {
        _dispatcher.VerifyAccess();
        if (_disposed) return;
        _disposed = true;
        if (_attempt is not null) _attempt.Interrupted = true;
        if (_foregroundHook != 0) Native.UnhookWinEvent(_foregroundHook);
    }

    private void ForegroundChanged(nint hook, uint eventId, nint hwnd, int objectId, int childId, uint thread, uint timestamp)
    {
        var pid = ProcessId(hwnd);
        if (_attempt is { } running && hwnd != running.Source.Window && pid != _ownerPid && hwnd != 0)
            running.Interrupted = true;
        if (hwnd == Native.GetForegroundWindow())
            RememberForeground(hwnd);
    }

    private void RememberForeground(nint window)
    {
        var pid = ProcessId(window);
        if (pid == 0 || pid == _ownerPid || !Native.IsWindowVisible(window)) return;
        var windowClass = new StringBuilder(96);
        Native.GetClassName(window, windowClass, windowClass.Capacity);
        if (windowClass.ToString() is "Shell_TrayWnd" or "Shell_SecondaryTrayWnd" or "NotifyIconOverflowWindow" or "#32768")
            return;
        _previousExternal = window;
    }

    private static SourceWindow? CaptureWindow(nint hwnd)
    {
        var thread = Native.GetWindowThreadProcessId(hwnd, out var pid);
        if (thread == 0 || pid == 0 || !Native.IsWindowVisible(hwnd) || Native.IsIconic(hwnd))
            return null;
        var title = WindowTitle(hwnd);
        if (string.IsNullOrWhiteSpace(title)) return null;
        try
        {
            using var process = Process.GetProcessById((int)pid);
            var app = process.ProcessName.ToLowerInvariant() switch
            {
                "msedge" => "Edge",
                "chrome" => "Chrome",
                "zotero" => "Zotero",
                "wps" or "wpspdf" or "wpsoffice" or "et" or "wpp" => "WPS",
                _ => process.ProcessName
            };
            return new SourceWindow(hwnd, thread, (int)pid, title, app, app is "Edge" or "Chrome" or "Zotero" or "WPS");
        }
        catch (ArgumentException) { return null; }
        catch (InvalidOperationException) { return null; }
        catch (System.ComponentModel.Win32Exception) { return null; }
    }

    private static string WindowTitle(nint hwnd)
    {
        // Refuse truncated window identities rather than equating two long titles.
        var text = new StringBuilder(2049);
        var read = Native.GetWindowText(hwnd, text, text.Capacity);
        return read == text.Capacity - 1 ? "" : text.ToString();
    }

    private static int ProcessId(nint hwnd)
    {
        Native.GetWindowThreadProcessId(hwnd, out var pid);
        return (int)pid;
    }

    private static bool SameSource(SourceWindow source)
    {
        var thread = Native.GetWindowThreadProcessId(source.Window, out var pid);
        return thread == source.Thread && (int)pid == source.Pid && Native.IsWindowVisible(source.Window) &&
            !Native.IsIconic(source.Window) && WindowTitle(source.Window) == source.Title;
    }

    private void EnsureCurrent(Attempt attempt, CancellationToken cancellationToken, bool requireSourceFocus = false)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var foreground = Native.GetForegroundWindow();
        if (attempt.Interrupted || !SameSource(attempt.Source) ||
            (foreground != attempt.Source.Window && (requireSourceFocus || ProcessId(foreground) != _ownerPid)))
            throw Failure("来源窗口或选区已改变。请回到原应用重新选取。");
    }

    private async Task ActivateSourceAsync(Attempt attempt, CancellationToken cancellationToken)
    {
        EnsureCurrent(attempt, cancellationToken);
        if (Native.GetForegroundWindow() == attempt.Source.Window) return;
        if (!Native.SetForegroundWindow(attempt.Source.Window))
            throw Failure("Windows 未切换到原窗口。请在原窗口手动复制，再粘贴选区。");
        attempt.ActivatedSource = true;
        var start = Stopwatch.GetTimestamp();
        do
        {
            EnsureCurrent(attempt, cancellationToken);
            if (Native.GetForegroundWindow() == attempt.Source.Window) return;
            await Task.Delay(15, cancellationToken);
        } while (Stopwatch.GetElapsedTime(start) < TimeSpan.FromMilliseconds(220));
        throw Failure("原窗口没有获得焦点。请在原窗口手动复制，再粘贴选区。");
    }

    private async Task<DirectRead> ReadUiaAsync(Attempt attempt, CancellationToken cancellationToken)
    {
        // UI Automation providers can stall without honoring cancellation. Keep
        // one worker in flight, and make the user-facing wait bounded.
        if (_directRead is { IsCompleted: false }) return default;
        var source = attempt.Source;
        _directRead = Task.Run(() => ReadUia(source), CancellationToken.None);
        DirectRead result;
        try { result = await _directRead.WaitAsync(DirectTimeout, cancellationToken); }
        catch (TimeoutException) { result = default; }
        EnsureCurrent(attempt, cancellationToken);
        return result;
    }

    private static DirectRead ReadUia(SourceWindow source)
    {
        try
        {
            if (!SameSource(source)) return default;
            var focused = Native.GetForegroundWindow() == source.Window ? AutomationElement.FocusedElement : null;
            if (focused is not null && focused.Current.ProcessId == source.Pid)
            {
                // Inspect the actual focus before trying its containing document.
                for (var element = focused; element is not null && element.Current.ProcessId == source.Pid;
                    element = TreeWalker.ControlViewWalker.GetParent(element))
                {
                    var result = TextPatternSelection(element);
                    if (result.IsKnown) return result;
                }
            }

            var info = new Native.GuiThreadInfo { Size = (uint)Marshal.SizeOf<Native.GuiThreadInfo>() };
            if (Native.GetGUIThreadInfo(source.Thread, ref info) && info.Focus != 0 && ProcessId(info.Focus) == source.Pid)
            {
                var control = AutomationElement.FromHandle(info.Focus);
                if (info.Focus != source.Window)
                {
                    var result = TextPatternSelection(control);
                    if (result.IsKnown) return result;
                }
            }

            var root = AutomationElement.FromHandle(source.Window);
            var visibleDocuments = new List<AutomationElement>();
            var pending = new Queue<(AutomationElement Element, int Depth)>();
            pending.Enqueue((root, 0));
            var visited = 0;
            while (pending.TryDequeue(out var next) && ++visited < 160)
            {
                var element = next.Element;
                if (next.Depth > 0 && element.Current.IsOffscreen) continue;
                if (element.Current.ControlType == ControlType.Document)
                {
                    if (element.Current.ProcessId != source.Pid || visibleDocuments.Count != 0)
                        return default;
                    visibleDocuments.Add(element);
                    continue;
                }
                if (next.Depth >= 8) continue;
                for (var child = TreeWalker.ControlViewWalker.GetFirstChild(element); child is not null;
                    child = TreeWalker.ControlViewWalker.GetNextSibling(child))
                {
                    if (pending.Count >= 160) return default;
                    pending.Enqueue((child, next.Depth + 1));
                }
            }
            // Multiple visible documents (for example split views) are ambiguous.
            return pending.Count == 0 && visibleDocuments.Count == 1
                ? TextPatternSelection(visibleDocuments[0], emptyIsDefinitive: !source.CopyAllowed) : default;
        }
        catch (Exception error) when (error is ElementNotAvailableException or COMException or UnauthorizedAccessException
                                     or InvalidOperationException or ArgumentException)
        {
            return default;
        }
    }

    private static DirectRead TextPatternSelection(AutomationElement element, bool emptyIsDefinitive = true)
    {
        if (element.Current.IsPassword)
            return new DirectRead(null, "此控件含有受保护内容，无法读取选区。");
        if (!element.TryGetCurrentPattern(TextPattern.Pattern, out var candidate) || candidate is not TextPattern pattern ||
            pattern.SupportedTextSelection == SupportedTextSelection.None)
            return default;
        var ranges = pattern.GetSelection();
        var empty = emptyIsDefinitive ? new DirectRead(null, "当前没有选中文字。") : default;
        if (ranges is null || ranges.Length == 0) return empty;
        if (ranges.Length > 1) return new DirectRead(null, "当前选区不连续。请分段选取，或手动复制。");
        var text = ranges[0].GetText(LocalLimit + 1);
        if (string.IsNullOrWhiteSpace(text)) return empty;
        if (text.Length > LocalLimit) return new DirectRead(null, "选区超过本机读取上限，请分段选取。");
        if (!Readable(text)) return new DirectRead(null, "原应用返回的选区无法核对。请手动复制。");
        return new DirectRead(text, null);
    }

    private async Task<WindowsSelectionResult> CopyAsync(Attempt attempt, CancellationToken cancellationToken)
    {
        if (_foregroundHook == 0)
            throw Failure("系统无法观察窗口切换。请在原窗口手动复制，再粘贴选区。");
        if (_copyIssuedAt != 0 && Stopwatch.GetElapsedTime(_copyIssuedAt) < CopyTimeout)
            throw Failure("上次自动复制可能尚未结束。请稍后重试或手动复制。");
        using var input = new InputWatch(
            () => attempt.Interrupted = true,
            () => !attempt.Interrupted && !cancellationToken.IsCancellationRequested &&
                Native.GetForegroundWindow() == attempt.Source.Window);
        if (!input.Active)
            throw Failure("系统无法核对自动复制期间的输入。请手动复制。");
        await ActivateSourceAsync(attempt, cancellationToken);
        EnsureCurrent(attempt, cancellationToken, requireSourceFocus: true);
        if (new[] { 0x10, 0x11, 0x12, 0x5B, 0x5C }.Any(key => Native.GetAsyncKeyState(key) < 0))
            throw Failure("请松开修饰键后重试取词。");

        var initial = Native.GetClipboardSequenceNumber();
        if (initial == 0 || Native.GetClipboardSequenceNumber() != initial)
            throw Failure("无法取得稳定的剪贴板版本。请手动复制。");
        _copyIssuedAt = Stopwatch.GetTimestamp();
        input.Copy();
        uint changed = initial;
        var lastChange = _copyIssuedAt;
        do
        {
            EnsureCurrent(attempt, cancellationToken, requireSourceFocus: true);
            var sequence = Native.GetClipboardSequenceNumber();
            if (sequence != changed)
            {
                changed = sequence;
                lastChange = Stopwatch.GetTimestamp();
            }
            else if (sequence != 0 && sequence != initial && Stopwatch.GetElapsedTime(lastChange) >= ClipboardSettle)
            {
                var owner = Native.GetClipboardOwner();
                if (!ClipboardSourceMatches(owner, attempt.Source))
                    throw Failure("无法确认剪贴板由原窗口更新。请选择手动复制。");
                string? text;
                try
                {
                    text = Clipboard.ContainsText(TextDataFormat.UnicodeText)
                        ? Clipboard.GetText(TextDataFormat.UnicodeText) : null;
                }
                catch (ExternalException) { text = null; }
                EnsureCurrent(attempt, cancellationToken, requireSourceFocus: true);
                if (Native.GetClipboardSequenceNumber() == sequence && Native.GetClipboardOwner() == owner)
                {
                    if (text is null) throw Failure("剪贴板没有稳定的文字选区。请手动复制。");
                    ValidateText(text);
                    _copyIssuedAt = 0;
                    return new WindowsSelectionResult(text, attempt.Source.Application, attempt.Source.Title, null, false, true);
                }
            }
            await Task.Delay(20, cancellationToken);
        } while (Stopwatch.GetElapsedTime(_copyIssuedAt) < CopyTimeout);
        throw Failure("未确认本次复制的选区。请手动复制；自动复制可能已改变剪贴板。");
    }

    private static bool ClipboardSourceMatches(nint owner, SourceWindow source)
    {
        int writerPid = ProcessId(owner);
        if (writerPid == source.Pid) return true;
        if (writerPid == 0 || source.Application != "WPS") return false;

        // WPS hosts the document window in wps.exe and uses a sibling PDF process
        // to own the clipboard. Other applications must still match the original PID.
        try
        {
            using var windowProcess = Process.GetProcessById(source.Pid);
            using var writerProcess = Process.GetProcessById(writerPid);
            var windowPath = windowProcess.MainModule?.FileName;
            var writerPath = writerProcess.MainModule?.FileName;
            return windowProcess.SessionId == writerProcess.SessionId &&
                string.Equals(Path.GetFileName(windowPath), "wps.exe", StringComparison.OrdinalIgnoreCase) &&
                string.Equals(Path.GetFileName(writerPath), "wpspdf.exe", StringComparison.OrdinalIgnoreCase) &&
                string.Equals(Path.GetDirectoryName(windowPath), Path.GetDirectoryName(writerPath), StringComparison.OrdinalIgnoreCase);
        }
        catch (Exception error) when (error is InvalidOperationException or ArgumentException or System.ComponentModel.Win32Exception)
        {
            return false;
        }
    }

    private async Task<WindowsSelectionResult?> ReadZoteroAsync(Attempt attempt, CancellationToken cancellationToken)
    {
        var pairing = ZoteroPairing();
        if (pairing is null) return null;
        var owner = ZoteroListenerProcess(pairing.Endpoint.Port);
        if (owner == 0) return null;
        if (owner != attempt.Source.Pid)
            throw Failure("Zotero 配对与当前窗口不一致，请选择该配置的配对文件。");
        await ActivateSourceAsync(attempt, cancellationToken);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(2));
        var requestId = Guid.NewGuid();
        var proof = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds().ToString(CultureInfo.InvariantCulture) + "." + Guid.NewGuid().ToString("N");
        var signature = Convert.ToHexStringLower(HMACSHA256.HashData(Encoding.UTF8.GetBytes(pairing.Token), Encoding.UTF8.GetBytes(proof)));
        using var request = new HttpRequestMessage(HttpMethod.Get, new Uri(pairing.Endpoint, "?selection=live&requestId=" + requestId.ToString("D")));
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", proof + "." + signature);
        request.Headers.CacheControl = new CacheControlHeaderValue { NoCache = true, NoStore = true };
        try
        {
            using var response = await ZoteroClient.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token);
            EnsureCurrent(attempt, cancellationToken, requireSourceFocus: true);
            if (response.Content.Headers.ContentLength > 200_000) return null;
            using var stream = await response.Content.ReadAsStreamAsync(timeout.Token);
            var bytes = new byte[200_001];
            var count = 0;
            while (count < bytes.Length)
            {
                var received = await stream.ReadAsync(bytes.AsMemory(count), timeout.Token);
                if (received == 0) break;
                count += received;
            }
            EnsureCurrent(attempt, cancellationToken, requireSourceFocus: true);
            if (count == bytes.Length || ZoteroListenerProcess(pairing.Endpoint.Port) != owner) return null;
            using var document = JsonDocument.Parse(bytes.AsMemory(0, count));
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object) return null;
            if (response.StatusCode != HttpStatusCode.OK)
            {
                switch (GetString(root, "error"))
                {
                    case "NO_SELECTION": throw Failure("Zotero 当前没有选中文字。");
                    case "NO_ACTIVE_PAPER":
                    case "SOURCE_CHANGED":
                    case "PAPER_CHANGED": throw Failure("Zotero 来源窗口或附件已改变，请重新选取。");
                    case "PROTECTED_CONTENT": throw Failure("Zotero 选区包含受保护内容。");
                    case "SELECTION_TOO_LARGE": throw Failure("Zotero 选区超过读取上限，请分段选取。");
                    default: return null;
                }
            }
            if (!root.TryGetProperty("ok", out var ok) || ok.ValueKind != JsonValueKind.True ||
                !root.TryGetProperty("liveSelection", out var selection) || selection.ValueKind != JsonValueKind.Object ||
                !Guid.TryParse(GetString(selection, "requestId"), out var returned) || returned != requestId ||
                !selection.TryGetProperty("capture", out var capture) || capture.ValueKind != JsonValueKind.Object ||
                GetString(capture, "method") is not ("pdf-canvas" or "pdf-native" or "document-dom") ||
                GetString(capture, "tabID") is not { Length: > 0 and <= 256 } ||
                !capture.TryGetProperty("attachmentID", out var id) || id.ValueKind != JsonValueKind.Number ||
                !id.TryGetInt64(out var attachmentId) || attachmentId <= 0 ||
                GetString(capture, "attachmentKey") is not { } key || !Regex.IsMatch(key, "\\A[A-Z0-9]{8}\\z") ||
                GetString(selection, "text") is not { Length: > 0 and <= 24_000 } text || !Readable(text))
                return null;
            var title = GetString(selection, "title");
            if (title is null || title.Length > 512) title = attempt.Source.Title;
            return new WindowsSelectionResult(text, "Zotero", title,
                ZoteroLocation(selection, key, GetString(capture, "method")), true, false, pairing.Identity);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested) { return null; }
        catch (HttpRequestException) { return null; }
        catch (IOException) { return null; }
        catch (JsonException) { return null; }
    }

    // Zotero's profiles can listen on different loopback ports. Associate the
    // paired endpoint with the native window rather than trusting its title alone.
    private static int ZoteroListenerProcess(int port)
    {
        const uint InsufficientBuffer = 122;
        const uint IPv4 = 2;
        const uint OwnerPidListeners = 3;
        const uint IPv4Loopback = 0x0100007f;
        const int RowSize = 24;
        var size = 0;
        if (Native.GetExtendedTcpTable(null, ref size, false, IPv4, OwnerPidListeners, 0) != InsufficientBuffer ||
            size is < sizeof(int) or > 1_048_576)
            return 0;
        var buffer = new byte[size];
        if (Native.GetExtendedTcpTable(buffer, ref size, false, IPv4, OwnerPidListeners, 0) != 0)
            return 0;
        var count = BitConverter.ToInt32(buffer, 0);
        if (count < 0 || count > (buffer.Length - sizeof(int)) / RowSize) return 0;
        var owner = 0;
        for (var row = 0; row < count; row++)
        {
            var offset = sizeof(int) + row * RowSize;
            var address = BitConverter.ToUInt32(buffer, offset + 4);
            var localPort = (buffer[offset + 8] << 8) | buffer[offset + 9];
            if (localPort != port || address is not (0 or IPv4Loopback)) continue;
            var pid = BitConverter.ToInt32(buffer, offset + 20);
            if (owner != 0 && pid != owner) return 0;
            owner = pid;
        }
        return owner;
    }

    internal void OpenZoteroSource(string address, string? pairingId)
    {
        if (pairingId is null)
            throw Failure("这条来源未绑定 Zotero 配置，请重新选取原文。");
        var pairing = ZoteroPairing();
        if (pairing is null || pairing.Identity != pairingId || pairing.ProfilePath is not { } profile)
            throw Failure("请选用记录这条来源时的 Zotero 配对文件。");
        var owner = ZoteroListenerProcess(pairing.Endpoint.Port);
        if (owner == 0)
            throw Failure("请先打开与这条来源配对的 Zotero 配置。");

        try
        {
            using var process = Process.GetProcessById(owner);
            if (!string.Equals(process.ProcessName, "zotero", StringComparison.OrdinalIgnoreCase) ||
                process.MainModule?.FileName is not { } executable || process.HasExited ||
                ZoteroListenerProcess(pairing.Endpoint.Port) != owner)
                throw Failure("无法确认配对的 Zotero 阅读器。");
            // Gecko dispatches the URI to this profile's running instance. The
            // system scheme association could instead target a different copy.
            var start = new ProcessStartInfo(executable) { UseShellExecute = false };
            start.ArgumentList.Add("-profile");
            start.ArgumentList.Add(profile);
            start.ArgumentList.Add("-url");
            start.ArgumentList.Add(address);
            using var launcher = Process.Start(start);
            if (launcher is null) throw Failure("未能向已配对的 Zotero 发送来源链接。");
        }
        catch (Exception error) when (error is ArgumentException or System.ComponentModel.Win32Exception)
        {
            throw Failure("未能向已配对的 Zotero 发送来源链接。");
        }
    }

    private Pairing? ZoteroPairing()
    {
        try
        {
            if (ZoteroPairingFile is { Length: > 0 } chosen) return ReadZoteroPairing(chosen);
            var root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Zotero", "Zotero");
            var ini = ReadSafeFile(Path.Combine(root, "profiles.ini"), 64 * 1024);
            var profiles = new List<Dictionary<string, string>>();
            Dictionary<string, string>? current = null;
            foreach (var raw in Encoding.UTF8.GetString(ini).Split('\n'))
            {
                var line = raw.Trim();
                if (line.StartsWith('['))
                {
                    current = Regex.IsMatch(line, "\\A\\[Profile[0-9]+\\]\\z") ? new Dictionary<string, string>(StringComparer.Ordinal) : null;
                    if (current is not null) profiles.Add(current);
                    continue;
                }
                var equal = line.IndexOf('=');
                if (current is not null && equal > 0) current[line[..equal]] = line[(equal + 1)..];
            }
            var defaults = profiles.Where(profile => profile.GetValueOrDefault("Default") == "1").ToArray();
            var active = defaults.Length == 1 ? defaults[0] : defaults.Length == 0 && profiles.Count == 1 ? profiles[0] : null;
            if (active?.GetValueOrDefault("Path") is not { Length: > 0 } profilePath) return null;
            if (active.GetValueOrDefault("IsRelative") == "1")
            {
                profilePath = Path.GetFullPath(profilePath, root);
                if (!profilePath.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) return null;
            }
            else if (active.GetValueOrDefault("IsRelative") != "0" || !Path.IsPathFullyQualified(profilePath) ||
                     profilePath.StartsWith(@"\\", StringComparison.Ordinal)) return null;
            return ReadZoteroPairing(Path.Combine(profilePath, "dsh-companion-bridge", "pairing.json"));
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException or ArgumentException or NotSupportedException)
        {
            return null;
        }
    }

    internal static bool IsZoteroPairingFile(string path)
    {
        try { return ReadZoteroPairing(path) != null; }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException or ArgumentException or NotSupportedException)
        {
            return false;
        }
    }

    private static Pairing? ReadZoteroPairing(string path)
    {
        if (!Path.IsPathFullyQualified(path) || path.StartsWith(@"\\", StringComparison.Ordinal)) return null;
        using var json = JsonDocument.Parse(ReadSafeFile(path, 4096));
        var token = GetString(json.RootElement, "token");
        var endpoint = GetString(json.RootElement, "endpoint") ?? "http://127.0.0.1:23119/dsh-companion/context";
        if (token is null || !Regex.IsMatch(token, "\\A[a-f0-9]{64}\\z") ||
            !Uri.TryCreate(endpoint, UriKind.Absolute, out var location) || location.Scheme != "http" ||
            location.Host != "127.0.0.1" || location.AbsolutePath != "/dsh-companion/context" ||
            location.UserInfo.Length != 0 || location.Query.Length != 0 || location.Fragment.Length != 0)
            return null;
        var parent = Path.GetDirectoryName(path);
        var profile = string.Equals(Path.GetFileName(path), "pairing.json", StringComparison.OrdinalIgnoreCase) &&
            string.Equals(Path.GetFileName(parent), "dsh-companion-bridge", StringComparison.OrdinalIgnoreCase)
            ? Path.GetDirectoryName(parent) : null;
        return new Pairing(token, location, profile);
    }

    private static byte[] ReadSafeFile(string path, int limit)
    {
        // Profile junctions would make it impossible to establish which local
        // account supplied the pairing record. Proprietary profiles may fall back.
        for (string? item = Path.GetFullPath(path); item is not null; item = Path.GetDirectoryName(item))
        {
            if ((File.GetAttributes(item) & FileAttributes.ReparsePoint) != 0)
                throw new IOException("Profile storage is redirected.");
        }
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 4096, FileOptions.SequentialScan);
        if (stream.Length > limit) throw new IOException("Profile record is too large.");
        var bytes = new byte[checked((int)stream.Length)];
        stream.ReadExactly(bytes);
        if (stream.ReadByte() != -1) throw new IOException("Profile record changed.");
        return bytes;
    }

    private static string? ZoteroLocation(JsonElement selection, string key, string? method)
    {
        if (!selection.TryGetProperty("location", out var location) || location.ValueKind != JsonValueKind.Object ||
            GetString(location, "attachmentKey") != key || GetString(location, "library") is not { } library ||
            (library != "library" && !Regex.IsMatch(library, "\\Agroups/[1-9][0-9]{0,15}\\z"))) return null;
        if (method == "document-dom") return "zotero://select/" + library + "/items/" + key;
        var page = location.TryGetProperty("pageIndex", out var index) && index.ValueKind == JsonValueKind.Number &&
            index.TryGetInt32(out var physical) && physical is >= 0 and < 1_000_000 ? "?page=" + (physical + 1).ToString(CultureInfo.InvariantCulture) : "";
        return "zotero://open-pdf/" + library + "/items/" + key + page;
    }

    private static string? GetString(JsonElement item, string name) =>
        item.ValueKind == JsonValueKind.Object && item.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;

    private static InvalidOperationException Failure(string message) => new(message);

    private static void ValidateText(string text)
    {
        if (text.Length > LocalLimit) throw Failure("选区超过本机读取上限，请分段选取。");
        if (!Readable(text)) throw Failure("未取得可读的文字选区。");
    }

    private static bool Readable(string text)
    {
        var chars = 0;
        var dubious = 0;
        foreach (var rune in text.EnumerateRunes())
        {
            if (rune.Value == 0) return false;
            if (Rune.IsWhiteSpace(rune)) continue;
            chars++;
            if (rune.Value == 0xfffd || Rune.GetUnicodeCategory(rune) is UnicodeCategory.PrivateUse or UnicodeCategory.Control)
                dubious++;
        }
        return chars > 0 && dubious * 10 < chars;
    }

    private sealed record SourceWindow(nint Window, uint Thread, int Pid, string Title, string Application, bool CopyAllowed);
    private sealed record Pairing(string Token, Uri Endpoint, string? ProfilePath)
    {
        public string Identity => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(Token)));
    }
    private readonly record struct DirectRead(string? Text, string? Error)
    {
        public bool IsKnown => Text is not null || Error is not null;
    }

    private sealed class Attempt(SourceWindow source, nint restoreWindow)
    {
        public SourceWindow Source { get; } = source;
        public nint RestoreWindow { get; } = restoreWindow;
        public bool Interrupted;
        public bool ActivatedSource;
    }

    /// <summary>During explicit copy only, any intervening input revokes the capture.</summary>
    private sealed class InputWatch : IDisposable
    {
        private readonly Action _interrupt;
        private readonly Func<bool> _canInject;
        private readonly nuint _marker = (nuint)RandomNumberGenerator.GetInt32(1, int.MaxValue);
        private readonly Native.HookProc _keyboard;
        private readonly Native.HookProc _mouse;
        private readonly nint _keyboardHook;
        private readonly nint _mouseHook;
        public bool Active => _keyboardHook != 0 && _mouseHook != 0;

        public InputWatch(Action interrupt, Func<bool> canInject)
        {
            _interrupt = interrupt;
            _canInject = canInject;
            _keyboard = Keyboard;
            _mouse = Mouse;
            var module = Native.GetModuleHandle(null);
            _keyboardHook = Native.SetWindowsHookEx(13, _keyboard, module, 0);
            _mouseHook = Native.SetWindowsHookEx(14, _mouse, module, 0);
        }

        private nint Keyboard(int code, nint message, nint data)
        {
            if (code >= 0 && ((long)message is 0x100 or 0x104))
            {
                if (Marshal.PtrToStructure<Native.LowLevelKeyboard>(data).ExtraInfo != _marker)
                    _interrupt();
                else if (!_canInject())
                {
                    // Prevent our chord from reaching a different foreground
                    // window. Always allow key-up to release an accepted down.
                    _interrupt();
                    return 1;
                }
            }
            return Native.CallNextHookEx(0, code, message, data);
        }

        private nint Mouse(int code, nint message, nint data)
        {
            if (code >= 0 && (long)message is 0x201 or 0x204 or 0x207 or 0x20A or 0x20B or 0x20E)
                _interrupt();
            return Native.CallNextHookEx(0, code, message, data);
        }

        public void Copy()
        {
            Native.Input Key(ushort key, bool up) => new()
            {
                Type = 1,
                Data = new Native.InputData { Keyboard = new Native.KeyInput { Key = key, Flags = up ? 2u : 0u, ExtraInfo = _marker } }
            };
            var events = new[] { Key(0x11, false), Key(0x43, false), Key(0x43, true), Key(0x11, true) };
            var size = Marshal.SizeOf<Native.Input>();
            var sent = Native.SendInput((uint)events.Length, events, size);
            if (sent == events.Length) return;
            if (sent != 0)
            {
                // Release only our keys if the OS accepted part of the chord.
                var releases = sent == 2 ? new[] { events[2], events[3] } : new[] { events[3] };
                Native.SendInput((uint)releases.Length, releases, size);
            }
            throw Failure("Windows 未接受自动复制按键。请手动复制。");
        }

        public void Dispose()
        {
            if (_keyboardHook != 0) Native.UnhookWindowsHookEx(_keyboardHook);
            if (_mouseHook != 0) Native.UnhookWindowsHookEx(_mouseHook);
        }
    }

    private static class Native
    {
        internal delegate void WinEventProc(nint hook, uint eventId, nint hwnd, int objectId, int childId, uint thread, uint timestamp);
        internal delegate nint HookProc(int code, nint message, nint data);
        [StructLayout(LayoutKind.Sequential)] internal struct Rect { public int Left, Top, Right, Bottom; }
        [StructLayout(LayoutKind.Sequential)] internal struct GuiThreadInfo
        {
            public uint Size, Flags;
            public nint Active, Focus, Capture, MenuOwner, MoveSize, Caret;
            public Rect CaretRect;
        }
        [StructLayout(LayoutKind.Sequential)] internal struct LowLevelKeyboard
        {
            public uint Key, Scan, Flags, Time;
            public nuint ExtraInfo;
        }
        [StructLayout(LayoutKind.Sequential)] internal struct KeyInput
        {
            public ushort Key, Scan;
            public uint Flags, Time;
            public nuint ExtraInfo;
        }
        [StructLayout(LayoutKind.Sequential)] internal struct MouseInput
        {
            public int X, Y;
            public uint Data, Flags, Time;
            public nuint ExtraInfo;
        }
        [StructLayout(LayoutKind.Explicit)] internal struct InputData
        {
            [FieldOffset(0)] public KeyInput Keyboard;
            [FieldOffset(0)] public MouseInput Mouse;
        }
        [StructLayout(LayoutKind.Sequential)] internal struct Input
        {
            public uint Type;
            public InputData Data;
        }
        [DllImport("iphlpapi.dll")] internal static extern uint GetExtendedTcpTable(
            [Out] byte[]? table, ref int size, [MarshalAs(UnmanagedType.Bool)] bool sort, uint family, uint tableClass, uint reserved);
        [DllImport("user32.dll")] internal static extern nint GetForegroundWindow();
        [DllImport("user32.dll")] internal static extern uint GetWindowThreadProcessId(nint window, out uint process);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] internal static extern int GetWindowText(nint hwnd, StringBuilder value, int capacity);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] internal static extern int GetClassName(nint hwnd, StringBuilder value, int capacity);
        [DllImport("user32.dll")] internal static extern bool IsWindowVisible(nint hwnd);
        [DllImport("user32.dll")] internal static extern bool IsIconic(nint hwnd);
        [DllImport("user32.dll")] internal static extern bool GetGUIThreadInfo(uint thread, ref GuiThreadInfo info);
        [DllImport("user32.dll")] internal static extern bool SetForegroundWindow(nint hwnd);
        [DllImport("user32.dll")] internal static extern nint SetWinEventHook(uint min, uint max, nint module, WinEventProc callback, uint pid, uint thread, uint flags);
        [DllImport("user32.dll")] internal static extern bool UnhookWinEvent(nint handle);
        [DllImport("user32.dll")] internal static extern uint GetClipboardSequenceNumber();
        [DllImport("user32.dll")] internal static extern nint GetClipboardOwner();
        [DllImport("user32.dll")] internal static extern short GetAsyncKeyState(int key);
        [DllImport("user32.dll")] internal static extern uint SendInput(uint count, [In] Input[] inputs, int size);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] internal static extern nint SetWindowsHookEx(int id, HookProc callback, nint module, uint thread);
        [DllImport("user32.dll")] internal static extern bool UnhookWindowsHookEx(nint handle);
        [DllImport("user32.dll")] internal static extern nint CallNextHookEx(nint handle, int code, nint message, nint data);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] internal static extern nint GetModuleHandle(string? name);
    }
}
