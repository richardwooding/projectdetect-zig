//! The `Registry` of project types plus detection, recursive discovery, and
//! file→project resolution.
//!
//! Filesystem access uses Zig 0.16's `Io` interface. Each top-level call
//! creates a `std.Io.Threaded` internally, so the public API stays free of an
//! `Io` parameter (matching the Go/Rust ports).

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Io = std.Io;
const Clock = Io.Clock;

const types = @import("types.zig");
const builtins = @import("builtins.zig");

pub const Indicator = types.Indicator;
pub const Match = types.Match;
pub const ProjectType = types.ProjectType;

/// Errors specific to registration. `error.CelUnsupported` is returned when a
/// project type carries a `cel` indicator — the Zig port has no CEL engine.
pub const RegisterError = error{CelUnsupported} || Allocator.Error;

/// Holds the registered project types used for detection.
pub const Registry = struct {
    gpa: Allocator,
    arena: ArenaAllocator,
    entries: std.ArrayListUnmanaged(ProjectType) = .empty,

    pub fn init(gpa: Allocator) Registry {
        return .{ .gpa = gpa, .arena = ArenaAllocator.init(gpa), .entries = .empty };
    }

    pub fn initWithBuiltins(gpa: Allocator) RegisterError!Registry {
        var r = Registry.init(gpa);
        errdefer r.deinit();
        for (builtins.all) |pt| try r.register(pt);
        return r;
    }

    pub fn deinit(self: *Registry) void {
        self.entries.deinit(self.gpa);
        self.arena.deinit();
    }

    /// Registers a project type, computing its per-indicator display strings.
    /// Returns `error.CelUnsupported` if any indicator is `cel`. The type's
    /// string slices are borrowed as-is (built-ins pass static data; the
    /// config loader pre-copies into this arena).
    pub fn register(self: *Registry, pt: ProjectType) RegisterError!void {
        for (pt.indicators) |ind| {
            if (ind == .cel) return error.CelUnsupported;
        }
        const a = self.arena.allocator();
        const displays = try a.alloc([]const u8, pt.indicators.len);
        for (pt.indicators, 0..) |ind, i| displays[i] = try ind.display(a);
        var copy = pt;
        copy.displays = displays;
        try self.entries.append(self.gpa, copy);
    }

    /// All registered types in registration order.
    pub fn projectTypes(self: *const Registry) []const ProjectType {
        return self.entries.items;
    }

    fn findType(self: *const Registry, name: []const u8) ?ProjectType {
        for (self.entries.items) |pt| {
            if (std.mem.eql(u8, pt.name, name)) return pt;
        }
        return null;
    }

    /// Inspects a single directory and returns the project types it matches,
    /// sorted by type name. A directory can match several types at once.
    /// Returns an empty slice if nothing matches or the directory can't be
    /// read. The returned slice is owned by `gpa`; the strings inside borrow
    /// the registry.
    pub fn detect(self: *const Registry, gpa: Allocator, path: []const u8) Allocator.Error![]Match {
        var threaded = Io.Threaded.init(gpa, .{});
        defer threaded.deinit();
        return self.detectImpl(threaded.io(), gpa, path);
    }

    fn detectImpl(self: *const Registry, io: Io, gpa: Allocator, path: []const u8) Allocator.Error![]Match {
        var scratch = ArenaAllocator.init(gpa);
        defer scratch.deinit();
        const a = scratch.allocator();

        var files: std.ArrayListUnmanaged([]const u8) = .empty;
        var subdirs: std.ArrayListUnmanaged([]const u8) = .empty;
        readListing(io, a, path, &files, &subdirs) catch {
            return gpa.alloc(Match, 0);
        };

        var out: std.ArrayListUnmanaged(Match) = .empty;
        for (self.entries.items) |pt| {
            if (pt.matchListing(files.items, subdirs.items)) |disp| {
                try out.append(gpa, .{ .type = pt.name, .indicator = disp });
            }
        }
        const slice = try out.toOwnedSlice(gpa);
        std.mem.sort(Match, slice, {}, lessByType);
        return slice;
    }

    /// Walks `root` recursively and returns every directory matching at least
    /// one project type. Honours `opts`. The result owns an arena; call
    /// `result.deinit()`.
    pub fn find(self: *const Registry, gpa: Allocator, root: []const u8, opts: FindOptions) Allocator.Error!FindResult {
        var arena = ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();

        var threaded = Io.Threaded.init(gpa, .{});
        defer threaded.deinit();
        const io = threaded.io();

        const start = Clock.Timestamp.now(io, .awake);
        var ctx = WalkCtx{
            .reg = self,
            .opts = opts,
            .io = io,
            .a = a,
            .projects = .empty,
            .gitignore = if (opts.respect_gitignore) parseRootGitignore(io, a, root) else &.{},
            .start = start,
        };
        try self.walk(&ctx, root, true);

        const projects = try ctx.projects.toOwnedSlice(a);
        const elapsed_ns = start.untilNow(io).raw.toNanoseconds();
        const elapsed_seconds = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
        return .{
            .arena = arena,
            .projects = projects,
            .count = projects.len,
            .cancelled = ctx.cancelled,
            .cancellation_reason = ctx.reason,
            .elapsed_seconds = elapsed_seconds,
        };
    }

    fn walk(self: *const Registry, ctx: *WalkCtx, dir_path: []const u8, is_root: bool) Allocator.Error!void {
        _ = is_root;
        if (ctx.checkCancel()) return;

        var files: std.ArrayListUnmanaged([]const u8) = .empty;
        var subdirs: std.ArrayListUnmanaged([]const u8) = .empty;
        readListing(ctx.io, ctx.a, dir_path, &files, &subdirs) catch return;

        var matched: std.ArrayListUnmanaged(Match) = .empty;
        for (self.entries.items) |pt| {
            if (pt.matchListing(files.items, subdirs.items)) |disp| {
                if (ctx.wantType(pt.name)) {
                    try matched.append(ctx.a, .{ .type = pt.name, .indicator = disp });
                }
            }
        }
        if (matched.items.len > 0) {
            try ctx.projects.append(ctx.a, .{
                .path = try ctx.a.dupe(u8, dir_path),
                .types = try matched.toOwnedSlice(ctx.a),
            });
            if (!ctx.opts.nested) return;
        }

        std.mem.sort([]const u8, subdirs.items, {}, lessByStr);
        for (subdirs.items) |name| {
            if (ctx.excluderSkip(name)) continue;
            if (ctx.gitignoreMatch(name)) continue;
            const child = try std.fs.path.join(ctx.a, &.{ dir_path, name });
            try self.walk(ctx, child, false);
            if (ctx.cancelled) return;
        }
    }

    /// Walks `root` (nested) and returns the sorted, deduped union of
    /// `build_excludes` from every detected type. Returned slice owned by
    /// `gpa`; the strings borrow the registry.
    pub fn collectBuildExcludes(self: *const Registry, gpa: Allocator, root: []const u8) Allocator.Error![][]const u8 {
        var res = try self.find(gpa, root, .{ .nested = true });
        defer res.deinit();

        var set: std.StringArrayHashMapUnmanaged(void) = .empty;
        defer set.deinit(gpa);
        for (res.projects) |p| {
            for (p.types) |m| {
                if (self.findType(m.type)) |pt| {
                    for (pt.build_excludes) |ex| try set.put(gpa, ex, {});
                }
            }
        }
        const out = try gpa.alloc([]const u8, set.count());
        for (set.keys(), 0..) |k, i| out[i] = k;
        std.mem.sort([]const u8, out, {}, lessByStr);
        return out;
    }

    /// One-shot, uncached walk-up: the nearest ancestor of `file_path` that
    /// detects as a project, to the filesystem root. The returned `path`
    /// borrows `file_path`; `matches` is owned by `gpa`.
    pub fn resolveForPath(self: *const Registry, gpa: Allocator, file_path: []const u8) Allocator.Error!?ResolvedPath {
        var threaded = Io.Threaded.init(gpa, .{});
        defer threaded.deinit();
        const io = threaded.io();

        var dir = std.fs.path.dirname(file_path) orelse return null;
        while (true) {
            const m = try self.detectImpl(io, gpa, dir);
            if (m.len > 0) return .{ .path = dir, .matches = m };
            gpa.free(m);
            dir = std.fs.path.dirname(dir) orelse return null;
        }
    }
};

