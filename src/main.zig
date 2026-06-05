//! cj — .cc 工具定义 DSL ↔ OpenAI 兼容 JSON。
//!
//! .cc 是一种缩进驱动的简洁 DSL，专为手写 OpenAI Chat Completions 请求体
//! （含 tools / function / JSON Schema 子结构）而设计。
//!
//! 语法要点：
//!   - 字段后缀 `+` 或 `*` 标记一个数组（数组项从下一行更深缩进开始）
//!   - 数组中对象项之间用 `,` 单独成行分隔（也允许省略，靠同缩进自动识别新项）
//!   - 字段后跟同行的非空内容 = 标量值
//!   - 字段后无值、下行有更深缩进 = 该字段的值是一个嵌套对象
//!   - 标量类型自动推导：int / float / bool / null / 其它为字符串
//!   - 数组项是标量还是对象自动推断：
//!     * 当前行有值（`name value`）→ 对象
//!     * 当前行无值、下行更深缩进 → 对象（值为嵌套对象）
//!     * 当前行无值、下行同级 → 标量（user 可用 `,` 强制对象、用 `"..."` 强制 string）
//!   - 双引号字符串支持转义：`\"` `\\` `\n` `\t` `\r` `\/` `\b` `\f`
//!   - 整行注释：`#` 开头（trim 缩进后）
//!
//! 用法：
//!   cj [options] [<input>]
//!
//! 选项：
//!   -p, --pretty    缩进美化输出（默认紧凑单行）
//!   -h, --help      显示帮助
//!
//! 不传文件名时从 stdin 读取。

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayListUnmanaged;
const StringHashMap = std.StringHashMapUnmanaged;
const Io = std.Io;

const Value = union(enum) {
    null_v,
    bool_v: bool,
    int_v: i64,
    float_v: f64,
    string_v: []const u8, // 借用 input 切片，零拷贝
    string_alloc_v: []u8, // 含转义，分配并拥有
    array_v: ArrayList(Value),
    object_v: StringHashMap(Value),

    fn deinit(self: *Value, allocator: Allocator) void {
        switch (self.*) {
            .string_alloc_v => |s| allocator.free(s),
            .array_v => |*a| {
                for (a.items) |*item| item.deinit(allocator);
                a.deinit(allocator);
            },
            .object_v => |*o| {
                var it = o.iterator();
                while (it.next()) |kv| {
                    // 键是 input 的切片视图，不单独 free
                    kv.value_ptr.deinit(allocator);
                }
                o.deinit(allocator);
            },
            else => {},
        }
    }
};

const Item = struct {
    line: usize, // 1-based
    indent: usize,
    body: []const u8,
};

const ParseError = error{ UnexpectedIndent, OutOfMemory, NoClosingTripleQuote };

