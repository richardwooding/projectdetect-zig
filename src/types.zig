//! Core value types: `Indicator`, `Match`, `ProjectType`, plus the glob and
//! case-insensitive matchers they rely on.

const std = @import("std");

/// A single match rule evaluated against a directory's listing.
///
/// Indicators are OR'd within a `ProjectType`: the first one that fires
/// identifies the directory as that type. The active tag determines what the
/// rule sees:
///
/// - `has_file` — case-insensitive exact **file** basename match (ASCII fold,
///   e.g. `NuGet.Config` matches `nuget.config`).
/// - `has_glob` — glob over **file** basenames only (e.g. `*.tf`).
/// - `has_subdir_glob` — glob over immediate **subdirectory** basenames only
///   (e.g. `*.xcodeproj`).
/// - `cel` — a CEL expression. CEL is **not supported** in the Zig port (no
///   CEL engine); registering a type with this indicator returns
///   `error.CelUnsupported`.
pub const Indicator = union(enum) {
    has_file: []const u8,
    has_glob: []const u8,
    has_subdir_glob: []const u8,
    cel: []const u8,

    /// The raw pattern/expression string carried by the indicator.
    pub fn pattern(self: Indicator) []const u8 {
        return switch (self) {
            inline else => |s| s,
        };
    }

    /// The human-readable form surfaced in `Match.indicator`. A
    /// `has_subdir_glob` renders with a trailing slash (e.g. `MyApp.xcodeproj/`)
    /// to signal a directory marker; a `cel` indicator renders as `cel:<expr>`.
    /// `has_subdir_glob`/`cel` need allocation; the others borrow `pattern()`.
    pub fn display(self: Indicator, arena: std.mem.Allocator) ![]const u8 {
        return switch (self) {
            .has_file, .has_glob => |s| s,
            .has_subdir_glob => |s| try std.fmt.allocPrint(arena, "{s}/", .{s}),
            .cel => |s| try std.fmt.allocPrint(arena, "cel:{s}", .{s}),
        };
    }
};

/// Couples a matched project type with the indicator that fired. The strings
/// borrow registry-owned memory and are valid as long as the `Registry` lives.
pub const Match = struct {
    type: []const u8,
    indicator: []const u8,
};

/// Describes a kind of project and the indicators that identify it.
///
/// Indicators are evaluated against a directory's own listing (basenames only
/// — no recursion). Any single indicator matching is enough (OR semantics);
/// the first match wins and its `display` is returned.
pub const ProjectType = struct {
    name: []const u8,
    description: []const u8,
    indicators: []const Indicator,
    build_excludes: []const []const u8 = &.{},
    /// Per-indicator display strings, filled in by `Registry.register`. Same
    /// length and order as `indicators`. Empty until registered.
    displays: []const []const u8 = &.{},

    /// Returns the display string of the first indicator that fires against
    /// the listing, or null if none match. `files` are file basenames;
    /// `subdirs` are immediate subdirectory basenames.
    pub fn matchListing(
        self: ProjectType,
        files: []const []const u8,
        subdirs: []const []const u8,
    ) ?[]const u8 {
        for (self.indicators, 0..) |ind, i| {
            const hit = switch (ind) {
                // ASCII case-insensitive exact match — mirrors Go's equalFold.
                .has_file => |want| anyEqlIgnoreCase(files, want),
                // Glob over files only (directories never matched).
                .has_glob => |pat| anyGlob(files, pat),
                // Glob over subdirectories only (files never matched).
                .has_subdir_glob => |pat| anyGlob(subdirs, pat),
                // CEL is unsupported; such types never register, so this is
                // never reached, but keep it total.
                .cel => false,
            };
            if (hit) return self.displays[i];
        }
        return null;
    }
};

fn anyEqlIgnoreCase(names: []const []const u8, want: []const u8) bool {
    for (names) |n| {
        if (std.ascii.eqlIgnoreCase(n, want)) return true;
    }
    return false;
}

fn anyGlob(names: []const []const u8, pat: []const u8) bool {
    for (names) |n| {
        if (globMatch(pat, n)) return true;
    }
    return false;
}

/// Whole-string glob match in the style of Go's `filepath.Match` over a single
/// path component: `*` matches any run of characters, `?` matches one, and
/// `[...]` is a character class (with `[!...]`/`[^...]` negation and `a-z`
/// ranges). There are no path separators in a basename, so `*` spanning `/` is
/// moot. A malformed class falls back to a literal `[`.
pub fn globMatch(pattern: []const u8, name: []const u8) bool {
    // Iterative matcher with backtracking on `*`.
    var p: usize = 0; // index into pattern
    var s: usize = 0; // index into name
    var star_p: ?usize = null; // pattern index just after the last `*`
    var star_s: usize = 0; // name index when the last `*` was taken

    while (s < name.len) {
        if (p < pattern.len) {
            switch (pattern[p]) {
                '*' => {
                    star_p = p + 1;
                    star_s = s;
                    p += 1;
                    continue;
                },
                '?' => {
                    p += 1;
                    s += 1;
                    continue;
                },
                '[' => {
                    if (matchClass(pattern, &p, name[s])) {
                        s += 1;
                        continue;
                    }
                },
                else => {
                    if (pattern[p] == name[s]) {
                        p += 1;
                        s += 1;
                        continue;
                    }
                },
            }
        }
        // Mismatch: backtrack to the last `*` if any.
        if (star_p) |sp| {
            p = sp;
            star_s += 1;
            s = star_s;
            continue;
        }
        return false;
    }

    // Consume trailing `*`s in the pattern.
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

/// Matches a `[...]` class at `pattern[p.*]` against `ch`. On success advances
/// `p.*` past the class and returns true. On a missing close bracket, treats
/// `[` as a literal: advances one char and matches `ch == '['`.
fn matchClass(pattern: []const u8, p: *usize, ch: u8) bool {
    const start = p.*;
    var i = start + 1; // skip '['
    var negate = false;
    if (i < pattern.len and (pattern[i] == '!' or pattern[i] == '^')) {
        negate = true;
        i += 1;
    }
    var matched = false;
    var saw_close = false;
    while (i < pattern.len) {
        if (pattern[i] == ']') {
            saw_close = true;
            i += 1;
            break;
        }
        // Range a-z (when not at the class edges).
        if (i + 2 < pattern.len and pattern[i + 1] == '-' and pattern[i + 2] != ']') {
            const lo = pattern[i];
            const hi = pattern[i + 2];
            if (ch >= lo and ch <= hi) matched = true;
            i += 3;
        } else {
            if (pattern[i] == ch) matched = true;
            i += 1;
        }
    }
    if (!saw_close) {
        // Malformed class: treat '[' literally.
        p.* = start + 1;
        return ch == '[';
    }
    p.* = i;
    return matched != negate;
}

test "globMatch basics" {
    try std.testing.expect(globMatch("*.tf", "main.tf"));
    try std.testing.expect(globMatch("*.tf", "providers.tf"));
    try std.testing.expect(!globMatch("*.sln", "Foo.slnx"));
    try std.testing.expect(globMatch("*.slnx", "Foo.slnx"));
    try std.testing.expect(globMatch("*.xcodeproj", "App.xcodeproj"));
    try std.testing.expect(globMatch("Cargo.toml", "Cargo.toml"));
    try std.testing.expect(!globMatch("Cargo.toml", "cargo.toml")); // glob is case-sensitive
    try std.testing.expect(globMatch("?.tf", "a.tf"));
    try std.testing.expect(globMatch("[abc].txt", "b.txt"));
    try std.testing.expect(!globMatch("[!abc].txt", "b.txt"));
}