pub const ResolvedPath = struct {
    path: []const u8,
    matches: []const Match,
};

/// Configures `Registry.find`.
pub const FindOptions = struct {
    /// When non-empty, restrict to these type names. Empty = accept all.
    types: []const []const u8 = &.{},
    /// Basename globs that prune directories during the walk.
    excludes: []const []const u8 = &.{},
    /// Keep walking inside a matched root (default: stop at the first match).
    nested: bool = false,
    /// Parse a `.gitignore` at the walk root and prune matching directories.
    respect_gitignore: bool = false,
    /// Optional walk timeout in milliseconds. `null` = no timeout.
    timeout_ms: ?u64 = null,
    /// Optional cooperative cancellation flag.
    cancel: ?*std.atomic.Value(bool) = null,
};

pub const FoundProject = struct {
    path: []const u8,
    types: []const Match,
};

/// The structured output of `Registry.find`. Owns an arena backing `projects`;
/// call `deinit`. The `Match` strings borrow the registry.
pub const FindResult = struct {
    arena: ArenaAllocator,
    projects: []const FoundProject,
    count: usize,
    cancelled: bool = false,
    cancellation_reason: []const u8 = "",
    elapsed_seconds: f64 = 0,

    pub fn deinit(self: *FindResult) void {
        self.arena.deinit();
    }
};