const HelpText =
    \\cj — convert between .cc tools DSL and OpenAI-compatible JSON
    \\
    \\Usage:
    \\  cj [options] [<input>]
    \\
    \\Options:
    \\  -p, --pretty    pretty-print JSON output (default: compact)
    \\  -d, --decode    decode mode: read JSON, output .cc (default: read .cc, output JSON)
    \\  -h, --help      show this help
    \\
    \\Reads from stdin if no input file is given. The format is auto-detected
    \\by the first non-whitespace byte ({/[ = JSON, anything else = .cc),
    \\or controlled by -d.
    \\
;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    var args_iter = try init.minimal.args.iterateAllocator(allocator);
    defer args_iter.deinit();
    _ = args_iter.skip();

    var pretty = false;
    var decode: ?bool = null;
    var input_path: ?[]const u8 = null;
    while (args_iter.next()) |arg_z| {
        const a: []const u8 = arg_z[0..arg_z.len];
        if (mem.eql(u8, a, "-h") or mem.eql(u8, a, "--help")) {
            var out_buf: [4096]u8 = undefined;
            var fw = Io.File.stdout().writer(io, &out_buf);
            try fw.interface.writeAll(HelpText);
            try fw.flush();
            return;
        } else if (mem.eql(u8, a, "-p") or mem.eql(u8, a, "--pretty")) {
            pretty = true;
        } else if (mem.eql(u8, a, "-d") or mem.eql(u8, a, "--decode")) {
            decode = true;
        } else if (mem.eql(u8, a, "-e") or mem.eql(u8, a, "--encode")) {
            decode = false;
        } else {
            input_path = a;
        }
    }

    var in_buf: [4096]u8 = undefined;
    var input: []u8 = undefined;
    if (input_path) |p| {
        const file = try Io.Dir.cwd().openFile(io, p, .{});
        defer file.close(io);
        var reader = file.reader(io, &in_buf);
        input = try reader.interface.allocRemaining(allocator, .unlimited);
    } else {
        // stdin 是 console/pipe，用 streaming 而非 positional
        var reader = Io.File.stdin().readerStreaming(io, &in_buf);
        input = try reader.interface.allocRemaining(allocator, .unlimited);
    }
    defer allocator.free(input);

    // 自动检测：未显式 -d/-e 时看首字符
    const is_decode = decode orelse isJsonInput(input);

    if (is_decode) {
        var value = parseJson(allocator, input) catch |err| {
            std.debug.print("cj: JSON parse error: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        defer value.deinit(allocator);

        var out: ArrayList(u8) = .empty;
        defer out.deinit(allocator);
        try appendCC(allocator, &out, value, 0);

        var out_buf: [4096]u8 = undefined;
        var fw = Io.File.stdout().writer(io, &out_buf);
        try fw.interface.writeAll(out.items);
        try fw.flush();
        return;
    }

    var value = parseCC(allocator, input) catch |err| {
        std.debug.print("cj: parse error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer value.deinit(allocator);

    var out: ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    if (pretty) {
        try appendPrettyJson(allocator, &out, value, 0);
    } else {
        try appendCompactJson(allocator, &out, value);
    }

    var out_buf: [4096]u8 = undefined;
    var fw = Io.File.stdout().writer(io, &out_buf);
    try fw.interface.writeAll(out.items);
    try fw.interface.writeAll("\n");
    try fw.flush();
}

/// 看首非空白字符：`{` 或 `[` → JSON；其它 → .cc
fn isJsonInput(input: []const u8) bool {
    for (input) |c| {
        switch (c) {
            ' ', '\t', '\n', '\r' => continue,
            '{', '[' => return true,
            else => return false,
        }
    }
    return false;
}

// ─── Tokenizer ─────────────────────────────────────────────────────────

fn tokenize(allocator: Allocator, input: []const u8) ![]Item {
    var items: ArrayList(Item) = .empty;
    errdefer items.deinit(allocator);

    var line_no: usize = 1;
    var line_iter = mem.splitScalar(u8, input, '\n');
    while (line_iter.next()) |raw| {
        defer line_no += 1;

        var indent: usize = 0;
        var start: usize = 0;
        while (start < raw.len and (raw[start] == ' ' or raw[start] == '\t')) {
            indent += 1;
            start += 1;
        }
        var end: usize = raw.len;
        while (end > start) {
            const c = raw[end - 1];
            if (c == ' ' or c == '\t' or c == '\r') {
                end -= 1;
            } else break;
        }
        if (end == start) continue;

        const body = raw[start..end];
        // 整行注释（trim 缩进后以 # 开头）
        if (body[0] == '#') continue;

        try items.append(allocator, .{ .line = line_no, .indent = indent, .body = body });
    }

    return items.toOwnedSlice(allocator);
}

// ─── Parser ────────────────────────────────────────────────────────────

fn parseCC(allocator: Allocator, input: []const u8) ParseError!Value {
    const items = try tokenize(allocator, input);
    defer allocator.free(items);

    if (items.len == 0) {
        return Value{ .object_v = .empty };
    }
    if (items[0].indent != 0) {
        std.debug.print("cj: line {}: first line must have no indent\n", .{items[0].line});
        return error.UnexpectedIndent;
    }

    var ctx = ParseCtx{ .allocator = allocator, .items = items };
    const result = try parseObject(&ctx, 0, 0);
    return result.value;
}

const ParseCtx = struct {
    allocator: Allocator,
    items: []const Item,
};

const ParseResult = struct {
    value: Value,
    next_idx: usize,
};

const ItemKind = enum { scalar, object };

fn firstWhitespace(s: []const u8) ?usize {
    for (s, 0..) |c, i| {
        if (c == ' ' or c == '\t') return i;
    }
    return null;
}

fn parseObject(ctx: *ParseCtx, start: usize, indent: usize) ParseError!ParseResult {
    var map: StringHashMap(Value) = .empty;
    errdefer {
        var it = map.iterator();
        while (it.next()) |kv| kv.value_ptr.deinit(ctx.allocator);
        map.deinit(ctx.allocator);
    }

    var i: usize = start;
    while (i < ctx.items.len) {
        const item = ctx.items[i];
        if (item.indent < indent) break;
        if (item.indent > indent) {
            std.debug.print("cj: line {}: unexpected indent (expected <= {})\n", .{ item.line, indent });
            return error.UnexpectedIndent;
        }

        if (mem.eql(u8, item.body, ",")) {
            // 数组里对象项之间的分隔符；遇 `,` 即结束当前对象
            break;
        }

        const fe = firstWhitespace(item.body);
        const head = if (fe) |e| item.body[0..e] else item.body;
        const rest = if (fe) |e| mem.trim(u8, item.body[e..], " \t") else "";

        const suffix: u8 = blk: {
            if (head.len == 0) break :blk 0;
            const last = head[head.len - 1];
            if (last == '+' or last == '*') break :blk last;
            break :blk 0;
        };

        const name_slice = if (suffix != 0) head[0 .. head.len - 1] else head;
        const name = mem.trim(u8, name_slice, " \t");

        i += 1;

        if (suffix == '+' or suffix == '*') {
            if (i >= ctx.items.len or ctx.items[i].indent <= indent) {
                try map.put(ctx.allocator, name, .{ .array_v = .empty });
            } else {
                const item_indent = ctx.items[i].indent;
                const arr = try parseArray(ctx, i, item_indent);
                try map.put(ctx.allocator, name, arr.value);
                i = arr.next_idx;
            }
        } else if (mem.eql(u8, rest, "\"\"\"")) {
            // 多行字符串（heredoc）：
            //   field """
            //       line 1
            //       line 2
            //       """
            // 找下一个 body == `"""` 的行作为结束，按首行 indent 剥离
            const ml = try parseMultilineString(ctx, i);
            try map.put(ctx.allocator, name, .{ .string_alloc_v = ml.content });
            i = ml.end_i;
        } else if (i < ctx.items.len and ctx.items[i].indent > indent) {
            const nested_indent = ctx.items[i].indent;
            const obj = try parseObject(ctx, i, nested_indent);
            try map.put(ctx.allocator, name, obj.value);
            i = obj.next_idx;
        } else if (rest.len > 0) {
            try map.put(ctx.allocator, name, try parseScalar(ctx.allocator, rest));
        } else {
            try map.put(ctx.allocator, name, .{ .string_v = "" });
        }
    }

    return ParseResult{ .value = .{ .object_v = map }, .next_idx = i };
}

fn parseArray(ctx: *ParseCtx, start: usize, item_indent: usize) ParseError!ParseResult {
    var arr: ArrayList(Value) = .empty;
    errdefer {
        for (arr.items) |*item| item.deinit(ctx.allocator);
        arr.deinit(ctx.allocator);
    }

    var i: usize = start;
    while (i < ctx.items.len) {
        const item = ctx.items[i];
        if (item.indent < item_indent) break;
        if (item.indent > item_indent) {
            std.debug.print("cj: line {}: unexpected indent in array (expected <= {})\n", .{ item.line, item_indent });
            return error.UnexpectedIndent;
        }

        if (mem.eql(u8, item.body, ",")) {
            i += 1;
            continue;
        }

        const kind = peekItemKind(ctx, i, item_indent);
        switch (kind) {
            .scalar => {
                try arr.append(ctx.allocator, try parseScalar(ctx.allocator, item.body));
                i += 1;
            },
            .object => {
                const obj = try parseObject(ctx, i, item_indent);
                try arr.append(ctx.allocator, obj.value);
                i = obj.next_idx;
            },
        }
    }

    return ParseResult{ .value = .{ .array_v = arr }, .next_idx = i };
}

/// 数组项的"标量 vs 对象"启发式：
///   - 当前行有值（`name value`） → 对象
///   - 当前行无值、下行更深缩进 → 对象（值为嵌套对象）
///   - 当前行无值、下行同级 → 标量（user 可用 `,` 强制对象、用 `"..."` 强制 string）
fn peekItemKind(ctx: *ParseCtx, i: usize, item_indent: usize) ItemKind {
    const cur = ctx.items[i];
    if (firstWhitespace(cur.body) != null) return .object;

    var j: usize = i + 1;
    while (j < ctx.items.len) {
        const nxt = ctx.items[j];
        if (nxt.indent < item_indent) break;
        if (nxt.indent == item_indent) {
            if (mem.eql(u8, nxt.body, ",")) {
                j += 1;
                continue;
            }
            return .scalar;
        }
        return .object;
    }
    return .scalar;
}

fn parseScalar(allocator: Allocator, s: []const u8) ParseError!Value {
    const trimmed = mem.trim(u8, s, " \t\r");
    if (trimmed.len == 0) return .{ .string_v = "" };

    if (trimmed.len >= 2 and trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') {
        const inner = trimmed[1 .. trimmed.len - 1];
        return try unescapeString(allocator, inner);
    }

    if (std.fmt.parseInt(i64, trimmed, 10)) |n| {
        return .{ .int_v = n };
    } else |_| {}

    if (std.fmt.parseFloat(f64, trimmed)) |f| {
        return .{ .float_v = f };
    } else |_| {}

    if (mem.eql(u8, trimmed, "true")) return .{ .bool_v = true };
    if (mem.eql(u8, trimmed, "false")) return .{ .bool_v = false };

    if (mem.eql(u8, trimmed, "null") or mem.eql(u8, trimmed, "none") or
        mem.eql(u8, trimmed, "~"))
    {
        return .{ .null_v = {} };
    }

    return .{ .string_v = trimmed };
}

/// 多行字符串（`"""` ... `"""`）：
/// 收集从 `start` 开始的所有行直到下一个 body == `"""` 的行；
/// 按首行 indent 剥离前导空白；行间用 `\n` 拼接。
/// 不解析转义——多行形式是给"人类可读"用的，转义交给单行 `"..."` 形式。
fn parseMultilineString(ctx: *ParseCtx, start: usize) ParseError!struct { content: []u8, end_i: usize } {
    var content: ArrayList(u8) = .empty;
    errdefer content.deinit(ctx.allocator);

    if (start >= ctx.items.len) return error.NoClosingTripleQuote;

    // 立刻就是结束 → 空字符串
    if (mem.eql(u8, mem.trim(u8, ctx.items[start].body, " \t"), "\"\"\"")) {
        return .{ .content = try content.toOwnedSlice(ctx.allocator), .end_i = start + 1 };
    }

    const base_indent = ctx.items[start].indent;
    var i: usize = start;
    while (i < ctx.items.len) {
        const item = ctx.items[i];
        if (mem.eql(u8, mem.trim(u8, item.body, " \t"), "\"\"\"")) {
            return .{ .content = try content.toOwnedSlice(ctx.allocator), .end_i = i + 1 };
        }
        // tokenize 已经把 base_indent 之前的缩进剥了；
        // item.indent - base_indent 的"额外缩进"用空格补回来
        const extra: usize = if (item.indent > base_indent) item.indent - base_indent else 0;
        if (content.items.len > 0) try content.append(ctx.allocator, '\n');
        for (0..extra) |_| try content.append(ctx.allocator, ' ');
        try content.appendSlice(ctx.allocator, item.body);
        i += 1;
    }
    return error.NoClosingTripleQuote;
}

/// 把双引号内的字面量转义还原。无转义时零拷贝返回借用切片。
fn unescapeString(allocator: Allocator, raw: []const u8) Allocator.Error!Value {
    var has_escape = false;
    for (raw) |c| {
        if (c == '\\') {
            has_escape = true;
            break;
        }
    }
    if (!has_escape) return .{ .string_v = raw };

    var buf: ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var i: usize = 0;
    while (i < raw.len) {
        const c = raw[i];
        if (c == '\\' and i + 1 < raw.len) {
            const next = raw[i + 1];
            switch (next) {
                '"' => try buf.append(allocator, '"'),
                '\\' => try buf.append(allocator, '\\'),
                'n' => try buf.append(allocator, '\n'),
                't' => try buf.append(allocator, '\t'),
                'r' => try buf.append(allocator, '\r'),
                '/' => try buf.append(allocator, '/'),
                'b' => try buf.append(allocator, 0x08),
                'f' => try buf.append(allocator, 0x0c),
                else => try buf.append(allocator, next), // 未知转义：保留字面量
            }
            i += 2;
        } else {
            try buf.append(allocator, c);
            i += 1;
        }
    }
    return .{ .string_alloc_v = try buf.toOwnedSlice(allocator) };
}

// ─── JSON 输出 ─────────────────────────────────────────────────────────

fn appendCompactJson(allocator: Allocator, buf: *ArrayList(u8), value: Value) !void {
    switch (value) {
        .null_v => try buf.appendSlice(allocator, "null"),
        .bool_v => |b| try buf.appendSlice(allocator, if (b) "true" else "false"),
        .int_v => |n| {
            var tmp: [32]u8 = undefined;
            const s = try std.fmt.bufPrint(&tmp, "{d}", .{n});
            try buf.appendSlice(allocator, s);
        },
        .float_v => |f| {
            var tmp: [64]u8 = undefined;
            const s = try std.fmt.bufPrint(&tmp, "{d}", .{f});
            try buf.appendSlice(allocator, s);
        },
        .string_v, .string_alloc_v => |s| try appendJsonString(allocator, buf, s),
        .array_v => |a| {
            try buf.append(allocator, '[');
            for (a.items, 0..) |item, idx| {
                if (idx > 0) try buf.append(allocator, ',');
                try appendCompactJson(allocator, buf, item);
            }
            try buf.append(allocator, ']');
        },
        .object_v => |o| {
            try buf.append(allocator, '{');
            var it = o.iterator();
            var first = true;
            while (it.next()) |kv| {
                if (!first) try buf.append(allocator, ',');
                first = false;
                try appendJsonString(allocator, buf, kv.key_ptr.*);
                try buf.append(allocator, ':');
                try appendCompactJson(allocator, buf, kv.value_ptr.*);
            }
            try buf.append(allocator, '}');
        },
    }
}

fn appendPrettyJson(allocator: Allocator, buf: *ArrayList(u8), value: Value, depth: usize) !void {
    switch (value) {
        .null_v => try buf.appendSlice(allocator, "null"),
        .bool_v => |b| try buf.appendSlice(allocator, if (b) "true" else "false"),
        .int_v => |n| {
            var tmp: [32]u8 = undefined;
            const s = try std.fmt.bufPrint(&tmp, "{d}", .{n});
            try buf.appendSlice(allocator, s);
        },
        .float_v => |f| {
            var tmp: [64]u8 = undefined;
            const s = try std.fmt.bufPrint(&tmp, "{d}", .{f});
            try buf.appendSlice(allocator, s);
        },
        .string_v, .string_alloc_v => |s| try appendJsonString(allocator, buf, s),
        .array_v => |a| {
            if (a.items.len == 0) {
                try buf.appendSlice(allocator, "[]");
                return;
            }
            try buf.append(allocator, '[');
            try buf.append(allocator, '\n');
            for (a.items, 0..) |item, idx| {
                try appendIndent(allocator, buf, depth + 1);
                try appendPrettyJson(allocator, buf, item, depth + 1);
                if (idx + 1 < a.items.len) try buf.append(allocator, ',');
                try buf.append(allocator, '\n');
            }
            try appendIndent(allocator, buf, depth);
            try buf.append(allocator, ']');
        },
        .object_v => |o| {
            if (o.count() == 0) {
                try buf.appendSlice(allocator, "{}");
                return;
            }
            try buf.append(allocator, '{');
            try buf.append(allocator, '\n');
            var it = o.iterator();
            var first = true;
            while (it.next()) |kv| {
                if (!first) {
                    try buf.append(allocator, ',');
                    try buf.append(allocator, '\n');
                }
                first = false;
                try appendIndent(allocator, buf, depth + 1);
                try appendJsonString(allocator, buf, kv.key_ptr.*);
                try buf.appendSlice(allocator, ": ");
                try appendPrettyJson(allocator, buf, kv.value_ptr.*, depth + 1);
            }
            try buf.append(allocator, '\n');
            try appendIndent(allocator, buf, depth);
            try buf.append(allocator, '}');
        },
    }
}

fn appendIndent(allocator: Allocator, buf: *ArrayList(u8), depth: usize) !void {
    var i: usize = 0;
    while (i < depth) : (i += 1) {
        try buf.appendSlice(allocator, "  ");
    }
}

fn appendJsonString(allocator: Allocator, buf: *ArrayList(u8), s: []const u8) !void {
    try buf.append(allocator, '"');
    for (s) |c| {
        if (c == '"') {
            try buf.appendSlice(allocator, "\\\"");
        } else if (c == '\\') {
            try buf.appendSlice(allocator, "\\\\");
        } else if (c == '\n') {
            try buf.appendSlice(allocator, "\\n");
        } else if (c == '\r') {
            try buf.appendSlice(allocator, "\\r");
        } else if (c == '\t') {
            try buf.appendSlice(allocator, "\\t");
        } else if (c < 0x20) {
            var tmp: [8]u8 = undefined;
            const esc = try std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{c});
            try buf.appendSlice(allocator, esc);
        } else {
            try buf.append(allocator, c);
        }
    }
    try buf.append(allocator, '"');
}

// ─── JSON 解析（用于 -d 模式：JSON → .cc）─────────────────────────────────

const JsonError = error{
    UnexpectedEof,
    UnexpectedChar,
    UnterminatedString,
    InvalidEscape,
    InvalidUnicode,
    InvalidNumber,
    ExpectedColon,
    ExpectedKey,
    ExpectedComma,
    TrailingContent,
} || Allocator.Error;

const JsonParser = struct {
    input: []const u8,
    pos: usize,
};

fn parseJson(allocator: Allocator, input: []const u8) JsonError!Value {
    var parser: JsonParser = .{ .input = input, .pos = 0 };
    const value = try parseJsonValue(allocator, &parser);
    skipJsonWhitespace(&parser);
    if (parser.pos < parser.input.len) return error.TrailingContent;
    return value;
}

fn parseJsonValue(allocator: Allocator, p: *JsonParser) JsonError!Value {
    skipJsonWhitespace(p);
    if (p.pos >= p.input.len) return error.UnexpectedEof;
    return switch (p.input[p.pos]) {
        '{' => parseJsonObject(allocator, p),
        '[' => parseJsonArray(allocator, p),
        '"' => try parseJsonString(allocator, p),
        't', 'f' => parseJsonBool(p),
        'n' => parseJsonNull(p),
        '-', '0'...'9' => parseJsonNumber(p),
        else => error.UnexpectedChar,
    };
}

fn skipJsonWhitespace(p: *JsonParser) void {
    while (p.pos < p.input.len) {
        switch (p.input[p.pos]) {
            ' ', '\t', '\n', '\r' => p.pos += 1,
            else => return,
        }
    }
}

fn parseJsonObject(allocator: Allocator, p: *JsonParser) JsonError!Value {
    p.pos += 1; // 消费 '{'
    var map: StringHashMap(Value) = .empty;
    errdefer {
        var it = map.iterator();
        while (it.next()) |kv| kv.value_ptr.deinit(allocator);
        map.deinit(allocator);
    }

    skipJsonWhitespace(p);
    if (p.pos < p.input.len and p.input[p.pos] == '}') {
        p.pos += 1;
        return .{ .object_v = map };
    }

    while (true) {
        skipJsonWhitespace(p);
        if (p.pos >= p.input.len or p.input[p.pos] != '"') return error.ExpectedKey;
        // key 是 Value（string_v 借用 input 或 string_alloc_v 分配）。
        // ⚠️ 已知限制：若 key 来自 string_alloc_v，map 的 key 持有指向
        // 该 buffer 的 slice，key_value 离开作用域时 buffer 被释放，key
        // 变 dangling。实际使用中 key 通常是简单标识符（无转义）→ 借用 input。
        var key_value = try parseJsonString(allocator, p);
        errdefer key_value.deinit(allocator);
        const key = switch (key_value) {
            .string_v => |s| s,
            .string_alloc_v => |s| s,
            else => unreachable,
        };
        skipJsonWhitespace(p);
        if (p.pos >= p.input.len or p.input[p.pos] != ':') return error.ExpectedColon;
        p.pos += 1;
        const value = try parseJsonValue(allocator, p);
        try map.put(allocator, key, value);

        skipJsonWhitespace(p);
        if (p.pos < p.input.len and p.input[p.pos] == ',') {
            p.pos += 1;
            continue;
        }
        if (p.pos < p.input.len and p.input[p.pos] == '}') {
            p.pos += 1;
            return .{ .object_v = map };
        }
        return error.ExpectedComma;
    }
}

fn parseJsonArray(allocator: Allocator, p: *JsonParser) JsonError!Value {
    p.pos += 1; // 消费 '['
    var arr: ArrayList(Value) = .empty;
    errdefer {
        for (arr.items) |*item| item.deinit(allocator);
        arr.deinit(allocator);
    }

    skipJsonWhitespace(p);
    if (p.pos < p.input.len and p.input[p.pos] == ']') {
        p.pos += 1;
        return .{ .array_v = arr };
    }

    while (true) {
        const value = try parseJsonValue(allocator, p);
        try arr.append(allocator, value);

        skipJsonWhitespace(p);
        if (p.pos < p.input.len and p.input[p.pos] == ',') {
            p.pos += 1;
            continue;
        }
        if (p.pos < p.input.len and p.input[p.pos] == ']') {
            p.pos += 1;
            return .{ .array_v = arr };
        }
        return error.ExpectedComma;
    }
}

/// 解析 JSON 字符串字面量为 Value：无转义 → string_v（借用 input），
/// 有转义 → string_alloc_v（分配并解转义，deinit 释放）。
fn parseJsonString(allocator: Allocator, p: *JsonParser) JsonError!Value {
    if (p.pos >= p.input.len or p.input[p.pos] != '"') return error.UnexpectedChar;
    p.pos += 1;

    const start = p.pos;
    while (p.pos < p.input.len and p.input[p.pos] != '"') {
        if (p.input[p.pos] == '\\') {
            p.pos += 1;
            if (p.pos >= p.input.len) return error.UnterminatedString;
            if (p.input[p.pos] == 'u') {
                p.pos += 1;
                if (p.pos + 4 > p.input.len) return error.InvalidEscape;
                p.pos += 4;
            } else {
                p.pos += 1;
            }
        } else {
            p.pos += 1;
        }
    }
    if (p.pos >= p.input.len) return error.UnterminatedString;
    const end = p.pos;
    p.pos += 1; // 消费 '"'

    // 快路径：无转义 → 借用
    var has_escape = false;
    for (p.input[start..end]) |c| {
        if (c == '\\') {
            has_escape = true;
            break;
        }
    }
    if (!has_escape) return .{ .string_v = p.input[start..end] };

    // 慢路径：分配并解转义
    var buf: ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var i: usize = start;
    while (i < end) {
        const c = p.input[i];
        if (c == '\\' and i + 1 < end) {
            const next = p.input[i + 1];
            switch (next) {
                '"' => try buf.append(allocator, '"'),
                '\\' => try buf.append(allocator, '\\'),
                '/' => try buf.append(allocator, '/'),
                'n' => try buf.append(allocator, '\n'),
                't' => try buf.append(allocator, '\t'),
                'r' => try buf.append(allocator, '\r'),
                'b' => try buf.append(allocator, 0x08),
                'f' => try buf.append(allocator, 0x0c),
                'u' => {
                    if (i + 6 > end) return error.InvalidEscape;
                    const hex_slice = p.input[i + 2 .. i + 6];
                    const cp = std.fmt.parseInt(u21, hex_slice, 16) catch return error.InvalidUnicode;
                    var tmp: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(cp, &tmp) catch return error.InvalidUnicode;
                    try buf.appendSlice(allocator, tmp[0..len]);
                    i += 4;
                },
                else => return error.InvalidEscape,
            }
            i += 2;
        } else {
            try buf.append(allocator, c);
            i += 1;
        }
    }
    return .{ .string_alloc_v = try buf.toOwnedSlice(allocator) };
}

fn parseJsonNull(p: *JsonParser) JsonError!Value {
    if (p.pos + 4 > p.input.len) return error.UnexpectedEof;
    if (!mem.eql(u8, p.input[p.pos..][0..4], "null")) return error.UnexpectedChar;
    p.pos += 4;
    return .{ .null_v = {} };
}

fn parseJsonBool(p: *JsonParser) JsonError!Value {
    if (p.input[p.pos] == 't') {
        if (p.pos + 4 > p.input.len) return error.UnexpectedEof;
        if (!mem.eql(u8, p.input[p.pos..][0..4], "true")) return error.UnexpectedChar;
        p.pos += 4;
        return .{ .bool_v = true };
    }
    if (p.pos + 5 > p.input.len) return error.UnexpectedEof;
    if (!mem.eql(u8, p.input[p.pos..][0..5], "false")) return error.UnexpectedChar;
    p.pos += 5;
    return .{ .bool_v = false };
}

fn parseJsonNumber(p: *JsonParser) JsonError!Value {
    const start = p.pos;
    if (p.input[p.pos] == '-') p.pos += 1;
    while (p.pos < p.input.len and p.input[p.pos] >= '0' and p.input[p.pos] <= '9') p.pos += 1;
    var is_float = false;
    if (p.pos < p.input.len and p.input[p.pos] == '.') {
        is_float = true;
        p.pos += 1;
        while (p.pos < p.input.len and p.input[p.pos] >= '0' and p.input[p.pos] <= '9') p.pos += 1;
    }
    if (p.pos < p.input.len and (p.input[p.pos] == 'e' or p.input[p.pos] == 'E')) {
        is_float = true;
        p.pos += 1;
        if (p.pos < p.input.len and (p.input[p.pos] == '+' or p.input[p.pos] == '-')) p.pos += 1;
        while (p.pos < p.input.len and p.input[p.pos] >= '0' and p.input[p.pos] <= '9') p.pos += 1;
    }
    const num_str = p.input[start..p.pos];
    if (num_str.len == 0 or (num_str.len == 1 and num_str[0] == '-')) return error.InvalidNumber;
    if (is_float) {
        const f = std.fmt.parseFloat(f64, num_str) catch return error.InvalidNumber;
        return .{ .float_v = f };
    }
    const n = std.fmt.parseInt(i64, num_str, 10) catch return error.InvalidNumber;
    return .{ .int_v = n };
}

// ─── .cc 生成（-d 模式：Value → .cc 文本）────────────────────────────────

const AppendCCError = Allocator.Error || std.fmt.BufPrintError;

fn appendCC(allocator: Allocator, buf: *ArrayList(u8), value: Value, indent: usize) AppendCCError!void {
    switch (value) {
        .object_v => |o| {
            var it = o.iterator();
            while (it.next()) |kv| {
                try appendCCField(allocator, buf, kv.key_ptr.*, kv.value_ptr.*, indent);
            }
        },
        .array_v => {
            // 顶层是数组：没有 key 包装，只能裸输出（用户用 -d 跑顶层数组会得到非典型 .cc）
            try appendCCArray(allocator, buf, value.array_v, indent);
        },
        else => {
            try appendCCScalar(allocator, buf, value);
            try buf.append(allocator, '\n');
        },
    }
}

fn appendCCField(allocator: Allocator, buf: *ArrayList(u8), key: []const u8, value: Value, indent: usize) AppendCCError!void {
    try appendIndent(allocator, buf, indent);
    try appendCCKey(allocator, buf, key);

    switch (value) {
        .null_v, .bool_v, .int_v, .float_v, .string_v, .string_alloc_v => {
            try buf.append(allocator, ' ');
            try appendCCScalar(allocator, buf, value);
            try buf.append(allocator, '\n');
        },
        .array_v => {
            try buf.append(allocator, '*');
            try buf.append(allocator, '\n');
            try appendCCArray(allocator, buf, value.array_v, indent + 1);
        },
        .object_v => {
            try buf.append(allocator, '\n');
            try appendCC(allocator, buf, value, indent + 1);
        },
    }
}

fn appendCCArray(allocator: Allocator, buf: *ArrayList(u8), items: ArrayList(Value), indent: usize) AppendCCError!void {
    if (items.items.len == 0) return;

    // 全是 object → 用 `,` 分隔；否则直接列表
    var all_objects = true;
    for (items.items) |it| {
        if (it != .object_v) {
            all_objects = false;
            break;
        }
    }

    for (items.items, 0..) |item, idx| {
        if (all_objects) {
            const obj = item.object_v;
            var it = obj.iterator();
            while (it.next()) |kv| {
                try appendCCField(allocator, buf, kv.key_ptr.*, kv.value_ptr.*, indent);
            }
            if (idx + 1 < items.items.len) {
                try appendIndent(allocator, buf, indent);
                try buf.append(allocator, ',');
                try buf.append(allocator, '\n');
            }
        } else {
            try appendIndent(allocator, buf, indent);
            try appendCCScalar(allocator, buf, item);
            try buf.append(allocator, '\n');
        }
    }
}

fn appendCCScalar(allocator: Allocator, buf: *ArrayList(u8), value: Value) AppendCCError!void {
    switch (value) {
        .null_v => try buf.appendSlice(allocator, "null"),
        .bool_v => |b| try buf.appendSlice(allocator, if (b) "true" else "false"),
        .int_v => |n| {
            var tmp: [32]u8 = undefined;
            const s = try std.fmt.bufPrint(&tmp, "{d}", .{n});
            try buf.appendSlice(allocator, s);
        },
        .float_v => |f| {
            var tmp: [64]u8 = undefined;
            const s = try std.fmt.bufPrint(&tmp, "{d}", .{f});
            try buf.appendSlice(allocator, s);
        },
        .string_v, .string_alloc_v => |s| {
            if (needsQuoting(s)) {
                try buf.append(allocator, '"');
                // 只转义内容，不再加外层引号
                try appendJsonEscapes(allocator, buf, s);
                try buf.append(allocator, '"');
            } else {
                try buf.appendSlice(allocator, s);
            }
        },
        else => {},
    }
}

/// 把字符串里的特殊字符转义成 .cc 转义形式（`"` `\\` `\n` `\t` 等）。
/// **不**加外层引号，由调用方决定。
fn appendJsonEscapes(allocator: Allocator, buf: *ArrayList(u8), s: []const u8) AppendCCError!void {
    for (s) |c| {
        if (c == '"') {
            try buf.appendSlice(allocator, "\\\"");
        } else if (c == '\\') {
            try buf.appendSlice(allocator, "\\\\");
        } else if (c == '\n') {
            try buf.appendSlice(allocator, "\\n");
        } else if (c == '\r') {
            try buf.appendSlice(allocator, "\\r");
        } else if (c == '\t') {
            try buf.appendSlice(allocator, "\\t");
        } else if (c < 0x20) {
            var tmp: [8]u8 = undefined;
            const esc = try std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{c});
            try buf.appendSlice(allocator, esc);
        } else {
            try buf.append(allocator, c);
        }
    }
}

fn appendCCKey(allocator: Allocator, buf: *ArrayList(u8), key: []const u8) AppendCCError!void {
    if (isValidIdentifier(key)) {
        try buf.appendSlice(allocator, key);
    } else {
        try buf.append(allocator, '"');
        try appendJsonString(allocator, buf, key);
        try buf.append(allocator, '"');
    }
}

fn isValidIdentifier(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s, 0..) |c, i| {
        const is_alpha = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
        const is_digit = c >= '0' and c <= '9';
        if (i == 0) {
            if (!is_alpha) return false;
        } else if (!is_alpha and !is_digit) {
            return false;
        }
    }
    return true;
}

fn needsQuoting(s: []const u8) bool {
    // .cc 解析器只在以下情况需要引号：
    //   1. 引号 `"` / 反斜杠 `\` — 字符串字面量语法
    //   2. 换行 / CR — 会断开行
    //   3. 起始字符是 `#` — 会被当注释
    //   4. 全部是空白 — trim 后变空字符串
    //   5. true / false / null / none / ~ — 保留字
    //   6. 数字字面量（-7、42、3.14）— 会被解析为数字
    //
    // 空格、tab、逗号、句号、分号、冒号等都是普通字符——它们在 .cc
    // 值里没有任何特殊语义，不需要引号。round-trip 应保留原始 .cc 风格。
    if (s.len == 0) return true;
    if (s[0] == '#') return true;
    if (mem.trim(u8, s, " \t\n\r").len == 0) return true; // 全部空白
    for (s) |c| {
        if (c == '"' or c == '\\' or c == '\n' or c == '\r') return true;
    }
    if (mem.eql(u8, s, "true") or mem.eql(u8, s, "false") or
        mem.eql(u8, s, "null") or mem.eql(u8, s, "none") or mem.eql(u8, s, "~"))
    {
        return true;
    }
    if (s[0] >= '0' and s[0] <= '9') return true;
    if (s[0] == '-' and s.len > 1 and s[1] >= '0' and s[1] <= '9') return true;
    return false;
}

/// 递归比较两个 Value（结构相等，忽略 string 借用 vs 分配差异）。
fn jsonEqual(a: Value, b: Value) bool {
    return switch (a) {
        .null_v => b == .null_v,
        .bool_v => |av| if (b == .bool_v) av == b.bool_v else false,
        .int_v => |av| switch (b) {
            .int_v => |bv| av == bv,
            .float_v => |bv| @as(f64, @floatFromInt(av)) == bv,
            else => false,
        },
        .float_v => |av| switch (b) {
            .float_v => |bv| av == bv,
            .int_v => |bv| av == @as(f64, @floatFromInt(bv)),
            else => false,
        },
        .string_v, .string_alloc_v => |av| switch (b) {
            .string_v, .string_alloc_v => |bv| mem.eql(u8, av, bv),
            else => false,
        },
        .array_v => |aa| switch (b) {
            .array_v => |ba| {
                if (aa.items.len != ba.items.len) return false;
                for (aa.items, ba.items) |ai, bi| if (!jsonEqual(ai, bi)) return false;
                return true;
            },
            else => false,
        },
        .object_v => |ao| switch (b) {
            .object_v => |bo| {
                if (ao.count() != bo.count()) return false;
                var it = ao.iterator();
                while (it.next()) |kv| {
                    const bv = bo.get(kv.key_ptr.*) orelse return false;
                    if (!jsonEqual(kv.value_ptr.*, bv)) return false;
                }
                return true;
            },
            else => false,
        },
    };
}

// ─── Tests ─────────────────────────────────────────────────────────────

test "tokenize records line numbers" {
    const allocator = std.testing.allocator;
    const input =
        \\a 1
        \\
        \\b 2
        \\c 3
    ;
    const items = try tokenize(allocator, input);
    defer allocator.free(items);
    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expectEqual(@as(usize, 1), items[0].line);
    try std.testing.expectEqual(@as(usize, 3), items[1].line);
    try std.testing.expectEqual(@as(usize, 4), items[2].line);
}

test "tokenize skips # comments" {
    const allocator = std.testing.allocator;
    const input =
        \\# leading comment
        \\a 1
        \\# middle comment
        \\    b 2 # NOT a comment (no inline support)
        \\c 3
    ;
    const items = try tokenize(allocator, input);
    defer allocator.free(items);
    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expectEqual(@as(usize, 2), items[0].line);
    try std.testing.expectEqualStrings("a 1", items[0].body);
    try std.testing.expectEqual(@as(usize, 4), items[1].line);
    try std.testing.expectEqual(@as(usize, 4), items[1].indent);
    try std.testing.expectEqualStrings("b 2 # NOT a comment (no inline support)", items[1].body);
    try std.testing.expectEqualStrings("c 3", items[2].body);
}

test "parseScalar" {
    const allocator = std.testing.allocator;
    try std.testing.expectEqual(@as(i64, 42), (try parseScalar(allocator, "42")).int_v);
    try std.testing.expectEqual(@as(i64, -7), (try parseScalar(allocator, "-7")).int_v);
    try std.testing.expectEqualStrings("hello", (try parseScalar(allocator, "hello")).string_v);
    try std.testing.expectEqualStrings("hello world", (try parseScalar(allocator, "hello world")).string_v);
    try std.testing.expectEqual(@as(bool, true), (try parseScalar(allocator, "true")).bool_v);
    try std.testing.expectEqual(@as(bool, false), (try parseScalar(allocator, "false")).bool_v);
    try std.testing.expect((try parseScalar(allocator, "null")) == .null_v);
    try std.testing.expect((try parseScalar(allocator, "none")) == .null_v);
    try std.testing.expect((try parseScalar(allocator, "~")) == .null_v);
    const f = try parseScalar(allocator, "3.14");
    try std.testing.expect(f == .float_v);
    // 无转义 → 借用 string_v
    const q = try parseScalar(allocator, "\"quoted\"");
    try std.testing.expect(q == .string_v);
    try std.testing.expectEqualStrings("quoted", q.string_v);
}

test "parseScalar with string escapes" {
    const allocator = std.testing.allocator;

    // \\n → 换行（触发 string_alloc_v）
    {
        var v = try parseScalar(allocator, "\"a\\nb\"");
        defer v.deinit(allocator);
        try std.testing.expect(v == .string_alloc_v);
        try std.testing.expectEqualStrings("a\nb", v.string_alloc_v);
    }
    // \\t → tab
    {
        var v = try parseScalar(allocator, "\"col1\\tcol2\"");
        defer v.deinit(allocator);
        try std.testing.expectEqualStrings("col1\tcol2", v.string_alloc_v);
    }
    // \\\" → "
    {
        var v = try parseScalar(allocator, "\"say \\\"hi\\\"\"");
        defer v.deinit(allocator);
        try std.testing.expectEqualStrings("say \"hi\"", v.string_alloc_v);
    }
    // \\\\ → \
    {
        var v = try parseScalar(allocator, "\"a\\\\b\"");
        defer v.deinit(allocator);
        try std.testing.expectEqualStrings("a\\b", v.string_alloc_v);
    }
    // \\r\\n → CRLF
    {
        var v = try parseScalar(allocator, "\"line1\\r\\nline2\"");
        defer v.deinit(allocator);
        try std.testing.expectEqualStrings("line1\r\nline2", v.string_alloc_v);
    }
}

test "parse simple object" {
    const allocator = std.testing.allocator;
    const input =
        \\model deepseek-v4-flash-free
        \\temperature 0.5
    ;
    var v = try parseCC(allocator, input);
    defer v.deinit(allocator);
    const obj = v.object_v;
    try std.testing.expectEqualStrings("deepseek-v4-flash-free", obj.get("model").?.string_v);
    try std.testing.expectEqual(@as(f64, 0.5), obj.get("temperature").?.float_v);
}

test "parse messages array with object items" {
    const allocator = std.testing.allocator;
    const input =
        \\messages+
        \\    role system
        \\    content 1
        \\    ,
        \\    role user
        \\    content ls
    ;
    var v = try parseCC(allocator, input);
    defer v.deinit(allocator);
    const arr = v.object_v.get("messages").?.array_v;
    try std.testing.expectEqual(@as(usize, 2), arr.items.len);
    try std.testing.expectEqualStrings("system", arr.items[0].object_v.get("role").?.string_v);
    try std.testing.expectEqual(@as(i64, 1), arr.items[0].object_v.get("content").?.int_v);
    try std.testing.expectEqualStrings("user", arr.items[1].object_v.get("role").?.string_v);
    try std.testing.expectEqualStrings("ls", arr.items[1].object_v.get("content").?.string_v);
}

test "parse required* scalar array" {
    const allocator = std.testing.allocator;
    const input =
        \\required*
        \\    location
    ;
    var v = try parseCC(allocator, input);
    defer v.deinit(allocator);
    const arr = v.object_v.get("required").?.array_v;
    try std.testing.expectEqual(@as(usize, 1), arr.items.len);
    try std.testing.expectEqualStrings("location", arr.items[0].string_v);
}

test "parse tools with nested function parameters" {
    const allocator = std.testing.allocator;
    const input =
        \\tools*
        \\    type function
        \\    function
        \\        name get_weather
        \\        description Get weather
        \\        parameters
        \\            type object
        \\            properties
        \\                location
        \\                    type string
        \\            required*
        \\                location
    ;
    var v = try parseCC(allocator, input);
    defer v.deinit(allocator);
    const tools = v.object_v.get("tools").?.array_v;
    try std.testing.expectEqual(@as(usize, 1), tools.items.len);
    const tool = tools.items[0].object_v;
    try std.testing.expectEqualStrings("function", tool.get("type").?.string_v);
    const func = tool.get("function").?.object_v;
    try std.testing.expectEqualStrings("get_weather", func.get("name").?.string_v);
    try std.testing.expectEqualStrings("Get weather", func.get("description").?.string_v);
    const params = func.get("parameters").?.object_v;
    try std.testing.expectEqualStrings("object", params.get("type").?.string_v);
    const props = params.get("properties").?.object_v;
    const loc = props.get("location").?.object_v;
    try std.testing.expectEqualStrings("string", loc.get("type").?.string_v);
    const req = params.get("required").?.array_v;
    try std.testing.expectEqual(@as(usize, 1), req.items.len);
    try std.testing.expectEqualStrings("location", req.items[0].string_v);
}

test "parse empty input" {
    const allocator = std.testing.allocator;
    var v = try parseCC(allocator, "");
    defer v.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), v.object_v.count());
}

