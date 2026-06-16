//! Layered discovery of project-type config files.
//!
//! Two layers are searched, in precedence order (later overrides earlier): a
//! **user-wide** config under the platform config dir, then a **per-project**
//! config under the current working directory.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const registry = @import("registry.zig");
const config = @import("config.zig");
const Registry = registry.Registry;

/// The config file basename searched in each layer.
pub const CONFIG_FILE_NAME = "project-types.yaml";
/// The user-wide config subdirectory (under the platform config dir).
pub const CONFIG_DIR_NAME = "file-search-on";
/// The per-project config subdirectory (under the current directory).
pub const PER_PROJECT_DIR_NAME = ".file-search-on";

/// One config search location with its scope (`"user-wide"` or
/// `"per-project"`).
pub const DiscoveryEntry = struct {
    scope: []const u8,
    path: []const u8,
};

/// Returns the ordered config search locations (caller owns the returned
/// slice and all paths; free with the same allocator).
///
/// Note (Zig 0.16): the per-project layer is resolved as a path relative to
/// the current directory. The user-wide layer needs the platform config dir,
/// which depends on environment variables; Zig 0.16's standard library exposes
/// no stable public env-var accessor, so the user-wide layer is **omitted**
/// here. Callers that know their config dir can build that entry via
/// `entriesFrom` and load it with `loadFromFile`.
pub fn discoveryEntries(gpa: Allocator) Allocator.Error![]DiscoveryEntry {
    return entriesFrom(gpa, platformConfigDir(), ".");
}

/// Builds the entry list from explicit anchors. Split out so tests can inject
/// anchors without depending on the process environment.
pub fn entriesFrom(
    gpa: Allocator,
    user_config_dir: ?[]const u8,
    cwd: ?[]const u8,
) Allocator.Error![]DiscoveryEntry {
    var out: std.ArrayListUnmanaged(DiscoveryEntry) = .empty;
    errdefer out.deinit(gpa);
    if (user_config_dir) |base| {
        try out.append(gpa, .{
            .scope = "user-wide",
            .path = try std.fs.path.join(gpa, &.{ base, CONFIG_DIR_NAME, CONFIG_FILE_NAME }),
        });
    }
    if (cwd) |base| {
        try out.append(gpa, .{
            .scope = "per-project",
            .path = try std.fs.path.join(gpa, &.{ base, PER_PROJECT_DIR_NAME, CONFIG_FILE_NAME }),
        });
    }
    return out.toOwnedSlice(gpa);
}

/// Loads every config found via `discoveryEntries` into `reg`, in precedence
/// order. Missing files are not errors; a real error (parse / validation /
/// unsupported CEL) halts loading. Returns the total registered.
pub fn loadDiscovered(reg: *Registry, gpa: Allocator) !usize {
    const entries = try discoveryEntries(gpa);
    defer {
        for (entries) |e| gpa.free(e.path);
        gpa.free(entries);
    }
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer paths.deinit(gpa);
    for (entries) |e| try paths.append(gpa, e.path);
    return loadPaths(reg, paths.items);
}

/// Loads each existing path in order, summing the registered counts. Missing
/// paths are skipped.
pub fn loadPaths(reg: *Registry, paths: []const []const u8) !usize {
    var threaded = Io.Threaded.init(reg.gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var total: usize = 0;
    for (paths) |path| {
        if (fileExists(io, path)) total += try config.loadFromFile(reg, path);
    }
    return total;
}

fn fileExists(io: Io, path: []const u8) bool {
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// The platform user-config directory (Go's `os.UserConfigDir`), or null.
///
/// Zig 0.16's standard library routes the process environment through the
/// `Io` interface and exposes no stable public env-var accessor, so this
/// returns null on this version — see the note on `discoveryEntries`. The
/// `builtin` import is retained for when a stable accessor lands.
fn platformConfigDir() ?[]const u8 {
    _ = builtin;
    return null;
}