/// A caching file→project resolver bound to a registry and a walk-up root.
/// The walk-up stops at the resolver `root`, the filesystem root, or the first
/// match. Matches/keys live in the resolver's arena; call `deinit`.
pub const Resolver = struct {
    registry: *const Registry,
    arena: ArenaAllocator,
    threaded: Io.Threaded,
    root: []const u8,
    cache: std.StringHashMapUnmanaged([]const Match) = .empty,

    pub fn init(gpa: Allocator, root: []const u8, registry: *const Registry) Resolver {
        return .{
            .registry = registry,
            .arena = ArenaAllocator.init(gpa),
            .threaded = Io.Threaded.init(gpa, .{}),
            .root = root,
        };
    }

    pub fn deinit(self: *Resolver) void {
        self.cache.deinit(self.arena.child_allocator);
        self.arena.deinit();
        self.threaded.deinit();
    }

    /// Walks up from `file_path`'s parent to the nearest project root. Returns
    /// the matched types (borrowed; valid while the resolver lives), or empty.
    pub fn resolve(self: *Resolver, file_path: []const u8) Allocator.Error![]const Match {
        const io = self.threaded.io();
        var dir = std.fs.path.dirname(file_path) orelse return &.{};
        while (true) {
            const m = try self.detectCached(io, dir);
            if (m.len > 0) return m;
            if (std.mem.eql(u8, dir, self.root)) return &.{};
            dir = std.fs.path.dirname(dir) orelse return &.{};
        }
    }

    fn detectCached(self: *Resolver, io: Io, dir: []const u8) Allocator.Error![]const Match {
        if (self.cache.get(dir)) |cached| return cached;
        const a = self.arena.allocator();
        const m = try self.registry.detectImpl(io, a, dir);
        const key = try a.dupe(u8, dir);
        try self.cache.put(self.arena.child_allocator, key, m);
        return m;
    }
};

// --- walk context -----------------------------------------------------------

const WalkCtx = struct {
    reg: *const Registry,
    opts: FindOptions,
    io: Io,
    a: Allocator,
    projects: std.ArrayListUnmanaged(FoundProject),
    gitignore: []const []const u8,
    start: Clock.Timestamp,
    cancelled: bool = false,
    reason: []const u8 = "",

    fn checkCancel(self: *WalkCtx) bool {
        if (self.opts.cancel) |flag| {
            if (flag.load(.monotonic)) {
                self.cancelled = true;
                self.reason = "client_cancel";
                return true;
            }
        }
        if (self.opts.timeout_ms) |t| {
            const elapsed_ms = self.start.untilNow(self.io).raw.toMilliseconds();
            if (elapsed_ms >= 0 and @as(u64, @intCast(elapsed_ms)) >= t) {
                self.cancelled = true;
                self.reason = "timeout";
                return true;
            }
        }
        return false;
    }

    fn wantType(self: *WalkCtx, name: []const u8) bool {
        if (self.opts.types.len == 0) return true;
        for (self.opts.types) |t| {
            if (std.mem.eql(u8, t, name)) return true;
        }
        return false;
    }

    fn excluderSkip(self: *WalkCtx, name: []const u8) bool {
        for (self.opts.excludes) |pat| {
            if (types.globMatch(pat, name)) return true;
        }
        return false;
    }

    fn gitignoreMatch(self: *WalkCtx, name: []const u8) bool {
        for (self.gitignore) |pat| {
            if (types.globMatch(pat, name)) return true;
        }
        return false;
    }
};

// --- helpers ----------------------------------------------------------------

fn lessByType(_: void, a: Match, b: Match) bool {
    return std.mem.lessThan(u8, a.type, b.type);
}

fn lessByStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Reads the immediate children of `path` into `files` / `subdirs` (basenames,
/// allocated with `a`). Symlinks are classified as files (not followed), like
/// Go's `DirEntry.IsDir`. `path` may be relative (to cwd) or absolute.
fn readListing(
    io: Io,
    a: Allocator,
    path: []const u8,
    files: *std.ArrayListUnmanaged([]const u8),
    subdirs: *std.ArrayListUnmanaged([]const u8),
) !void {
    var dir = try Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const name = try a.dupe(u8, entry.name);
        if (entry.kind == .directory) {
            try subdirs.append(a, name);
        } else {
            try files.append(a, name);
        }
    }
}

/// Parses `root/.gitignore` into basename patterns (trailing/leading `/`
/// stripped; comments/blanks skipped). Only the root file is consulted.
/// Returns an empty list on any error.
fn parseRootGitignore(io: Io, a: Allocator, root: []const u8) []const []const u8 {
    const gi_path = std.fs.path.join(a, &.{ root, ".gitignore" }) catch return &.{};
    const data = Io.Dir.cwd().readFileAlloc(io, gi_path, a, .unlimited) catch return &.{};

    var patterns: std.ArrayListUnmanaged([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        var line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '/') line = line[1..];
        if (line.len > 0 and line[line.len - 1] == '/') line = line[0 .. line.len - 1];
        if (line.len == 0) continue;
        patterns.append(a, line) catch return patterns.items;
    }
    return patterns.items;
}