test "multi-line string with triple quote" {
    const allocator = std.testing.allocator;
    const input =
        \\content """
        \\    Line 1
        \\    Line 2
        \\    """
    ;
    var v = try parseCC(allocator, input);
    defer v.deinit(allocator);
    const content = v.object_v.get("content").?.string_alloc_v;
    try std.testing.expectEqualStrings("Line 1\nLine 2", content);
}

test "multi-line string preserves sub-indent" {
    const allocator = std.testing.allocator;
    const input =
        \\content """
        \\    First
        \\        Sub-indented
        \\    Third
        \\    """
    ;
    var v = try parseCC(allocator, input);
    defer v.deinit(allocator);
    const content = v.object_v.get("content").?.string_alloc_v;
    try std.testing.expectEqualStrings("First\n    Sub-indented\nThird", content);
}

test "multi-line string immediately closed" {
    const allocator = std.testing.allocator;
    const input =
        \\content """
        \\    """
    ;
    var v = try parseCC(allocator, input);
    defer v.deinit(allocator);
    const content = v.object_v.get("content").?.string_alloc_v;
    try std.testing.expectEqualStrings("", content);
}

test "enum+ as JSON Schema enum array" {
    const allocator = std.testing.allocator;
    const input =
        \\enum+
        \\    a
        \\    b
        \\    c
    ;
    var v = try parseCC(allocator, input);
    defer v.deinit(allocator);
    const arr = v.object_v.get("enum").?.array_v;
    try std.testing.expectEqual(@as(usize, 3), arr.items.len);
    try std.testing.expectEqualStrings("a", arr.items[0].string_v);
    try std.testing.expectEqualStrings("b", arr.items[1].string_v);
    try std.testing.expectEqualStrings("c", arr.items[2].string_v);
}

