//! A minimal, zero-dependency YAML reader for the project-types config schema.
//!
//! This is **not** a general YAML parser. It supports exactly the block-style
//! subset the config uses: nested mappings (`key: value` / `key:` + indented
//! block), block sequences (`- item`), inline sequence-item mappings
//! (`- key: value`), `#` comments, blank lines, an optional leading `---`, and
//! single/double-quoted or plain scalars. Indentation must use spaces. A colon
//! inside a quoted scalar is fine; an unquoted scalar containing `: ` is not
//! supported (none occur in the schema).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Value = union(enum) {
    scalar: []const u8,
    list: []const Value,
    map: []const Pair,

    pub const Pair = struct { key: []const u8, value: Value };

    pub fn asScalar(self: Value) ?[]const u8 {
        return switch (self) {
            .scalar => |s| s,
            else => null,
        };
    }

    pub fn asList(self: Value) ?[]const Value {
        return switch (self) {
            .list => |l| l,
            else => null,
        };
    }

    /// Looks up `key` in a mapping value (linear scan). Null for non-maps or
    /// missing keys.
    pub fn get(self: Value, key: []const u8) ?Value {
        switch (self) {
            .map => |pairs| {
                for (pairs) |p| {
                    if (std.mem.eql(u8, p.key, key)) return p.value;
                }
                return null;
            },
            else => return null,
        }
    }
};

pub const ParseError = error{MalformedYaml} || Allocator.Error;

const Line = struct { indent: usize, text: []const u8 };

const Parser = struct {
    lines: []const Line,
    i: usize = 0,
    arena: Allocator,

    fn peek(self: *Parser) ?Line {
        return if (self.i < self.lines.len) self.lines[self.i] else null;
    }

    /// Parses a block node whose lines are at indentation >= `indent`. Returns
    /// a mapping or a sequence depending on the first line.
    fn parseNode(self: *Parser, indent: usize) ParseError!Value {
        const first = self.peek() orelse return Value{ .map = &.{} };
        if (isSeqItem(first.text)) return self.parseSequence(first.indent);
        return self.parseMapping(indent);
    }

    fn parseMapping(self: *Parser, indent: usize) ParseError!Value {
        var pairs: std.ArrayListUnmanaged(Value.Pair) = .empty;
        while (self.peek()) |line| {
            if (line.indent != indent or isSeqItem(line.text)) break;
            self.i += 1;
            const pair = try self.parsePair(line.text, indent);
            try pairs.append(self.arena, pair);
        }
        return Value{ .map = try pairs.toOwnedSlice(self.arena) };
    }

    /// Parses one `key: value` / `key:` line into a pair, recursing for a
    /// nested block value when the inline value is absent.
    fn parsePair(self: *Parser, text: []const u8, indent: usize) ParseError!Value.Pair {
        const colon = std.mem.indexOfScalar(u8, text, ':') orelse return error.MalformedYaml;
        const key = std.mem.trim(u8, text[0..colon], " \t");
        const rest = std.mem.trim(u8, text[colon + 1 ..], " \t");
        if (rest.len > 0) {
            return .{ .key = key, .value = .{ .scalar = unquote(rest) } };
        }
        // Block value: a deeper mapping, or a sequence at indent >= this line.
        if (self.peek()) |next| {
            if (isSeqItem(next.text) and next.indent >= indent) {
                return .{ .key = key, .value = try self.parseSequence(next.indent) };
            }
            if (next.indent > indent) {
                return .{ .key = key, .value = try self.parseNode(next.indent) };
            }
        }
        return .{ .key = key, .value = .{ .scalar = "" } };
    }

    fn parseSequence(self: *Parser, indent: usize) ParseError!Value {
        var items: std.ArrayListUnmanaged(Value) = .empty;
        while (self.peek()) |line| {
            if (line.indent != indent or !isSeqItem(line.text)) break;
            self.i += 1;
            const rest = std.mem.trim(u8, line.text[1..], " \t"); // after '-'
            try items.append(self.arena, try self.parseSeqItem(rest, indent));
        }
        return Value{ .list = try items.toOwnedSlice(self.arena) };
    }

    /// Parses a sequence item. If `rest` looks like `key: value`, the item is a
    /// mapping whose first pair is inline and whose remaining pairs are the
    /// following lines indented past the dash.
    fn parseSeqItem(self: *Parser, rest: []const u8, dash_indent: usize) ParseError!Value {
        if (rest.len == 0) {
            // Nested block on following lines.
            const next = self.peek() orelse return Value{ .scalar = "" };
            return self.parseNode(next.indent);
        }
        if (std.mem.indexOfScalar(u8, rest, ':')) |_| {
            var pairs: std.ArrayListUnmanaged(Value.Pair) = .empty;
            try pairs.append(self.arena, try self.parsePair(rest, dash_indent + 2));
            // Continuation pairs are indented past the dash.
            while (self.peek()) |line| {
                if (line.indent <= dash_indent or isSeqItem(line.text)) break;
                self.i += 1;
                try pairs.append(self.arena, try self.parsePair(line.text, line.indent));
            }
            return Value{ .map = try pairs.toOwnedSlice(self.arena) };
        }
        return Value{ .scalar = unquote(rest) };
    }
};

