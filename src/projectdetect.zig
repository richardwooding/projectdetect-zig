//! projectdetect — detect what kind of project a directory is (Go module,
//! Node app, Rust crate, Xcode project, …) by canonical indicator files, with
//! recursive discovery, file→project resolution, and YAML custom types.
//!
//! A Zig port of the Go library
//! `github.com/richardwooding/projectdetect`. CEL indicators are not supported
//! in this port (no CEL engine); a `cel:` indicator yields `error.CelUnsupported`.
//!
//! ## Quick start
//! ```zig
//! var reg = try projectdetect.Registry.initWithBuiltins(gpa);
//! defer reg.deinit();
//! const matches = try reg.detect(gpa, ".");
//! defer gpa.free(matches);
//! for (matches) |m| std.debug.print("{s} (via {s})\n", .{ m.type, m.indicator });
//! ```

const std = @import("std");

const registry = @import("registry.zig");
const types = @import("types.zig");
const config = @import("config.zig");
const discovery = @import("discovery.zig");

// Core types and the registry.
pub const Registry = registry.Registry;
pub const RegisterError = registry.RegisterError;
pub const Indicator = types.Indicator;
pub const Match = types.Match;
pub const ProjectType = types.ProjectType;

// Discovery / find.
pub const FindOptions = registry.FindOptions;
pub const FindResult = registry.FindResult;
pub const FoundProject = registry.FoundProject;
pub const Resolver = registry.Resolver;
pub const ResolvedPath = registry.ResolvedPath;

// Glob matcher, exposed for reuse/testing.
pub const globMatch = types.globMatch;

// YAML config + layered discovery.
pub const loadFromFile = config.loadFromFile;
pub const ConfigError = config.ConfigError;
pub const loadDiscovered = discovery.loadDiscovered;
pub const discoveryEntries = discovery.discoveryEntries;
pub const DiscoveryEntry = discovery.DiscoveryEntry;
pub const CONFIG_FILE_NAME = discovery.CONFIG_FILE_NAME;
pub const CONFIG_DIR_NAME = discovery.CONFIG_DIR_NAME;
pub const PER_PROJECT_DIR_NAME = discovery.PER_PROJECT_DIR_NAME;

test {
    // Pull in unit tests from the implementation modules and the suite.
    _ = types;
    _ = registry;
    _ = config;
    _ = discovery;
    _ = @import("yaml_min.zig");
    _ = @import("tests.zig");
}