test "peekItemKind heuristic" {
    const allocator = std.testing.allocator;

    // 单元素无值 → 1 标量
    {
        var v = try parseCC(allocator, "list*\n    hello\n");
        defer v.deinit(allocator);
        const arr = v.object_v.get("list").?.array_v;
        try std.testing.expectEqual(@as(usize, 1), arr.items.len);
        try std.testing.expectEqualStrings("hello", arr.items[0].string_v);
    }

    // 多元素无值 → 多标量
    {
        var v = try parseCC(allocator, "list*\n    hello\n    world\n");
        defer v.deinit(allocator);
        const arr = v.object_v.get("list").?.array_v;
        try std.testing.expectEqual(@as(usize, 2), arr.items.len);
        try std.testing.expectEqualStrings("hello", arr.items[0].string_v);
        try std.testing.expectEqualStrings("world", arr.items[1].string_v);
    }

    // 首元素有值 → 1 对象
    {
        var v = try parseCC(allocator, "list*\n    a b\n    c d\n");
        defer v.deinit(allocator);
        const arr = v.object_v.get("list").?.array_v;
        try std.testing.expectEqual(@as(usize, 1), arr.items.len);
        const obj = arr.items[0].object_v;
        try std.testing.expectEqualStrings("b", obj.get("a").?.string_v);
        try std.testing.expectEqualStrings("d", obj.get("c").?.string_v);
    }

    // 首元素无值、下行更深 → 1 对象（嵌套）
    {
        var v = try parseCC(allocator, "list*\n    function\n        name foo\n");
        defer v.deinit(allocator);
        const arr = v.object_v.get("list").?.array_v;
        try std.testing.expectEqual(@as(usize, 1), arr.items.len);
        const obj = arr.items[0].object_v;
        const func = obj.get("function").?.object_v;
        try std.testing.expectEqualStrings("foo", func.get("name").?.string_v);
    }
}