fn isSeqItem(text: []const u8) bool {
    return text.len >= 1 and text[0] == '-' and (text.len == 1 or text[1] == ' ');
}

/// Strips a single layer of surrounding single or double quotes.
fn unquote(s: []const u8) []const u8 {
    if (s.len >= 2) {
        const q = s[0];
        if ((q == '"' or q == '\'') and s[s.len - 1] == q) return s[1 .. s.len - 1];
    }
    return s;
}

/// Parses `source` into a single root `Value` (a mapping for the config
/// schema). All slices are allocated in `arena`.
pub fn parse(arena: Allocator, source: []const u8) ParseError!Value {
    var lines: std.ArrayListUnmanaged(Line) = .empty;
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |raw| {
        const no_cr = std.mem.trimEnd(u8, raw, "\r");
        const trimmed = std.mem.trimStart(u8, no_cr, " ");
        const indent = no_cr.len - trimmed.len;
        const content = std.mem.trimEnd(u8, trimmed, " \t");
        if (content.len == 0 or content[0] == '#') continue;
        if (std.mem.eql(u8, content, "---")) continue;
        try lines.append(arena, .{ .indent = indent, .text = content });
    }
    if (lines.items.len == 0) return Value{ .map = &.{} };

    var p = Parser{ .lines = lines.items, .arena = arena };
    return p.parseNode(lines.items[0].indent);
}

test "parse project-types schema" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\project_types:
        \\  - name: helm-chart
        \\    description: A chart
        \\    indicators:
        \\      - has_file: Chart.yaml
        \\      - has_glob: "*.tf"
        \\  - name: app
        \\    indicators:
        \\      - cel: '"x" in files'
    ;
    const root = try parse(arena.allocator(), src);
    const list = root.get("project_types").?.asList().?;
    try std.testing.expectEqual(@as(usize, 2), list.len);

    const e0 = list[0];
    try std.testing.expectEqualStrings("helm-chart", e0.get("name").?.asScalar().?);
    try std.testing.expectEqualStrings("A chart", e0.get("description").?.asScalar().?);
    const inds = e0.get("indicators").?.asList().?;
    try std.testing.expectEqual(@as(usize, 2), inds.len);
    try std.testing.expectEqualStrings("Chart.yaml", inds[0].get("has_file").?.asScalar().?);
    try std.testing.expectEqualStrings("*.tf", inds[1].get("has_glob").?.asScalar().?);

    const e1 = list[1];
    try std.testing.expectEqualStrings("app", e1.get("name").?.asScalar().?);
    const inds1 = e1.get("indicators").?.asList().?;
    try std.testing.expectEqualStrings("\"x\" in files", inds1[0].get("cel").?.asScalar().?);
}
