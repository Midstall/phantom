//! Sockets that are not sockets: enough of one for HTTP to work in a browser.
//!
//! A browser hands out no socket. It hands out `fetch`, which is a whole request
//! and a whole response at once, and it does TLS itself. `std.http.Client` wants
//! to write an HTTP/1.1 request into a stream and read the reply back out of it.
//! This file is the join: a connection here buffers everything written to it,
//! and the first read is what actually sends the request and answers with the
//! reply, rebuilt as the HTTP/1.1 response the caller expected to read.
//!
//! Why this shape rather than a request function of our own: an application then
//! writes ordinary Zig. `std.http.Client`, and anything built on it, works with
//! no web-specific branch anywhere in it.
//!
//! THE ONE RULE AN APPLICATION HAS TO FOLLOW:
//!
//!     Ask for `http://`, name the page's OWN host, and write NO PORT.
//!
//!     `http://sigil.example/api/sites`         yes
//!     `http://sigil.example:443/api/sites`     no
//!     `https://sigil.example/api/sites`        no
//!
//! Those look like three tips and they are one rule. Each part is useless without
//! the others, and the failure when they are split is misleading rather than
//! obvious.
//!
//! The no-port part is the surprising one, because `:443` looks like the more
//! careful spelling and is the one that fails. A URL with no port parses as port
//! 80, and port 80 is the only shape `requestUrl` hands to the browser as a bare
//! target. Any other port is read as a request for a DIFFERENT service, which is
//! what stops one from silently becoming a request to the page itself.
//!
//! The `http` half is forced: `std.http.Client` runs its own TLS handshake for an
//! `https` URL, and a socket that is really `fetch` cannot answer one, because it
//! would have to BE a TLS server. So a connection here always speaks plaintext
//! HTTP/1.1 and the browser adds the transport security.
//!
//! The page's-own-host half is what makes the `http` half safe. `requestUrl`
//! hands a request for the page's host to the browser as a bare target and lets
//! the PAGE resolve it, so it goes out over the page's real scheme and port, with
//! the page's cookies. Nothing is ever actually sent in the clear.
//!
//! Split the rule and a literal `http://` to some OTHER host from an `https` page
//! fails TWICE: once as mixed content, and once at `connect-src` under any strict
//! Content Security Policy. The second error is the one the developer is shown,
//! and it points at the policy rather than at the URL, which is the wrong place
//! to start looking.
//!
//! THE OTHER THING IT CANNOT DO, because a browser owns it:
//!   * Streaming. The reply arrives whole or not at all, so a caller that expects
//!     to read a response while it is still coming in reads it after it has
//!     finished instead. Nothing observable breaks; the timing changes.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// How many connections can be open at once. A browser page holds a handful of
/// requests in flight, never hundreds, and a fixed table means no allocation on
/// the connect path and a runaway caller that is refused instead of unbounded.
pub const max_conns = 16;

/// The longest host name a connection remembers. Longer than any real one, and
/// the check is a refusal rather than a truncation: half a host name names a
/// different machine.
pub const max_host = 255;

/// One request, as the host has to see it. The pieces are separate rather than a
/// finished URL, because only the host knows the page it is running on and so
/// only the host can resolve the scheme. See `requestUrl`.
pub const Request = struct {
    method: []const u8,
    host: []const u8,
    port: u16,
    /// The request target from the request line: a path, with its query.
    target: []const u8,
    /// The header block as the caller wrote it, `Name: Value\r\n` lines, with no
    /// blank line at the end.
    headers: []const u8,
    body: []const u8,
};