test "parse error reports line number" {
    const allocator = std.testing.allocator;
    // 第 1 行有缩进，但根字段必须 indent=0
    try std.testing.expectError(error.UnexpectedIndent, parseCC(allocator, "  bad\n"));
}

test "user example tools.cc" {
    // 完整复刻 D:\zbin\tools.cc 内容
    const allocator = std.testing.allocator;
    const input =
        \\model deepseek-v4-flash-free
        \\messages+
        \\    role system
        \\    content 1
        \\    ,
        \\    role user
        \\    content ls
        \\tools*
        \\    type function
        \\    function
        \\        name get_weather
        \\        description Get weather of a location, the user should supply a location first.
        \\        parameters
        \\            type object
        \\            properties
        \\                location
        \\                    type string
        \\                    description The city and state, e.g. San Francisco, CA
        \\            required*
        \\                location
    ;
    var v = try parseCC(allocator, input);
    defer v.deinit(allocator);
    const tools = v.object_v.get("tools").?.array_v;
    try std.testing.expectEqual(@as(usize, 1), tools.items.len);
    const desc = tools.items[0].object_v.get("function").?.object_v.get("description").?.string_v;
    try std.testing.expectEqualStrings(
        "Get weather of a location, the user should supply a location first.",
        desc,
    );
}

