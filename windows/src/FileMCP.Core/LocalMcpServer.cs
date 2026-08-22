using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace FileMCP.Core;

internal sealed record HttpRequestData(string Method, string Path, Dictionary<string, string> Headers, byte[] Body);
internal enum HttpParseStatus { Incomplete, Request, Failure }
internal sealed record HttpParseResult(HttpParseStatus Status, HttpRequestData? Request = null, int FailureStatus = 0, string? FailureMessage = null);

public sealed class LocalMcpServer : IAsyncDisposable
{
    private static readonly HashSet<string> SingleValueHeaders = new(StringComparer.OrdinalIgnoreCase)
    {
        "content-length", "content-type", "host", "origin", "mcp-protocol-version", "mcp-method", "mcp-name",
        "transfer-encoding", FileMcpConstants.LocalAuthHeaderName.ToLowerInvariant(),
    };
    private readonly ushort _port;
    private readonly string _localAuthToken;
    private readonly LocalTools _tools;
    private readonly Action<string> _log;
    private TcpListener? _listener;
    private CancellationTokenSource? _cts;
    private Task? _acceptLoop;

    public LocalMcpServer(ushort port, string allowedDirectory, string gitUserName, string gitUserEmail, bool enableCommands, string localAuthToken, Action<string> log)
    {
        if (Encoding.UTF8.GetByteCount(localAuthToken) < 32) throw new FileMcpException("Local MCP authentication token is too short");
        _port = port; _localAuthToken = localAuthToken; _log = log;
        _tools = new LocalTools(allowedDirectory, gitUserName, gitUserEmail, enableCommands);
    }

    public bool IsReady { get; private set; }

    public Task StartAsync(CancellationToken cancellationToken = default)
    {
        if (_port == 0) throw new FileMcpException("Invalid port: 0");
        try
        {
            _listener = new TcpListener(IPAddress.Loopback, _port) { ExclusiveAddressUse = true };
            _listener.Start();
            _cts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            IsReady = true;
            _acceptLoop = AcceptLoopAsync(_cts.Token);
            _log($"MCP server listening on http://127.0.0.1:{_port}/mcp\n");
            return Task.CompletedTask;
        }
        catch (SocketException ex)
        {
            Stop();
            throw new FileMcpException($"Cannot listen on port {_port}: {ex.Message}");
        }
    }

    public void Stop()
    {
        IsReady = false;
        try { _cts?.Cancel(); } catch { }
        try { _listener?.Stop(); } catch { }
        _listener = null;
    }