/// Runs one request to completion and returns the whole HTTP/1.1 response as an
/// owned slice, or null when it never arrived.
///
/// Blocking is the point and it is the hard part: on the web this is a suspension
/// through JSPI where the browser has it, and a synchronous XMLHttpRequest where
/// it does not. Both look the same from here.
///
/// Null means the request did not happen: no network, DNS failure, a blocked
/// request. It does NOT mean an error status. A 403 is a response and arrives as
/// one, because "the server said no" and "nothing answered" send a reader of the
/// result to two different places.
///
/// ONE CASE OF NULL IS NOT THE NETWORK, and it is worth knowing before spending
/// an afternoon on a connection that was never broken. A server that answers with
/// a redirect to ANOTHER ORIGIN is followed by the browser, and a page with a
/// strict `connect-src` then refuses the followed request. `fetch` rejects for
/// that the same way it rejects for a dead network, with no way to tell them
/// apart, so it arrives here as null and reaches the application as a transport
/// failure. The page prints what really happened to the console, naming the URI
/// the policy refused. A route whose redirect IS the answer has to be navigated
/// to rather than requested, and this is the shape that failure takes.
pub const Hook = struct {
    ctx: *anyopaque,
    send: *const fn (ctx: *anyopaque, gpa: Allocator, req: Request) ?[]u8,
};

/// A connection's whole life: what has been written to it, and what came back.
const Conn = struct {
    open: bool = false,
    host_buf: [max_host]u8 = undefined,
    host_len: usize = 0,
    port: u16 = 0,
    /// Everything the caller has written, which is the HTTP/1.1 request.
    req: std.ArrayList(u8) = .empty,
    /// The response, owned, once the request has been sent. Null until then.
    res: ?[]u8 = null,
    /// How much of `res` has been read out.
    read: usize = 0,
    /// Set when the request was sent and nothing came back. The read that
    /// triggered it reports it, and every read after that reports it too, rather
    /// than silently answering with an empty stream that reads as a clean close.
    failed: bool = false,

    fn host(self: *const Conn) []const u8 {
        return self.host_buf[0..self.host_len];
    }
};

/// What a write can fail with: a slot nothing opened, or no room to buffer the
/// request. Spelled out rather than inferred, so a caller mapping these onto
/// `std.Io`'s own error set can see the whole list in one place.
pub const WriteError = error{ SocketUnconnected, OutOfMemory };

/// What a read can fail with. No `OutOfMemory` in it: a read allocates nothing,
/// because the host allocated the response before it ever got here.
pub const ReadError = error{ SocketUnconnected, NetworkDown };

/// A name parked between a lookup and the connect that follows it.
const Name = struct {
    buf: [max_host]u8 = undefined,
    len: usize = 0,
    port: u16 = 0,

    fn host(self: *const Name) []const u8 {
        return self.buf[0..self.len];
    }
};

/// How many looked-up names are remembered at once. An entry is needed only for
/// the handful of calls between a lookup and its connect, so a small ring is
/// plenty and an entry nothing connects to is overwritten rather than leaked.
pub const max_names = 16;