// ─── Fixture 测试 ──────────────────────────────────────────────────────
// 跑 examples/<name>.cc，解析两份 JSON 并 jsonEqual 比对（不依赖 hash 顺序）
fn checkFixture(allocator: Allocator, cc_path: []const u8, json_path: []const u8) !void {
    const io = std.testing.io;
    var in_buf: [4096]u8 = undefined;

    const file = try Io.Dir.cwd().openFile(io, cc_path, .{});
    defer file.close(io);
    var reader = file.reader(io, &in_buf);
    const input = try reader.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(input);

    var v = try parseCC(allocator, input);
    defer v.deinit(allocator);

    var out: ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try appendCompactJson(allocator, &out, v);

    const golden_file = try Io.Dir.cwd().openFile(io, json_path, .{});
    defer golden_file.close(io);
    var g_reader = golden_file.reader(io, &in_buf);
    const golden = try g_reader.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(golden);
    const golden_stripped = mem.trimEnd(u8, golden, " \n\r\t");

    // 用 JSON 语义比对（hash 顺序无关）
    var actual_v = parseJson(allocator, out.items) catch |err| {
        std.debug.print("\n--- {s}: parseJson(actual) failed: {s} ---\nactual:\n{s}\n---\n", .{ cc_path, @errorName(err), out.items });
        return err;
    };
    defer actual_v.deinit(allocator);
    var expected_v = parseJson(allocator, golden_stripped) catch |err| {
        std.debug.print("\n--- {s}: parseJson(golden) failed: {s} ---\ngolden:\n{s}\n---\n", .{ cc_path, @errorName(err), golden_stripped });
        return err;
    };
    defer expected_v.deinit(allocator);

    if (!jsonEqual(actual_v, expected_v)) {
        std.debug.print("\n--- SEMANTIC MISMATCH for {s} ---\nexpected:\n{s}\nactual:\n{s}\n--- END ---\n", .{ cc_path, golden_stripped, out.items });
        return error.TestExpectedEqual;
    }
}

