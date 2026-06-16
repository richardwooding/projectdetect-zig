//! YAML configuration for user-defined project types.
//!
//! Schema (matching the Go/Rust libraries):
//! ```yaml
//! project_types:
//!   - name: my-app
//!     description: Internal Foo app
//!     indicators:
//!       - has_file: Chart.yaml
//!       - has_glob: "*.tf"
//!       - has_subdir_glob: "*.xcodeproj"
//! ```
//! `cel:` indicators are accepted by the parser but rejected at registration
//! with `error.CelUnsupported` (the Zig port has no CEL engine).

const std = @import("std");
const Allocator = std.mem.Allocator;
const yaml = @import("yaml_min.zig");

const registry = @import("registry.zig");
const types = @import("types.zig");
const Registry = registry.Registry;
const Indicator = types.Indicator;
const ProjectType = types.ProjectType;

/// Validation errors for a config entry.
pub const ConfigError = error{
    NameRequired,
    IndicatorsRequired,
    EmptyIndicator,
};

/// Parses `path` as YAML and registers every project type it declares into
/// `reg`. Validates each entry (non-empty name + at least one indicator).
/// Returns the number of types registered. Strings are copied into the
/// registry's arena, so the file's contents need not outlive this call.
pub fn loadFromFile(reg: *Registry, path: []const u8) !usize {
    const gpa = reg.gpa;
    const data = try readFile(gpa, path);
    defer gpa.free(data);

    var parse_arena = std.heap.ArenaAllocator.init(gpa);
    defer parse_arena.deinit();
    const root = try yaml.parse(parse_arena.allocator(), data);

    const pts = root.get("project_types") orelse return 0;
    const list = pts.asList() orelse return 0;

    const ra = reg.arena.allocator();
    var count: usize = 0;
    for (list) |entry| {
        const name = scalarOr(entry, "name", "");
        if (name.len == 0) return ConfigError.NameRequired;
        const desc = scalarOr(entry, "description", "");

        const inds_val = entry.get("indicators") orelse return ConfigError.IndicatorsRequired;
        const inds_list = inds_val.asList() orelse return ConfigError.IndicatorsRequired;
        if (inds_list.len == 0) return ConfigError.IndicatorsRequired;

        const inds = try ra.alloc(Indicator, inds_list.len);
        for (inds_list, 0..) |iv, j| {
            inds[j] = (try indicatorFrom(ra, iv)) orelse return ConfigError.EmptyIndicator;
        }

        try reg.register(.{
            .name = try ra.dupe(u8, name),
            .description = try ra.dupe(u8, desc),
            .indicators = inds,
        });
        count += 1;
    }
    return count;
}

/// Converts one indicator mapping to an `Indicator`. Precedence when several
/// keys are present: has_file > has_glob > has_subdir_glob > cel. Returns null
/// if none are set.
fn indicatorFrom(ra: Allocator, v: yaml.Value) !?Indicator {
    if (v.get("has_file")) |x| {
        if (x.asScalar()) |s| return Indicator{ .has_file = try ra.dupe(u8, s) };
    }
    if (v.get("has_glob")) |x| {
        if (x.asScalar()) |s| return Indicator{ .has_glob = try ra.dupe(u8, s) };
    }
    if (v.get("has_subdir_glob")) |x| {
        if (x.asScalar()) |s| return Indicator{ .has_subdir_glob = try ra.dupe(u8, s) };
    }
    if (v.get("cel")) |x| {
        if (x.asScalar()) |s| return Indicator{ .cel = try ra.dupe(u8, s) };
    }
    return null;
}

fn scalarOr(v: yaml.Value, key: []const u8, default: []const u8) []const u8 {
    if (v.get(key)) |x| {
        if (x.asScalar()) |s| return s;
    }
    return default;
}

fn readFile(gpa: Allocator, path: []const u8) ![]u8 {
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    return std.Io.Dir.cwd().readFileAlloc(threaded.io(), path, gpa, .unlimited);
}
