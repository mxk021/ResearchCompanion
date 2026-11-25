using System;
using System.Buffers;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.IO.Pipes;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;

namespace ResearchCompanion.Windows;

public sealed class BridgeRequestException(string errorCode, string message) : IOException(message)
{
    public string ErrorCode { get; } = errorCode;
}

/// <summary>Owner-local connection to the installed DSH research bridge.</summary>
public sealed class BridgeClient : IAsyncDisposable
{
    private const int MaxManifestBytes = 16384;
    private const int MaxResponseBytes = 16 * 1024 * 1024;
    private const string PipePrefix = @"\\.\pipe\";
    private static readonly Regex InstanceIdPattern = new("^[a-f0-9]{24}$", RegexOptions.CultureInvariant);
    private static readonly Regex NoncePattern = new("^[a-f0-9]{64}$", RegexOptions.CultureInvariant);
    private static readonly JsonSerializerOptions JsonOptions = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };

    private sealed record Endpoint(string InstanceId, string Kind, int Pid, int SessionId, string PipeName, byte[] ProtectedCredential);

    private readonly Endpoint endpoint;
    private byte[]? credential;

    private BridgeClient(Endpoint endpoint, byte[] credential)
    {
        this.endpoint = endpoint;
        this.credential = credential;
    }

    public JsonElement Capabilities { get; private set; }

    public static async Task<BridgeClient> ConnectAsync(CancellationToken ct = default)
    {
        string directory = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Research Companion", "instances");
        if (!Directory.Exists(directory) || IsReparsePoint(directory)
            || IsReparsePoint(Path.GetDirectoryName(directory)!))
            throw new IOException("找不到 Windows 科研桥。请先安装随附的科研桥并启动 DSH。");

        using var identity = WindowsIdentity.GetCurrent();
        string sid = identity.User?.Value ?? throw new IOException("无法核实当前 Windows 账户。");
        using var current = Process.GetCurrentProcess();
        int session = current.SessionId;
        var endpoints = new List<Endpoint>();
        foreach (string path in Directory.EnumerateFiles(directory, "*.json").Take(128))
        {
            ct.ThrowIfCancellationRequested();
            try
            {
                var candidate = ReadEndpoint(path, sid, session);
                if (candidate is not null)
                    endpoints.Add(candidate);
            }
            catch (Exception error) when (IsUnavailable(error))
            {
                // Untrusted or obsolete discovery record; no work is sent to it.
            }
        }
        foreach (var group in endpoints.GroupBy(endpoint => endpoint.Kind == "desktop" ? 0 : 1).OrderBy(group => group.Key))
        {
            BridgeClient? ready = null;
            try
            {
                foreach (var candidate in group.Take(8))
                {
                    ct.ThrowIfCancellationRequested();
                    BridgeClient? client = null;
                    try
                    {
                        client = new BridgeClient(candidate, Unprotect(candidate.ProtectedCredential));
                        client.Capabilities = await client.InvokeAsync("capabilities", null, 2000, ct).ConfigureAwait(false);
                        client.ValidateCapabilities();
                        // Socket discovery can precede workspace registration.
                        await client.InvokeAsync("workspaces", null, 5000, ct).ConfigureAwait(false);
                    }
                    catch (Exception error) when (IsUnavailable(error))
                    {
                        if (client is not null)
                            await client.DisposeAsync().ConfigureAwait(false);
                        continue;
                    }
                    catch
                    {
                        if (client is not null)
                            await client.DisposeAsync().ConfigureAwait(false);
                        throw;
                    }
                    if (ready is not null)
                    {
                        await client.DisposeAsync().ConfigureAwait(false);
                        throw new IOException("同一 Windows 会话有多个可用科研桥。请只保留需要使用的 DSH 实例。");
                    }
                    ready = client;
                }
                if (ready is not null)
                {
                    var selected = ready;
                    ready = null;
                    return selected;
                }
            }
            finally
            {
                if (ready is not null)
                    await ready.DisposeAsync().ConfigureAwait(false);
            }
        }
        throw new IOException("未找到可验证的 Windows 科研桥。请核对 DSH 和随附科研桥版本。");
    }

    public Task<JsonElement> RequestAsync(string action, object? fields = null, CancellationToken ct = default)
    {
        int timeout = action == "researchDocumentPlan" ? 120_000 : 25_000;
        return InvokeAsync(action, fields, timeout, ct);
    }

    public ValueTask DisposeAsync()
    {
        var secret = Interlocked.Exchange(ref credential, null);
        if (secret is not null)
            CryptographicOperations.ZeroMemory(secret);
        return ValueTask.CompletedTask;
    }

    private async Task<JsonElement> InvokeAsync(string action, object? fields, int timeout, CancellationToken ct)
    {
        var secret = credential ?? throw new ObjectDisposedException(nameof(BridgeClient));
        using var lifetime = CancellationTokenSource.CreateLinkedTokenSource(ct);
        lifetime.CancelAfter(timeout);
        try
        {
            using var pipe = new NamedPipeClientStream(".", endpoint.PipeName, PipeDirection.InOut,
                PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly, TokenImpersonationLevel.Anonymous);
            await pipe.ConnectAsync(lifetime.Token).ConfigureAwait(false);
            if (!GetNamedPipeServerProcessId(pipe.SafePipeHandle, out uint pid) || pid != (uint)endpoint.Pid
                || !GetNamedPipeServerSessionId(pipe.SafePipeHandle, out uint session) || session != (uint)endpoint.SessionId)
                throw new IOException("科研桥的进程或会话身份已变化。");

            var lines = new PipeLines(pipe);
            await AuthenticateAsync(lines, secret, lifetime.Token).ConfigureAwait(false);

            string id = Guid.NewGuid().ToString();
            await lines.WriteAsync(EncodeRequest(id, action, fields), lifetime.Token).ConfigureAwait(false);
            while (true)
            {
                var reply = await lines.ReadAsync(MaxResponseBytes, lifetime.Token).ConfigureAwait(false);
                if (!reply.TryGetProperty("id", out var replyId) || replyId.ValueKind != JsonValueKind.String
                    || replyId.GetString() != id)
                    continue;
                if (reply.TryGetProperty("ok", out var ok) && ok.ValueKind == JsonValueKind.True)
                    return reply;
                if (reply.TryGetProperty("error", out var error) && error.ValueKind == JsonValueKind.Object)
                    throw new BridgeRequestException(StringValue(error, "code") ?? "bridge-error",
                        StringValue(error, "message") ?? "科研桥拒绝了请求。");
                throw new BridgeRequestException("bridge-error", "科研桥拒绝了请求。");
            }
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            throw new TimeoutException("等待科研桥响应超时。");
        }
    }

    private async Task AuthenticateAsync(PipeLines lines, byte[] secret, CancellationToken ct)
    {
        var hello = await lines.ReadAsync(512, ct).ConfigureAwait(false);
        string? challenge = StringValue(hello, "challenge");
        if (challenge is null || !NoncePattern.IsMatch(challenge))
            throw new IOException("科研桥身份检查失败。");
        string clientNonce = Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(32));
        byte[] Proof(string side) => HMACSHA256.HashData(secret,
            Encoding.UTF8.GetBytes($"Research Companion IPC v1\n{side}\n{endpoint.PipeName}\n{challenge}\n{clientNonce}"));
        string proof = Convert.ToHexStringLower(Proof("client"));
        await lines.WriteAsync(JsonSerializer.SerializeToUtf8Bytes(new { clientNonce, proof }), ct).ConfigureAwait(false);
        var verified = await lines.ReadAsync(512, ct).ConfigureAwait(false);
        string? serverProof = StringValue(verified, "proof");
        if (!verified.TryGetProperty("authenticated", out var authenticated) || authenticated.ValueKind != JsonValueKind.True
            || serverProof is null || !NoncePattern.IsMatch(serverProof)
            || !CryptographicOperations.FixedTimeEquals(Convert.FromHexString(serverProof), Proof("server")))
            throw new IOException("科研桥无法证明其 Windows 用户身份。");
    }

    private void ValidateCapabilities()
    {
        if (!Capabilities.TryGetProperty("protocolVersion", out var protocol) || !protocol.TryGetInt32(out int version) || version != 1
            || !Capabilities.TryGetProperty("commandSocket", out var transport) || transport.ValueKind != JsonValueKind.True
            || !Capabilities.TryGetProperty("instance", out var instance) || instance.ValueKind != JsonValueKind.Object
            || StringValue(instance, "instanceId") != endpoint.InstanceId
            || !instance.TryGetProperty("pid", out var pid) || !pid.TryGetInt32(out int serverPid) || serverPid != endpoint.Pid
            || StringValue(instance, "commandSocketPath") != PipePrefix + endpoint.PipeName)
            throw new IOException("科研桥协议或实例不匹配。");
    }

    private static Endpoint? ReadEndpoint(string path, string sid, int session)
    {
        if (IsReparsePoint(path))
            return null;
        using var file = File.Open(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        if (file.Length is <= 0 or > MaxManifestBytes)
            return null;

        using var document = JsonDocument.Parse(file);
        var row = document.RootElement;
        string? id = StringValue(row, "instanceId");
        string? kind = StringValue(row, "kind");
        string? name = StringValue(row, "commandSocketPath");
        string? protectedCredential = StringValue(row, "protectedCredential");
        if (id is null || !InstanceIdPattern.IsMatch(id) || Path.GetFileName(path) != id + ".json"
            || kind is not ("desktop" or "web" or "unknown")
            || !row.TryGetProperty("protocolVersion", out var version) || !version.TryGetInt32(out int protocol) || protocol != 1
            || !row.TryGetProperty("pid", out var pidValue) || !pidValue.TryGetInt32(out int pid) || pid <= 0
            || !row.TryGetProperty("startedAt", out var timeValue) || !timeValue.TryGetInt64(out long startedAt) || startedAt <= 0
            || !row.TryGetProperty("transport", out var transport) || transport.ValueKind != JsonValueKind.Object
            || StringValue(transport, "scheme") != "windows-pipe-v1" || StringValue(transport, "userSid") != sid
            || !transport.TryGetProperty("sessionId", out var sessionValue) || !sessionValue.TryGetInt32(out int serverSession) || serverSession != session
            || protectedCredential is null || protectedCredential.Length > 4096)
            return null;

        string expected = $"ResearchCompanion-v1-{sid}-{session.ToString(CultureInfo.InvariantCulture)}-{id}-c";
        if (name != PipePrefix + expected)
            return null;
        using var process = Process.GetProcessById(pid);
        if (process.SessionId != session || new DateTimeOffset(process.StartTime).ToUnixTimeSeconds() > startedAt + 1)
            return null;
        return new Endpoint(id, kind, pid, session, expected, Convert.FromBase64String(protectedCredential));
    }

    private static bool IsUnavailable(Exception error) =>
        error is IOException or UnauthorizedAccessException or FormatException or ArgumentException
            or JsonException or TimeoutException or CryptographicException or InvalidOperationException
            or System.ComponentModel.Win32Exception;

    private static bool IsReparsePoint(string path) =>
        (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0;

    private static string? StringValue(JsonElement value, string property) =>
        value.ValueKind == JsonValueKind.Object && value.TryGetProperty(property, out var element)
        && element.ValueKind == JsonValueKind.String ? element.GetString() : null;

    private static byte[] EncodeRequest(string id, string action, object? fields)
    {
        using var stream = new MemoryStream();
        using var writer = new Utf8JsonWriter(stream);
        writer.WriteStartObject();
        writer.WriteString("id", id);
        writer.WriteString("action", action);
        if (fields is not null)
        {
            var value = JsonSerializer.SerializeToElement(fields, JsonOptions);
            if (value.ValueKind != JsonValueKind.Object)
                throw new ArgumentException("请求参数必须是 JSON 对象。", nameof(fields));
            foreach (var property in value.EnumerateObject())
            {
                if (property.Name is "id" or "action")
                    throw new ArgumentException("请求参数包含保留字段。", nameof(fields));
                property.WriteTo(writer);
            }
        }
        writer.WriteEndObject();
        writer.Flush();
        return stream.ToArray();
    }

    private sealed class PipeLines(Stream stream)
    {
        private readonly byte[] buffer = new byte[4096];
        private int first;
        private int last;

        public async Task WriteAsync(byte[] bytes, CancellationToken ct)
        {
            await stream.WriteAsync(bytes, ct).ConfigureAwait(false);
            await stream.WriteAsync("\n"u8.ToArray(), ct).ConfigureAwait(false);
            await stream.FlushAsync(ct).ConfigureAwait(false);
        }

        public async Task<JsonElement> ReadAsync(int limit, CancellationToken ct)
        {
            var line = new ArrayBufferWriter<byte>();
            while (true)
            {
                if (first == last)
                {
                    first = 0;
                    last = await stream.ReadAsync(buffer, ct).ConfigureAwait(false);
                    if (last == 0) throw new EndOfStreamException("科研桥连接已关闭。");
                }
                int newline = Array.IndexOf(buffer, (byte)'\n', first, last - first);
                int end = newline < 0 ? last : newline;
                int bytes = end - first;
                if (line.WrittenCount + bytes > limit)
                    throw new IOException("科研桥返回数据超过读取上限。");
                line.Write(buffer.AsSpan(first, bytes));
                first = end;
                if (newline < 0) continue;
                first++;
                using var document = JsonDocument.Parse(line.WrittenMemory);
                if (document.RootElement.ValueKind != JsonValueKind.Object)
                    throw new IOException("科研桥返回了无效数据。");
                return document.RootElement.Clone();
            }
        }
    }

    private static byte[] Unprotect(byte[] encrypted)
    {
        var pinned = GCHandle.Alloc(encrypted, GCHandleType.Pinned);
        try
        {
            var input = new DataBlob { Size = encrypted.Length, Data = pinned.AddrOfPinnedObject() };
            if (!CryptUnprotectData(in input, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 1, out var output))
                throw new CryptographicException("无法解锁当前 Windows 用户的科研桥配对信息。");
            try
            {
                if (output.Size != 32)
                    throw new CryptographicException("科研桥密钥大小无效。");
                byte[] result = new byte[32];
                Marshal.Copy(output.Data, result, 0, result.Length);
                Marshal.Copy(new byte[32], 0, output.Data, 32);
                return result;
            }
            finally
            {
                LocalFree(output.Data);
            }
        }
        finally
        {
            pinned.Free();
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DataBlob
    {
        public int Size;
        public IntPtr Data;
    }

    [DllImport("crypt32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptUnprotectData(in DataBlob input, IntPtr description, IntPtr entropy,
        IntPtr reserved, IntPtr prompt, uint flags, out DataBlob output);

    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr memory);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetNamedPipeServerProcessId(SafePipeHandle pipe, out uint pid);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetNamedPipeServerSessionId(SafePipeHandle pipe, out uint session);
}