test "fixture: get_weather" {
    try checkFixture(std.testing.allocator, "examples/get_weather.cc", "examples/get_weather.golden.json");
}

test "fixture: web_search" {
    try checkFixture(std.testing.allocator, "examples/web_search.cc", "examples/web_search.golden.json");
}

test "fixture: send_email" {
    try checkFixture(std.testing.allocator, "examples/send_email.cc", "examples/send_email.golden.json");
}

test "fixture: calculator" {
    try checkFixture(std.testing.allocator, "examples/calculator.cc", "examples/calculator.golden.json");
}

test "fixture: chained_messages" {
    try checkFixture(std.testing.allocator, "examples/chained_messages.cc", "examples/chained_messages.golden.json");
}

test "fixture: enum_tool" {
    try checkFixture(std.testing.allocator, "examples/enum_tool.cc", "examples/enum_tool.golden.json");
}

test "fixture: long_prompt" {
    try checkFixture(std.testing.allocator, "examples/long_prompt.cc", "examples/long_prompt.golden.json");
}

test "fixture: image_search" {
    try checkFixture(std.testing.allocator, "examples/image_search.cc", "examples/image_search.golden.json");
}

test "fixture: unicode_prompt" {
    try checkFixture(std.testing.allocator, "examples/unicode_prompt.cc", "examples/unicode_prompt.golden.json");
}

test "fixture: boolean_flag" {
    try checkFixture(std.testing.allocator, "examples/boolean_flag.cc", "examples/boolean_flag.golden.json");
}

test "parseJson basic types" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { input: []const u8, expected: Value }{
        .{ .input = "null", .expected = .{ .null_v = {} } },
        .{ .input = "true", .expected = .{ .bool_v = true } },
        .{ .input = "false", .expected = .{ .bool_v = false } },
        .{ .input = "42", .expected = .{ .int_v = 42 } },
        .{ .input = "-7", .expected = .{ .int_v = -7 } },
        .{ .input = "3.14", .expected = .{ .float_v = 3.14 } },
        .{ .input = "\"hello\"", .expected = .{ .string_v = "hello" } },
        .{ .input = "\"\"", .expected = .{ .string_v = "" } },
    };
    for (cases) |c| {
        var v = try parseJson(allocator, c.input);
        defer v.deinit(allocator);
        try std.testing.expect(jsonEqual(v, c.expected));
    }
}

test "parseJson object and array" {
    const allocator = std.testing.allocator;
    const input =
        \\{"name":"foo","values":[1,2,3],"nested":{"a":true,"b":null}}
    ;
    var v = try parseJson(allocator, input);
    defer v.deinit(allocator);
    const obj = v.object_v;
    try std.testing.expectEqualStrings("foo", obj.get("name").?.string_v);
    const arr = obj.get("values").?.array_v;
    try std.testing.expectEqual(@as(usize, 3), arr.items.len);
    try std.testing.expectEqual(@as(i64, 2), arr.items[1].int_v);
    const nested = obj.get("nested").?.object_v;
    try std.testing.expect(nested.get("a").?.bool_v);
    try std.testing.expectEqual(@as(?Value, .{ .null_v = {} }), nested.get("b"));
}

test "parseJson string escapes" {
    const allocator = std.testing.allocator;
    var v = try parseJson(allocator, "\"a\\nb\\tc\\\"d\"");
    defer v.deinit(allocator);
    // 有转义 → string_alloc_v
    try std.testing.expect(v == .string_alloc_v);
    try std.testing.expectEqualStrings("a\nb\tc\"d", v.string_alloc_v);
}

test "parseJson unicode escape \\uXXXX" {
    const allocator = std.testing.allocator;
    // U+4E2D = 中
    var v = try parseJson(allocator, "\"\\u4E2D\"");
    defer v.deinit(allocator);
    try std.testing.expect(v == .string_alloc_v);
    try std.testing.expectEqualStrings("中", v.string_alloc_v);
}

test "parseJson strict: unknown escape fails" {
    const allocator = std.testing.allocator;
    // \x 不是 JSON 合法转义
    try std.testing.expectError(error.InvalidEscape, parseJson(allocator, "\"\\x\""));
}

test "parseJson strict: trailing content fails" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.TrailingContent, parseJson(allocator, "1 2"));
}

test "appendCC scalar object" {
    const allocator = std.testing.allocator;
    var v = Value{ .object_v = .empty };
    defer v.deinit(allocator);
    try v.object_v.put(allocator, "model", .{ .string_v = "gpt-4" });
    try v.object_v.put(allocator, "count", .{ .int_v = 42 });
    try v.object_v.put(allocator, "active", .{ .bool_v = true });

    var out: ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try appendCC(allocator, &out, v, 0);
    const text = out.items;
    // "gpt-4" 无特殊字符 → 不加引号
    try std.testing.expect(std.mem.indexOf(u8, text, "model gpt-4\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "count 42\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "active true\n") != null);
}

test "appendCC array of objects" {
    const allocator = std.testing.allocator;
    var v = Value{ .object_v = .empty };
    defer v.deinit(allocator);

    var obj1: StringHashMap(Value) = .empty;
    try obj1.put(allocator, "role", .{ .string_v = "user" });

    var arr: ArrayList(Value) = .empty;
    try arr.append(allocator, .{ .object_v = obj1 });
    try v.object_v.put(allocator, "messages", .{ .array_v = arr });

    var out: ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try appendCC(allocator, &out, v, 0);
    const text = out.items;
    try std.testing.expect(std.mem.indexOf(u8, text, "messages*\n") != null);
    // appendCC indent 是 2 空格/级（默认）；"user" 无特殊字符所以不加引号
    try std.testing.expect(std.mem.indexOf(u8, text, "  role user\n") != null);
}

test "appendCC quotes when needed" {
    const allocator = std.testing.allocator;
    var v = Value{ .object_v = .empty };
    defer v.deinit(allocator);
    // 这些值真的需要引号（\" / \\ / \n / 数字字面量）
    try v.object_v.put(allocator, "quoted", .{ .string_v = "say \"hi\"" });
    try v.object_v.put(allocator, "backslash", .{ .string_v = "a\\b" });
    try v.object_v.put(allocator, "newline", .{ .string_v = "line1\nline2" });
    try v.object_v.put(allocator, "numeric", .{ .string_v = "42" });
    try v.object_v.put(allocator, "bool_word", .{ .string_v = "true" });
    // 这些**不**需要引号：含空格/逗号/句号都是普通字符
    try v.object_v.put(allocator, "natural", .{ .string_v = "Get weather, please." });

    var out: ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try appendCC(allocator, &out, v, 0);
    const text = out.items;
    try std.testing.expect(std.mem.indexOf(u8, text, "quoted \"say \\\"hi\\\"\"\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "backslash \"a\\\\b\"\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "newline \"line1\\nline2\"\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "numeric \"42\"\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "bool_word \"true\"\n") != null);
    // "Get weather, please." 不应加引号
    try std.testing.expect(std.mem.indexOf(u8, text, "natural Get weather, please.\n") != null);
}

test "round-trip: golden.json → .cc → jsonEqual to original" {
    const allocator = std.testing.allocator;

    // 跑所有 10 个样本
    const fixtures = [_][]const u8{
        "examples/get_weather.golden.json",
        "examples/web_search.golden.json",
        "examples/send_email.golden.json",
        "examples/calculator.golden.json",
        "examples/chained_messages.golden.json",
        "examples/enum_tool.golden.json",
        "examples/long_prompt.golden.json",
        "examples/image_search.golden.json",
        "examples/unicode_prompt.golden.json",
        "examples/boolean_flag.golden.json",
    };

    for (fixtures) |json_path| {
        const io = std.testing.io;
        var in_buf: [4096]u8 = undefined;
        const file = try Io.Dir.cwd().openFile(io, json_path, .{});
        defer file.close(io);
        var reader = file.reader(io, &in_buf);
        const json_in = try reader.interface.allocRemaining(allocator, .unlimited);
        defer allocator.free(json_in);

        // JSON → .cc
        var v1 = try parseJson(allocator, json_in);
        defer v1.deinit(allocator);
        var cc_out: ArrayList(u8) = .empty;
        defer cc_out.deinit(allocator);
        try appendCC(allocator, &cc_out, v1, 0);

        // .cc → JSON
        var v2 = try parseCC(allocator, cc_out.items);
        defer v2.deinit(allocator);
        var json_out: ArrayList(u8) = .empty;
        defer json_out.deinit(allocator);
        try appendCompactJson(allocator, &json_out, v2);

        // 比对两个 JSON 的 Value 结构
        var v2_parsed = try parseJson(allocator, json_out.items);
        defer v2_parsed.deinit(allocator);

        if (!jsonEqual(v1, v2_parsed)) {
            std.debug.print("\n--- ROUND-TRIP MISMATCH: {s} ---\noriginal: {s}\nroundtrip: {s}\n---\n", .{ json_path, json_in, json_out.items });
            return error.TestExpectedEqual;
        }
    }
}