/// The connection table. One per page, held by the `WebApp`, which is why it
/// takes no allocator of its own: every connection borrows the app's.
pub const Net = struct {
    gpa: Allocator,
    hook: ?Hook = null,
    conns: [max_conns]Conn = @splat(.{}),
    /// The connection a read or a write means on a target whose socket handle
    /// carries nothing. See `handled` in web.zig.
    current: usize = 0,
    /// See `remember`. Not connections: names waiting to become one.
    names: [max_names]Name = @splat(.{}),
    next_name: usize = 0,

    pub fn deinit(self: *Net) void {
        for (&self.conns) |*c| self.release(c);
        self.* = undefined;
    }

    fn release(self: *Net, c: *Conn) void {
        c.req.deinit(self.gpa);
        if (c.res) |r| self.gpa.free(r);
        c.* = .{};
    }

    /// Park a name a lookup was asked about, and return the byte that stands for
    /// it inside the address handed back. Null when the name does not fit.
    ///
    /// A browser resolves nothing for us: it takes a URL and does its own DNS. So
    /// a lookup here does not resolve, it remembers, and the address it answers
    /// with means no more than "the name in slot n". `connect` is where the name
    /// is wanted and an address is all that reaches it.
    pub fn remember(self: *Net, host_name: []const u8, port: u16) ?u8 {
        if (host_name.len > max_host) return null;
        const i = self.next_name;
        self.next_name = (self.next_name + 1) % self.names.len;
        self.names[i] = .{ .len = host_name.len, .port = port };
        @memcpy(self.names[i].buf[0..host_name.len], host_name);
        // Offset by one so the encoded byte is never zero: `127.0.0.0` is not an
        // address anything should be dialling, and a zero there is far more
        // likely to be an address that never came from `remember` at all.
        return @intCast(i + 1);
    }

    /// The name behind an encoded byte, or null when it stands for nothing this
    /// table parked: an address the caller built itself, or one whose entry has
    /// since been overwritten.
    pub fn recall(self: *Net, byte: u8) ?struct { host: []const u8, port: u16 } {
        if (byte == 0 or byte > self.names.len) return null;
        const n = &self.names[byte - 1];
        if (n.len == 0) return null;
        return .{ .host = n.host(), .port = n.port };
    }

    /// Claim a slot for `host_name`. Returns the slot index, which is what a
    /// socket handle is here. Null when the table is full or the name does not
    /// fit, both of which the caller turns into a connect failure.
    pub fn open(self: *Net, host_name: []const u8, port: u16) ?usize {
        if (host_name.len > max_host) return null;
        for (&self.conns, 0..) |*c, i| {
            if (c.open) continue;
            c.* = .{ .open = true, .port = port, .host_len = host_name.len };
            @memcpy(c.host_buf[0..host_name.len], host_name);
            self.current = i;
            return i;
        }
        return null;
    }

    pub fn close(self: *Net, slot: usize) void {
        if (slot >= self.conns.len) return;
        self.release(&self.conns[slot]);
    }

    fn get(self: *Net, slot: usize) ?*Conn {
        if (slot >= self.conns.len) return null;
        const c = &self.conns[slot];
        return if (c.open) c else null;
    }

    /// Buffer what the caller wrote. Nothing leaves the machine here: the
    /// request is not known to be finished until the caller asks to read, so
    /// sending on each write would send a torn request.
    pub fn write(self: *Net, slot: usize, bytes: []const u8) WriteError!usize {
        const c = self.get(slot) orelse return error.SocketUnconnected;
        try c.req.appendSlice(self.gpa, bytes);
        return bytes.len;
    }

    /// Read the response, sending the request first if that has not happened.
    ///
    /// This is where the blocking lives, and it is the right place for it: the
    /// caller has written its whole request and is now asking for the answer,
    /// which is exactly the moment a real socket would have to wait.
    ///
    /// Returns 0 at the end of the response, which a reader sees as the peer
    /// closing, and that is what it is: one `fetch` is one exchange.
    pub fn read(self: *Net, slot: usize, out: []u8) ReadError!usize {
        const c = self.get(slot) orelse return error.SocketUnconnected;
        if (c.res == null and !c.failed) try self.send(c);
        if (c.failed) return error.NetworkDown;
        const res = c.res orelse return error.NetworkDown;
        if (c.read >= res.len) return 0;
        const n = @min(out.len, res.len - c.read);
        @memcpy(out[0..n], res[c.read..][0..n]);
        c.read += n;
        return n;
    }

    fn send(self: *Net, c: *Conn) ReadError!void {
        const hook = self.hook orelse return error.NetworkDown;
        const parsed = parseRequest(c.req.items) orelse return error.NetworkDown;
        const req = Request{
            .method = parsed.method,
            .host = c.host(),
            .port = c.port,
            .target = parsed.target,
            .headers = parsed.headers,
            .body = parsed.body,
        };
        c.res = hook.send(hook.ctx, self.gpa, req) orelse {
            c.failed = true;
            return error.NetworkDown;
        };
    }
};

/// The parts of an HTTP/1.1 request, borrowed from the bytes the caller wrote.
pub const ParsedRequest = struct {
    method: []const u8,
    target: []const u8,
    headers: []const u8,
    body: []const u8,
};

/// Split a written request into its parts. Null when it is not a request at all:
/// no request line, or no blank line ending the headers.
///
/// Deliberately not a validating parser. These bytes came from `std.http.Client`
/// one function call ago, so the job is to find the pieces the browser needs, not
/// to police a peer.
pub fn parseRequest(buf: []const u8) ?ParsedRequest {
    const head_end = std.mem.indexOf(u8, buf, "\r\n\r\n") orelse return null;
    const head = buf[0..head_end];
    const line_end = std.mem.indexOf(u8, head, "\r\n") orelse head.len;
    const line = head[0..line_end];

    const sp1 = std.mem.indexOfScalar(u8, line, ' ') orelse return null;
    const rest = line[sp1 + 1 ..];
    const sp2 = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;

    return .{
        .method = line[0..sp1],
        .target = rest[0..sp2],
        .headers = if (line_end == head.len) "" else head[line_end + 2 ..],
        .body = buf[head_end + 4 ..],
    };
}