    private async Task AcceptLoopAsync(CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            TcpClient client;
            try { client = await _listener!.AcceptTcpClientAsync(cancellationToken).ConfigureAwait(false); }
            catch (OperationCanceledException) { return; }
            catch (ObjectDisposedException) { return; }
            catch (SocketException) when (cancellationToken.IsCancellationRequested) { return; }
            _ = Task.Run(() => HandleClientAsync(client, cancellationToken), CancellationToken.None);
        }
    }

    private async Task HandleClientAsync(TcpClient client, CancellationToken cancellationToken)
    {
        using (client)
        {
            client.NoDelay = true;
            var stream = client.GetStream();
            var buffer = new MemoryStream();
            var readBuffer = new byte[65_536];
            while (!cancellationToken.IsCancellationRequested)
            {
                HttpParseResult parsed;
                try { parsed = ParseHttpRequest(buffer.ToArray()); }
                catch { parsed = new HttpParseResult(HttpParseStatus.Failure, FailureStatus: 400, FailureMessage: "Malformed request"); }
                if (parsed.Status == HttpParseStatus.Request)
                {
                    byte[] response;
                    try
                    {
                        response = await ProcessAsync(parsed.Request!, cancellationToken).ConfigureAwait(false);
                    }
                    catch
                    {
                        _log("ERROR: MCP request processing failed.\n");
                        response = JsonRpcError(null, -32603, "Internal error", status: 500);
                    }
                    await stream.WriteAsync(response, cancellationToken).ConfigureAwait(false);
                    return;
                }
                if (parsed.Status == HttpParseStatus.Failure)
                {
                    var response = HttpResponse(parsed.FailureStatus, Encoding.UTF8.GetBytes(parsed.FailureMessage ?? "Error"), "text/plain");
                    await stream.WriteAsync(response, cancellationToken).ConfigureAwait(false);
                    return;
                }
                if (buffer.Length > FileMcpConstants.MaxHttpRequestHeaderBytes + FileMcpConstants.MaxHttpRequestBodyBytes)
                {
                    var response = HttpResponse(413, Encoding.UTF8.GetBytes("Payload too large"), "text/plain");
                    await stream.WriteAsync(response, cancellationToken).ConfigureAwait(false);
                    return;
                }
                int read;
                try { read = await stream.ReadAsync(readBuffer, cancellationToken).ConfigureAwait(false); }
                catch (OperationCanceledException) { return; }
                if (read <= 0) return;
                buffer.Write(readBuffer, 0, read);
            }
        }
    }

    internal HttpParseResult ParseHttpRequest(byte[] data)
    {
        var separator = "\r\n\r\n"u8.ToArray();
        var headerEnd = IndexOf(data, separator);
        if (headerEnd < 0)
            return data.Length > FileMcpConstants.MaxHttpRequestHeaderBytes
                ? new(HttpParseStatus.Failure, FailureStatus: 431, FailureMessage: "Request headers too large") : new(HttpParseStatus.Incomplete);
        if (headerEnd > FileMcpConstants.MaxHttpRequestHeaderBytes) return new(HttpParseStatus.Failure, FailureStatus: 431, FailureMessage: "Request headers too large");
        string headerText;
        try { headerText = new UTF8Encoding(false, true).GetString(data, 0, headerEnd); }
        catch (DecoderFallbackException) { return new(HttpParseStatus.Failure, FailureStatus: 400, FailureMessage: "Malformed request headers"); }
        var lines = headerText.Split("\r\n", StringSplitOptions.None);
        if (lines.Length == 0) return new(HttpParseStatus.Failure, FailureStatus: 400, FailureMessage: "Malformed request line");
        var parts = lines[0].Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length != 3 || (parts[2] != "HTTP/1.1" && parts[2] != "HTTP/1.0")) return new(HttpParseStatus.Failure, FailureStatus: 400, FailureMessage: "Malformed request line");

        var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var line in lines.Skip(1))
        {
            var colon = line.IndexOf(':'); if (colon < 0) return new(HttpParseStatus.Failure, FailureStatus: 400, FailureMessage: "Malformed request header");
            var rawKey = line[..colon]; var key = rawKey.Trim(); var value = line[(colon + 1)..].Trim();
            if (rawKey != key || !IsValidHeaderName(key) || !IsValidHeaderValue(value)) return new(HttpParseStatus.Failure, FailureStatus: 400, FailureMessage: "Malformed request header");
            key = key.ToLowerInvariant();
            if (SingleValueHeaders.Contains(key) && headers.ContainsKey(key)) return new(HttpParseStatus.Failure, FailureStatus: 400, FailureMessage: $"Duplicate {key} header");
            headers[key] = value;
        }
        if (headers.ContainsKey("transfer-encoding")) return new(HttpParseStatus.Failure, FailureStatus: 400, FailureMessage: "Transfer-Encoding is not supported");
        if (!headers.TryGetValue("host", out var host) || host.Length == 0) return new(HttpParseStatus.Failure, FailureStatus: 400, FailureMessage: "Missing Host header");
        if (!IsAllowedHost(host)) return new(HttpParseStatus.Failure, FailureStatus: 403, FailureMessage: "Forbidden host");
        if (headers.TryGetValue("origin", out var origin) && !IsAllowedOrigin(origin)) return new(HttpParseStatus.Failure, FailureStatus: 403, FailureMessage: "Forbidden origin");

        var contentLength = 0;
        if (headers.TryGetValue("content-length", out var rawLength))
        {
            if (rawLength.Length == 0 || rawLength.Any(ch => ch is < '0' or > '9') || !int.TryParse(rawLength, out contentLength)) return new(HttpParseStatus.Failure, FailureStatus: 400, FailureMessage: "Invalid Content-Length header");
            if (contentLength > FileMcpConstants.MaxHttpRequestBodyBytes) return new(HttpParseStatus.Failure, FailureStatus: 413, FailureMessage: "Payload too large");
        }
        if (!headers.TryGetValue(FileMcpConstants.LocalAuthHeaderName, out var token) || !ConstantTimeEquals(token, _localAuthToken)) return new(HttpParseStatus.Failure, FailureStatus: 401, FailureMessage: "Unauthorized");

        var bodyStart = headerEnd + separator.Length; var available = data.Length - bodyStart;
        if (available < contentLength) return new(HttpParseStatus.Incomplete);
        if (available != contentLength) return new(HttpParseStatus.Failure, FailureStatus: 400, FailureMessage: "Unexpected bytes after request body");
        var body = data.AsSpan(bodyStart, contentLength).ToArray(); var path = parts[1].Split('?', 2)[0];
        return new(HttpParseStatus.Request, new HttpRequestData(parts[0].ToUpperInvariant(), path, headers, body));
    }

    private async Task<byte[]> ProcessAsync(HttpRequestData request, CancellationToken cancellationToken)
    {
        if (request.Method == "OPTIONS") return HttpResponse(204, [], "text/plain");
        if (request.Path != "/mcp") return HttpResponse(404, Encoding.UTF8.GetBytes("Not found"), "text/plain");
        if (request.Method is "GET" or "DELETE") return HttpResponse(405, Encoding.UTF8.GetBytes("Method not allowed"), "text/plain");
        if (request.Method != "POST") return HttpResponse(405, Encoding.UTF8.GetBytes("Method not allowed"), "text/plain");
        if (!IsJsonContentType(request.Headers.GetValueOrDefault("content-type"))) return HttpResponse(415, Encoding.UTF8.GetBytes("Content-Type must be application/json"), "text/plain");
        JsonObject message;
        try { message = JsonNode.Parse(request.Body)?.AsObject() ?? throw new JsonException(); }
        catch { return JsonRpcError(null, -32700, "Parse error", status: 400); }
        if (message["jsonrpc"]?.GetValue<string>() != "2.0") return JsonRpcError(null, -32600, "Invalid Request", status: 400);
        if (message["method"] is not JsonValue methodNode || !methodNode.TryGetValue<string>(out var method)) return JsonRpcError(message["id"], -32600, "Invalid Request", status: 400);
        var id = message["id"]?.DeepClone();
        var headerVersion = request.Headers.GetValueOrDefault("mcp-protocol-version");
        var headerModern = headerVersion is not null && !FileMcpConstants.LegacySupportedVersions.Contains(headerVersion);
        JsonObject parameters;
        if (message["params"] is null) parameters = new JsonObject();
        else if (message["params"] is JsonObject obj) parameters = obj;
        else return JsonRpcError(id, -32602, "Invalid params: expected an object", status: headerModern ? 400 : 200);
        var meta = parameters["_meta"] as JsonObject; var bodyVersion = meta?["io.modelcontextprotocol/protocolVersion"]?.GetValue<string>();
        var bodyModern = bodyVersion is not null && !FileMcpConstants.LegacySupportedVersions.Contains(bodyVersion); var modernIntent = headerModern || bodyModern;
        if (modernIntent && headerVersion is not null && bodyVersion is not null && headerVersion != bodyVersion) return HeaderMismatch(id, $"MCP-Protocol-Version header '{headerVersion}' does not match body protocol version '{bodyVersion}'");
        if (headerVersion is not null && headerVersion != FileMcpConstants.ModernProtocolVersion && !FileMcpConstants.LegacySupportedVersions.Contains(headerVersion)) return UnsupportedProtocol(id, headerVersion);
        if (modernIntent)
        {
            var error = ValidateModernRequest(request, method, parameters, id); if (error is not null) return error;
            if (message["id"] is null) return HttpResponse(202, [], "application/json");
            return await ProcessModernRequestAsync(id, method, parameters, cancellationToken).ConfigureAwait(false);
        }
        if (message["id"] is null) return HttpResponse(202, [], "application/json");
        return await ProcessLegacyRequestAsync(id, method, parameters, cancellationToken).ConfigureAwait(false);
    }

    private async Task<byte[]> ProcessLegacyRequestAsync(JsonNode? id, string method, JsonObject parameters, CancellationToken cancellationToken) => method switch
    {
        "initialize" => JsonRpcResult(id, new JsonObject { ["protocolVersion"] = NegotiateLegacy(parameters["protocolVersion"]?.GetValue<string>()), ["capabilities"] = ServerCapabilities(), ["serverInfo"] = ServerInfo() }),
        "ping" => JsonRpcResult(id, new JsonObject()),
        "tools/list" => JsonRpcResult(id, new JsonObject { ["tools"] = _tools.ToolDefinitions }),
        "tools/call" => await CallToolAsync(id, parameters, false, cancellationToken).ConfigureAwait(false),
        _ => JsonRpcError(id, -32601, $"Method not found: {method}"),
    };

    private async Task<byte[]> ProcessModernRequestAsync(JsonNode? id, string method, JsonObject parameters, CancellationToken cancellationToken)
    {
        if (method == "server/discover") { var result = ModernComplete(new JsonObject { ["supportedVersions"] = new JsonArray(FileMcpConstants.ModernProtocolVersion), ["capabilities"] = ServerCapabilities(), ["instructions"] = "Read and manage files, Git repositories, and optionally local commands inside the configured shared directory." }); result["ttlMs"] = 60_000; result["cacheScope"] = "private"; return JsonRpcResult(id, result); }
        if (method == "ping") return JsonRpcResult(id, ModernComplete(new JsonObject()));
        if (method == "tools/list") { var result = ModernComplete(new JsonObject { ["tools"] = _tools.ToolDefinitions }); result["ttlMs"] = 30_000; result["cacheScope"] = "private"; return JsonRpcResult(id, result); }
        if (method == "tools/call") return await CallToolAsync(id, parameters, true, cancellationToken).ConfigureAwait(false);
        return JsonRpcError(id, -32601, $"Method not found: {method}", status: 404);
    }

    private async Task<byte[]> CallToolAsync(JsonNode? id, JsonObject parameters, bool modern, CancellationToken cancellationToken)
    {
        if (parameters["name"] is not JsonValue nameNode || !nameNode.TryGetValue<string>(out var name)) return JsonRpcError(id, -32602, "Missing tool name", status: modern ? 400 : 200);
        if (!_tools.HasTool(name)) return JsonRpcError(id, -32602, $"Unknown tool: {name}");
        JsonObject arguments;
        if (parameters["arguments"] is null) arguments = new JsonObject();
        else if (parameters["arguments"] is JsonObject obj) arguments = obj;
        else { var invalid = new JsonObject { ["content"] = new JsonArray(new JsonObject { ["type"] = "text", ["text"] = "Invalid arguments: expected an object" }), ["isError"] = true }; if (modern) invalid = ModernComplete(invalid); return JsonRpcResult(id, invalid); }
        try
        {
            var output = await _tools.CallAsync(name, arguments, cancellationToken).ConfigureAwait(false);
            var result = new JsonObject { ["content"] = output.Content, ["structuredContent"] = output.StructuredContent, ["isError"] = false };
            if (modern) result = ModernComplete(result); return JsonRpcResult(id, result);
        }
        catch (Exception ex)
        {
            var result = new JsonObject { ["content"] = new JsonArray(new JsonObject { ["type"] = "text", ["text"] = ex.Message }), ["isError"] = true };
            if (modern) result = ModernComplete(result); return JsonRpcResult(id, result);
        }
    }

    private byte[]? ValidateModernRequest(HttpRequestData request, string method, JsonObject parameters, JsonNode? id)
    {
        if (!request.Headers.TryGetValue("mcp-protocol-version", out var headerVersion)) return HeaderMismatch(id, "Missing required MCP-Protocol-Version header");
        if (headerVersion != FileMcpConstants.ModernProtocolVersion) return FileMcpConstants.LegacySupportedVersions.Contains(headerVersion) ? HeaderMismatch(id, "MCP-Protocol-Version header does not match the modern request metadata") : UnsupportedProtocol(id, headerVersion);
        if (parameters["_meta"] is not JsonObject meta) return JsonRpcError(id, -32602, "Missing required params._meta", status: 400);
        var bodyVersion = meta["io.modelcontextprotocol/protocolVersion"]?.GetValue<string>(); if (bodyVersion is null) return JsonRpcError(id, -32602, "Missing required _meta.io.modelcontextprotocol/protocolVersion", status: 400);
        if (bodyVersion != FileMcpConstants.ModernProtocolVersion) return bodyVersion == headerVersion ? UnsupportedProtocol(id, bodyVersion) : HeaderMismatch(id, $"MCP-Protocol-Version header '{headerVersion}' does not match body protocol version '{bodyVersion}'");
        if (meta["io.modelcontextprotocol/clientCapabilities"] is not JsonObject) return JsonRpcError(id, -32602, "Missing required _meta.io.modelcontextprotocol/clientCapabilities", status: 400);
        if (meta["io.modelcontextprotocol/clientInfo"] is JsonNode info)
        {
            if (info is not JsonObject implementation ||
                implementation["name"] is not JsonValue nameValue || !nameValue.TryGetValue<string>(out _) ||
                implementation["version"] is not JsonValue versionValue || !versionValue.TryGetValue<string>(out _))
                return JsonRpcError(id, -32602, "Invalid _meta.io.modelcontextprotocol/clientInfo", status: 400);
        }
        if (!request.Headers.TryGetValue("mcp-method", out var methodHeader)) return HeaderMismatch(id, "Missing required Mcp-Method header");
        if (methodHeader != method) return HeaderMismatch(id, $"Mcp-Method header '{methodHeader}' does not match body method '{method}'");
        if (method == "tools/call")
        {
            var toolName = parameters["name"]?.GetValue<string>(); if (toolName is null) return JsonRpcError(id, -32602, "Missing tool name", status: 400);
            if (!request.Headers.TryGetValue("mcp-name", out var encoded)) return HeaderMismatch(id, "Missing required Mcp-Name header");
            var decoded = DecodeHeaderValue(encoded); if (decoded is null) return HeaderMismatch(id, "Malformed Mcp-Name header");
            if (decoded != toolName) return HeaderMismatch(id, $"Mcp-Name header value '{decoded}' does not match body value '{toolName}'");
        }
        return null;
    }

    private static string NegotiateLegacy(string? requested) => requested is not null && FileMcpConstants.LegacySupportedVersions.Contains(requested) ? requested : FileMcpConstants.LatestLegacyProtocolVersion;
    private static JsonObject ModernComplete(JsonObject fields) { fields["resultType"] = "complete"; fields["_meta"] = new JsonObject { ["io.modelcontextprotocol/serverInfo"] = ServerInfo() }; return fields; }
    private static JsonObject ServerInfo() => new() { ["name"] = FileMcpConstants.ServerName, ["version"] = FileMcpConstants.ServerVersion };
    private static JsonObject ServerCapabilities() => new() { ["tools"] = new JsonObject { ["listChanged"] = false } };

    internal static bool IsAllowedHost(string value)
    {
        var trimmed = value.Trim().ToLowerInvariant(); if (trimmed.Length == 0) return false;
        if (trimmed.StartsWith('[')) { var close = trimmed.IndexOf(']'); if (close < 0) return false; var host = trimmed[1..close]; var rest = trimmed[(close + 1)..]; if (rest.Length > 0 && (!rest.StartsWith(':') || !ValidPort(rest[1..]))) return false; return host == "::1"; }
        var parts = trimmed.Split(':', 2); if (parts.Length == 2 && !ValidPort(parts[1])) return false; return parts[0] is "localhost" or "127.0.0.1";
    }

    internal static bool IsAllowedOrigin(string origin)
    {
        if (!Uri.TryCreate(origin, UriKind.Absolute, out var uri) || !string.IsNullOrEmpty(uri.UserInfo) || !string.IsNullOrEmpty(uri.Query) || !string.IsNullOrEmpty(uri.Fragment) || uri.AbsolutePath != "/") return false;
        var host = uri.Host.ToLowerInvariant(); var scheme = uri.Scheme.ToLowerInvariant();
        if ((scheme is "http" or "https") && (host is "localhost" or "127.0.0.1" or "::1")) return uri.Port is >= 0 and <= 65535;
        if (scheme == "https" && (host == "chatgpt.com" || host.EndsWith(".chatgpt.com", StringComparison.Ordinal))) return uri.IsDefaultPort || uri.Port == 443;
        return false;
    }

    private static bool ValidPort(string value) => value.Length > 0 && value.All(char.IsAsciiDigit) && uint.TryParse(value, out var port) && port <= 65535;
    private static bool IsJsonContentType(string? value) => value?.Split(';', 2)[0].Trim().Equals("application/json", StringComparison.OrdinalIgnoreCase) == true;
    private static bool IsValidHeaderName(string value) => value.Length > 0 && value.All(ch => char.IsAsciiLetterOrDigit(ch) || "!#$%&'*+-.^_`|~".Contains(ch));
    private static bool IsValidHeaderValue(string value) => value.All(ch => ch == '\t' || (ch >= ' ' && ch != '\u007f'));
    private static bool ConstantTimeEquals(string lhs, string rhs) => CryptographicOperations.FixedTimeEquals(Encoding.UTF8.GetBytes(lhs), Encoding.UTF8.GetBytes(rhs));
    private static string? DecodeHeaderValue(string value)
    {
        const string prefix = "=?base64?", suffix = "?=";
        if (value.StartsWith(prefix, StringComparison.Ordinal) && value.EndsWith(suffix, StringComparison.Ordinal))
        {
            try { return new UTF8Encoding(false, true).GetString(Convert.FromBase64String(value[prefix.Length..^suffix.Length])); }
            catch { return null; }
        }
        return value.All(ch => ch == '\t' || ch is >= ' ' and <= '~') ? value : null;
    }

    private static byte[] HeaderMismatch(JsonNode? id, string message) => JsonRpcError(id, -32020, "Header mismatch: " + message, status: 400);
    private static byte[] UnsupportedProtocol(JsonNode? id, string requested) => JsonRpcError(id, -32022, "Unsupported protocol version: " + requested, new JsonObject { ["supported"] = new JsonArray(FileMcpConstants.AllSupportedVersions.Select(v => JsonValue.Create(v)).ToArray()), ["requested"] = requested }, 400);
    private static byte[] JsonRpcResult(JsonNode? id, JsonNode result) => JsonResponse(new JsonObject { ["jsonrpc"] = "2.0", ["id"] = id?.DeepClone(), ["result"] = result });
    private static byte[] JsonRpcError(JsonNode? id, int code, string message, JsonNode? data = null, int status = 200) { var error = new JsonObject { ["code"] = code, ["message"] = message }; if (data is not null) error["data"] = data; return JsonResponse(new JsonObject { ["jsonrpc"] = "2.0", ["id"] = id?.DeepClone(), ["error"] = error }, status); }
    private static byte[] JsonResponse(JsonNode node, int status = 200) => HttpResponse(status, Encoding.UTF8.GetBytes(node.ToJsonString()), "application/json");

    private static byte[] HttpResponse(int status, byte[] body, string contentType)
    {
        var reason = status switch { 200 => "OK", 202 => "Accepted", 204 => "No Content", 400 => "Bad Request", 401 => "Unauthorized", 403 => "Forbidden", 404 => "Not Found", 405 => "Method Not Allowed", 413 => "Payload Too Large", 415 => "Unsupported Media Type", 431 => "Request Header Fields Too Large", 500 => "Internal Server Error", _ => "Error" };
        var header = Encoding.ASCII.GetBytes($"HTTP/1.1 {status} {reason}\r\nContent-Type: {contentType}\r\nContent-Length: {body.Length}\r\nConnection: close\r\n\r\n");
        var response = new byte[header.Length + body.Length]; Buffer.BlockCopy(header, 0, response, 0, header.Length); Buffer.BlockCopy(body, 0, response, header.Length, body.Length); return response;
    }

    private static int IndexOf(byte[] source, byte[] pattern)
    {
        for (var i = 0; i <= source.Length - pattern.Length; i++) { var match = true; for (var j = 0; j < pattern.Length; j++) if (source[i + j] != pattern[j]) { match = false; break; } if (match) return i; }
        return -1;
    }

    public async ValueTask DisposeAsync()
    {
        Stop(); if (_acceptLoop is not null) { try { await _acceptLoop.ConfigureAwait(false); } catch { } }
        _cts?.Dispose();
    }
}