test "isValidIdentifier" {
    try std.testing.expect(isValidIdentifier("foo"));
    try std.testing.expect(isValidIdentifier("Foo"));
    try std.testing.expect(isValidIdentifier("_foo"));
    try std.testing.expect(isValidIdentifier("a1"));
    try std.testing.expect(isValidIdentifier("foo_bar_baz"));
    try std.testing.expect(isValidIdentifier("X9"));
    try std.testing.expect(!isValidIdentifier(""));
    try std.testing.expect(!isValidIdentifier("1foo"));
    try std.testing.expect(!isValidIdentifier("9"));
    try std.testing.expect(!isValidIdentifier("foo bar"));
    try std.testing.expect(!isValidIdentifier("foo-bar"));
    try std.testing.expect(!isValidIdentifier("foo.bar"));
    try std.testing.expect(!isValidIdentifier("foo:bar"));
    try std.testing.expect(!isValidIdentifier("+"));
    try std.testing.expect(!isValidIdentifier("*"));
    try std.testing.expect(!isValidIdentifier(","));
    try std.testing.expect(!isValidIdentifier("foo+"));
    try std.testing.expect(!isValidIdentifier("\"foo\""));
}

test "needsQuoting" {
    // 不需要引号：含空格/逗号/句号/分号/冒号/连字符都 OK
    try std.testing.expect(!needsQuoting("hello"));
    try std.testing.expect(!needsQuoting("hello world"));
    try std.testing.expect(!needsQuoting("Get weather, please."));
    try std.testing.expect(!needsQuoting("foo-bar"));
    try std.testing.expect(!needsQuoting("a:b"));
    try std.testing.expect(!needsQuoting("path/to/file"));
    try std.testing.expect(!needsQuoting("v1.0"));
    // 需要引号
    try std.testing.expect(needsQuoting(""));
    try std.testing.expect(needsQuoting("# comment"));
    try std.testing.expect(needsQuoting("say \"hi\""));
    try std.testing.expect(needsQuoting("a\\b"));
    try std.testing.expect(needsQuoting("line1\nline2"));
    try std.testing.expect(needsQuoting("line1\rline2"));
    try std.testing.expect(needsQuoting("   "));
    try std.testing.expect(needsQuoting(" "));
    try std.testing.expect(needsQuoting("\t"));
    try std.testing.expect(needsQuoting("true"));
    try std.testing.expect(needsQuoting("false"));
    try std.testing.expect(needsQuoting("null"));
    try std.testing.expect(needsQuoting("none"));
    try std.testing.expect(needsQuoting("~"));
    try std.testing.expect(needsQuoting("42"));
    try std.testing.expect(needsQuoting("-7"));
    try std.testing.expect(needsQuoting("3.14"));
    try std.testing.expect(needsQuoting("0"));
}

test "jsonEqual edge cases" {
    const allocator = std.testing.allocator;
    // int vs float（数值相等）
    {
        var a = try parseJson(allocator, "42");
        defer a.deinit(allocator);
        var b = try parseJson(allocator, "42.0");
        defer b.deinit(allocator);
        try std.testing.expect(jsonEqual(a, b));
    }
    // 嵌套对象相等（hash 顺序无关）
    {
        var a = try parseJson(allocator, "{\"x\":1,\"y\":2}");
        defer a.deinit(allocator);
        var b = try parseJson(allocator, "{\"y\":2,\"x\":1}");
        defer b.deinit(allocator);
        try std.testing.expect(jsonEqual(a, b));
    }
    // 不同类型 → 不等
    {
        const a = Value{ .int_v = 42 };
        const b = Value{ .string_v = "42" };
        try std.testing.expect(!jsonEqual(a, b));
    }
    // null vs absent key → 不等
    {
        var m1: StringHashMap(Value) = .empty;
        defer m1.deinit(allocator);
        try m1.put(allocator, "a", .{ .null_v = {} });
        var m2: StringHashMap(Value) = .empty;
        defer m2.deinit(allocator);
        try std.testing.expect(!jsonEqual(.{ .object_v = m1 }, .{ .object_v = m2 }));
    }
    // 数组长度不同
    {
        var a = try parseJson(allocator, "[1,2,3]");
        defer a.deinit(allocator);
        var b = try parseJson(allocator, "[1,2]");
        defer b.deinit(allocator);
        try std.testing.expect(!jsonEqual(a, b));
    }
    // 嵌套数组相等
    {
        var a = try parseJson(allocator, "[[1,2],[3,4]]");
        defer a.deinit(allocator);
        var b = try parseJson(allocator, "[[1,2],[3,4]]");
        defer b.deinit(allocator);
        try std.testing.expect(jsonEqual(a, b));
    }
}

test "parseJson empty object and array" {
    const allocator = std.testing.allocator;
    var eo = try parseJson(allocator, "{}");
    defer eo.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), eo.object_v.count());

    var ea = try parseJson(allocator, "[]");
    defer ea.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), ea.array_v.items.len);
}

test "parseJson scientific notation" {
    const allocator = std.testing.allocator;
    var v = try parseJson(allocator, "1.5e10");
    defer v.deinit(allocator);
    try std.testing.expect(v == .float_v);
    try std.testing.expectEqual(@as(f64, 1.5e10), v.float_v);

    var v2 = try parseJson(allocator, "-2.5E-3");
    defer v2.deinit(allocator);
    try std.testing.expect(v2 == .float_v);
    try std.testing.expectEqual(@as(f64, -2.5e-3), v2.float_v);
}

test "parseJson negative numbers" {
    const allocator = std.testing.allocator;
    var v = try parseJson(allocator, "-42");
    defer v.deinit(allocator);
    try std.testing.expectEqual(@as(i64, -42), v.int_v);

    var v2 = try parseJson(allocator, "-3.14");
    defer v2.deinit(allocator);
    try std.testing.expect(v2 == .float_v);
    try std.testing.expectEqual(@as(f64, -3.14), v2.float_v);
}

test "parseJson deeply nested" {
    const allocator = std.testing.allocator;
    const input = "{\"a\":{\"b\":{\"c\":{\"d\":{\"e\":42}}}}}";
    var v = try parseJson(allocator, input);
    defer v.deinit(allocator);
    const e = v.object_v.get("a").?.object_v.get("b").?.object_v.get("c").?.object_v.get("d").?.object_v.get("e").?;
    try std.testing.expectEqual(@as(i64, 42), e.int_v);
}

test "parseJson array of mixed types" {
    const allocator = std.testing.allocator;
    var v = try parseJson(allocator, "[1,\"two\",true,null,3.14]");
    defer v.deinit(allocator);
    const arr = v.array_v;
    try std.testing.expectEqual(@as(usize, 5), arr.items.len);
    try std.testing.expectEqual(@as(i64, 1), arr.items[0].int_v);
    try std.testing.expectEqualStrings("two", arr.items[1].string_v);
    try std.testing.expect(arr.items[2].bool_v);
    try std.testing.expect(arr.items[3] == .null_v);
    try std.testing.expect(arr.items[4] == .float_v);
}

test "parseJson strict: various errors" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.UnterminatedString, parseJson(allocator, "\"unclosed"));
    try std.testing.expectError(error.ExpectedComma, parseJson(allocator, "[1 2]"));
    try std.testing.expectError(error.UnexpectedEof, parseJson(allocator, "["));
    try std.testing.expectError(error.ExpectedColon, parseJson(allocator, "{\"a\"")); // 对象先查 : 再查 }
    try std.testing.expectError(error.ExpectedKey, parseJson(allocator, "{:1}"));
    try std.testing.expectError(error.ExpectedColon, parseJson(allocator, "{\"a\" 1}"));
    try std.testing.expectError(error.InvalidEscape, parseJson(allocator, "\"\\q\""));
}

test "parseJson whitespace tolerance" {
    const allocator = std.testing.allocator;
    var v = try parseJson(allocator, "  \n\t { \n  \"a\"  :  1  \n  }  \n");
    defer v.deinit(allocator);
    try std.testing.expectEqual(@as(i64, 1), v.object_v.get("a").?.int_v);
}