/// Build the URL the browser should fetch.
///
/// A request for the page's own host is handed over as the bare target, with no
/// scheme and no host on it at all. The browser then resolves it against the page,
/// which is what makes the whole arrangement work: the application asked for
/// `http` because its socket cannot do TLS, and the request still goes out over
/// the page's real scheme and port, to the page's own origin, with the page's
/// cookies on it. Guessing a scheme and a port here could only get that wrong.
///
/// Anywhere else there is no page to resolve against, so the URL is built out and
/// the port decides the scheme: 443 is https, everything else is http. The port
/// is left off when it is that scheme's default, because `https://host:443/x` and
/// `https://host/x` are not the same origin to a cookie.
pub fn requestUrl(gpa: Allocator, page_host: []const u8, req: Request) ![]u8 {
    // The port has to match as well as the name, and 80 is what counts as a
    // match, because the one rule an application follows ("ask for http, name
    // the page's own host") is what produces port 80 and nothing else does.
    //
    // Without this check a request for a DIFFERENT service on the same machine,
    // `http://localhost:9/admin` from a page on `localhost:8443`, would be handed
    // over as the bare target `/admin` and be sent to the page's own origin with
    // the page's cookies on it. An application asking to talk to something else
    // would silently be talking to itself, authenticated. Any other port builds a
    // real cross-origin URL instead, which fails visibly if it is not allowed.
    if (req.port == 80 and std.mem.eql(u8, req.host, page_host)) return gpa.dupe(u8, req.target);
    const scheme = if (req.port == 443) "https" else "http";
    const default_port: u16 = if (req.port == 443) 443 else 80;
    if (req.port == default_port) {
        return std.fmt.allocPrint(gpa, "{s}://{s}{s}", .{ scheme, req.host, req.target });
    }
    return std.fmt.allocPrint(gpa, "{s}://{s}:{d}{s}", .{ scheme, req.host, req.port, req.target });
}

/// Rebuild the HTTP/1.1 response a socket serves, out of the three things a
/// browser can tell us about a reply.
///
/// `headers` is the block a browser hands back, which is `\r\n` separated with a
/// trailing separator and lower-cased names. It is passed through as it is: a
/// header block does not have to be pretty to parse, and rewriting it would be a
/// chance to change what the server said.
///
/// A `content-length` is appended when the block has none, which is what makes
/// the reply readable as a message rather than as a stream that ends whenever the
/// connection does.
///
/// `connection: close` is appended for a reason worth spelling out, because
/// leaving it off looked harmless and was not. One connection here is ONE `fetch`
/// and can never carry a second exchange: the request buffer has already been
/// spent and the response has already been read to its end. HTTP/1.1 keeps a
/// connection alive by default, so without this the client puts the connection
/// back in its pool, writes the next request onto a buffer that was already sent,
/// reads zero bytes and reports the connection closing. That is the ordinary
/// sequential case, not an edge: two requests on one `std.http.Client`.
pub fn buildResponse(gpa: Allocator, status: u16, headers: []const u8, body: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    // No reason phrase: the status number carries the meaning, every parser
    // treats the phrase as decoration, and inventing one would put words in the
    // server's mouth.
    try out.print(gpa, "HTTP/1.1 {d} \r\n", .{status});
    try out.appendSlice(gpa, headers);
    if (headers.len > 0 and !std.mem.endsWith(u8, headers, "\r\n")) {
        try out.appendSlice(gpa, "\r\n");
    }
    if (!hasHeader(headers, "content-length")) {
        try out.print(gpa, "content-length: {d}\r\n", .{body.len});
    }
    if (!hasHeader(headers, "connection")) {
        try out.appendSlice(gpa, "connection: close\r\n");
    }
    try out.appendSlice(gpa, "\r\n");
    try out.appendSlice(gpa, body);
    return out.toOwnedSlice(gpa);
}

/// Whether `block` already carries `name`, matched case-insensitively at the
/// start of a line, which is the only place a header name can be.
fn hasHeader(block: []const u8, name: []const u8) bool {
    var it = std.mem.splitSequence(u8, block, "\r\n");
    while (it.next()) |line| {
        if (line.len < name.len + 1) continue;
        if (std.ascii.eqlIgnoreCase(line[0..name.len], name) and line[name.len] == ':') return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "a written request is split into the pieces a browser needs" {
    const raw = "POST /api/sites?page=2 HTTP/1.1\r\nhost: example.com\r\ncontent-type: application/json\r\n\r\n{\"a\":1}";
    const p = parseRequest(raw) orelse return error.NotParsed;
    try std.testing.expectEqualStrings("POST", p.method);
    // The query rides along with the path: it is part of the target and the
    // browser needs it.
    try std.testing.expectEqualStrings("/api/sites?page=2", p.target);
    try std.testing.expectEqualStrings("host: example.com\r\ncontent-type: application/json", p.headers);
    try std.testing.expectEqualStrings("{\"a\":1}", p.body);
}

test "a request with no body and no headers still parses" {
    const p = parseRequest("GET / HTTP/1.1\r\n\r\n") orelse return error.NotParsed;
    try std.testing.expectEqualStrings("GET", p.method);
    try std.testing.expectEqualStrings("/", p.target);
    try std.testing.expectEqualStrings("", p.headers);
    try std.testing.expectEqualStrings("", p.body);
}

test "an unfinished request is refused rather than half read" {
    // The headers have not ended yet. Sending this would send a torn request.
    try std.testing.expect(parseRequest("GET / HTTP/1.1\r\nhost: example.com\r\n") == null);
    try std.testing.expect(parseRequest("") == null);
}

test "a request for the page's own host is handed over bare, for the browser to resolve" {
    const gpa = std.testing.allocator;
    // The whole point of the rule. The application had to ask for http, because
    // its socket cannot do TLS, and the request still leaves over the page's real
    // scheme and port with the page's cookies on it, because the browser resolves
    // this against the page instead of against a guess made here.
    const url = try requestUrl(gpa, "sigil.example", .{
        .method = "GET",
        .host = "sigil.example",
        .port = 80,
        .target = "/api/sites",
        .headers = "",
        .body = "",
    });
    defer gpa.free(url);
    try std.testing.expectEqualStrings("/api/sites", url);
}

test "a default port is left out of the url, because a port changes the origin a cookie is sent to" {
    const gpa = std.testing.allocator;
    const url = try requestUrl(gpa, "sigil.example", .{
        .method = "GET",
        .host = "other.example",
        .port = 443,
        .target = "/x",
        .headers = "",
        .body = "",
    });
    defer gpa.free(url);
    try std.testing.expectEqualStrings("https://other.example/x", url);

    const odd = try requestUrl(gpa, "sigil.example", .{
        .method = "GET",
        .host = "other.example",
        .port = 8080,
        .target = "/x",
        .headers = "",
        .body = "",
    });
    defer gpa.free(odd);
    try std.testing.expectEqualStrings("http://other.example:8080/x", odd);
}

test "a response is rebuilt with a content length when the browser did not give one" {
    const gpa = std.testing.allocator;
    const res = try buildResponse(gpa, 200, "content-type: application/json\r\n", "{}");
    defer gpa.free(res);
    try std.testing.expectEqualStrings(
        "HTTP/1.1 200 \r\ncontent-type: application/json\r\ncontent-length: 2\r\nconnection: close\r\n\r\n{}",
        res,
    );
}

test "a content length the browser did give is not repeated" {
    const gpa = std.testing.allocator;
    // Two content-length headers is a message a strict parser rejects outright,
    // and matching must ignore case because a browser lower-cases them.
    const res = try buildResponse(gpa, 204, "Content-Length: 0\r\n", "");
    defer gpa.free(res);
    try std.testing.expectEqualStrings("HTTP/1.1 204 \r\nContent-Length: 0\r\nconnection: close\r\n\r\n", res);
}

test "a header block with no trailing separator still ends before the body" {
    const gpa = std.testing.allocator;
    const res = try buildResponse(gpa, 403, "content-type: text/plain", "no");
    defer gpa.free(res);
    try std.testing.expectEqualStrings(
        "HTTP/1.1 403 \r\ncontent-type: text/plain\r\ncontent-length: 2\r\nconnection: close\r\n\r\nno",
        res,
    );
}

test "hasHeader matches a whole name at the start of a line and nothing else" {
    try std.testing.expect(hasHeader("content-length: 3\r\n", "content-length"));
    try std.testing.expect(hasHeader("a: 1\r\nCONTENT-LENGTH: 3\r\n", "content-length"));
    // A name that only appears inside a value is not that header.
    try std.testing.expect(!hasHeader("x-echo: content-length: 3\r\n", "content-length"));
    // A longer name that starts the same way is a different header.
    try std.testing.expect(!hasHeader("content-length-hint: 3\r\n", "content-length"));
    try std.testing.expect(!hasHeader("", "content-length"));
}

// -- the connection table ---------------------------------------------------

const Spy = struct {
    seen: Request = undefined,
    calls: u32 = 0,
    answer: ?[]const u8 = null,

    fn send(ctx: *anyopaque, gpa: Allocator, req: Request) ?[]u8 {
        const self: *Spy = @ptrCast(@alignCast(ctx));
        self.seen = req;
        self.calls += 1;
        const a = self.answer orelse return null;
        return gpa.dupe(u8, a) catch null;
    }

    fn hook(self: *Spy) Hook {
        return .{ .ctx = self, .send = Spy.send };
    }
};

test "the request is sent on the first read, not on a write" {
    const gpa = std.testing.allocator;
    var spy = Spy{ .answer = "HTTP/1.1 200 \r\ncontent-length: 2\r\n\r\nhi" };
    var net = Net{ .gpa = gpa, .hook = spy.hook() };
    defer net.deinit();
    const slot = net.open("example.com", 80) orelse return error.NoSlot;

    // A request written in pieces, which is what a buffered writer does. Sending
    // on any of these would send a torn request.
    _ = try net.write(slot, "GET /a HTTP/1.1\r\n");
    _ = try net.write(slot, "host: example.com\r\n\r\n");
    try std.testing.expectEqual(@as(u32, 0), spy.calls);

    var buf: [64]u8 = undefined;
    const n = try net.read(slot, &buf);
    try std.testing.expectEqual(@as(u32, 1), spy.calls);
    try std.testing.expectEqualStrings("GET", spy.seen.method);
    try std.testing.expectEqualStrings("/a", spy.seen.target);
    try std.testing.expectEqualStrings("example.com", spy.seen.host);
    try std.testing.expectEqualStrings("HTTP/1.1 200 \r\ncontent-length: 2\r\n\r\nhi", buf[0..n]);

    // The end of the response reads as a close, and reading again does not send
    // the request a second time.
    try std.testing.expectEqual(@as(usize, 0), try net.read(slot, &buf));
    try std.testing.expectEqual(@as(u32, 1), spy.calls);
}

test "a response longer than the read buffer is served in pieces" {
    const gpa = std.testing.allocator;
    var spy = Spy{ .answer = "HTTP/1.1 200 \r\n\r\nabcdefghij" };
    var net = Net{ .gpa = gpa, .hook = spy.hook() };
    defer net.deinit();
    const slot = net.open("example.com", 80) orelse return error.NoSlot;
    _ = try net.write(slot, "GET / HTTP/1.1\r\n\r\n");

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var buf: [4]u8 = undefined;
    while (true) {
        const n = try net.read(slot, &buf);
        if (n == 0) break;
        try out.appendSlice(gpa, buf[0..n]);
    }
    try std.testing.expectEqualStrings("HTTP/1.1 200 \r\n\r\nabcdefghij", out.items);
}

test "a request that never arrives is an error, not an empty response" {
    const gpa = std.testing.allocator;
    // The difference that matters to a dashboard: "the server said no" and "the
    // network is down" send a person to two different places. An empty stream
    // would read as a clean close and become a parse error about a short reply.
    var spy = Spy{ .answer = null };
    var net = Net{ .gpa = gpa, .hook = spy.hook() };
    defer net.deinit();
    const slot = net.open("example.com", 80) orelse return error.NoSlot;
    _ = try net.write(slot, "GET / HTTP/1.1\r\n\r\n");

    var buf: [16]u8 = undefined;
    try std.testing.expectError(error.NetworkDown, net.read(slot, &buf));
    // Still an error on the next read, and still only one attempt.
    try std.testing.expectError(error.NetworkDown, net.read(slot, &buf));
    try std.testing.expectEqual(@as(u32, 1), spy.calls);
}

test "a closed slot is reused, and a full table refuses instead of growing" {
    const gpa = std.testing.allocator;
    var net = Net{ .gpa = gpa };
    defer net.deinit();

    var slots: [max_conns]usize = undefined;
    for (&slots) |*s| s.* = net.open("example.com", 80) orelse return error.NoSlot;
    try std.testing.expect(net.open("example.com", 80) == null);

    net.close(slots[3]);
    const reused = net.open("other.example", 443) orelse return error.NoSlot;
    try std.testing.expectEqual(slots[3], reused);
    // The reused slot is the new connection's, not a leftover of the old one.
    try std.testing.expectEqualStrings("other.example", net.conns[reused].host());
    try std.testing.expectEqual(@as(u16, 443), net.conns[reused].port);
}

test "an over long host name is refused rather than truncated to a different machine" {
    const gpa = std.testing.allocator;
    var net = Net{ .gpa = gpa };
    defer net.deinit();
    const long = "a" ** (max_host + 1);
    try std.testing.expect(net.open(long, 443) == null);
}

test "writing to a slot that was never opened is an error, not a silent success" {
    const gpa = std.testing.allocator;
    var net = Net{ .gpa = gpa };
    defer net.deinit();
    try std.testing.expectError(error.SocketUnconnected, net.write(0, "GET / HTTP/1.1\r\n\r\n"));
    var buf: [8]u8 = undefined;
    try std.testing.expectError(error.SocketUnconnected, net.read(max_conns + 5, &buf));
}

test "a hook that was never wired reports the network down instead of hanging" {
    const gpa = std.testing.allocator;
    var net = Net{ .gpa = gpa, .hook = null };
    defer net.deinit();
    const slot = net.open("example.com", 80) orelse return error.NoSlot;
    _ = try net.write(slot, "GET / HTTP/1.1\r\n\r\n");
    var buf: [8]u8 = undefined;
    try std.testing.expectError(error.NetworkDown, net.read(slot, &buf));
}

test "a rebuilt response closes the connection, because one connection is one fetch" {
    const gpa = std.testing.allocator;
    // Without this the client keeps the connection alive and reuses it, writing
    // its next request onto a buffer that was already sent and reading nothing
    // back. That is the ordinary two-requests case, not an edge.
    const res = try buildResponse(gpa, 200, "content-type: text/plain\r\n", "hi");
    defer gpa.free(res);
    try std.testing.expect(std.mem.indexOf(u8, res, "connection: close\r\n") != null);

    // A server that said something about the connection itself keeps its word.
    const keep = try buildResponse(gpa, 200, "Connection: keep-alive\r\n", "");
    defer gpa.free(keep);
    try std.testing.expect(std.mem.indexOf(u8, keep, "connection: close") == null);
}

test "a different port on the page's own host is a different origin, not the page" {
    const gpa = std.testing.allocator;
    // The hole this closes: handed over as a bare target, this would have gone
    // to the page's own origin carrying the page's cookies, while the caller
    // believed it was talking to another service on the same machine.
    const other = try requestUrl(gpa, "localhost", .{
        .method = "GET",
        .host = "localhost",
        .port = 9,
        .target = "/admin",
        .headers = "",
        .body = "",
    });
    defer gpa.free(other);
    try std.testing.expectEqualStrings("http://localhost:9/admin", other);

    // The rule's own case still resolves against the page.
    const own = try requestUrl(gpa, "localhost", .{
        .method = "GET",
        .host = "localhost",
        .port = 80,
        .target = "/api",
        .headers = "",
        .body = "",
    });
    defer gpa.free(own);
    try std.testing.expectEqualStrings("/api", own);
}
