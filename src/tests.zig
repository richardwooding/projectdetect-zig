//! Integration test suite — ports the Go/Rust assertions.

const std = @import("std");
const pd = @import("projectdetect.zig");
const discovery = @import("discovery.zig");

const ta = std.testing.allocator;

/// A throwaway directory tree rooted at a cwd-relative path.
const Tree = struct {
    tmp: std.testing.TmpDir,
    threaded: std.Io.Threaded,
    root: []u8,

    fn init() !Tree {
        const tmp = std.testing.tmpDir(.{});
        // std.testing.tmpDir creates `.zig-cache/tmp/<sub_path>` relative to
        // the cwd; build that relative path (realpath was removed in 0.16).
        const root = try std.fmt.allocPrint(ta, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
        return .{ .tmp = tmp, .threaded = std.Io.Threaded.init(ta, .{}), .root = root };
    }

    fn deinit(self: *Tree) void {
        ta.free(self.root);
        self.tmp.cleanup();
        self.threaded.deinit();
    }

    fn touch(self: *Tree, rel: []const u8) !void {
        const io = self.threaded.io();
        if (std.fs.path.dirname(rel)) |d| try self.tmp.dir.createDirPath(io, d);
        var f = try self.tmp.dir.createFile(io, rel, .{});
        f.close(io);
    }

    fn mkdir(self: *Tree, rel: []const u8) !void {
        try self.tmp.dir.createDirPath(self.threaded.io(), rel);
    }

    fn write(self: *Tree, rel: []const u8, bytes: []const u8) !void {
        const io = self.threaded.io();
        if (std.fs.path.dirname(rel)) |d| try self.tmp.dir.createDirPath(io, d);
        try self.tmp.dir.writeFile(io, .{ .sub_path = rel, .data = bytes });
    }

    /// Path of `rel` within the tree (cwd-relative; caller frees).
    fn path(self: *Tree, rel: []const u8) ![]u8 {
        return std.fs.path.join(ta, &.{ self.root, rel });
    }
};

fn expectTypes(matches: []const pd.Match, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, matches.len);
    for (matches, expected) |m, e| try std.testing.expectEqualStrings(e, m.type);
}

// --- detect -----------------------------------------------------------------

test "detect single type via has_file" {
    const cases = [_]struct { f: []const u8, t: []const u8 }{
        .{ .f = "go.mod", .t = "go" },
        .{ .f = "package.json", .t = "node" },
        .{ .f = "Cargo.toml", .t = "rust" },
        .{ .f = "pyproject.toml", .t = "python" },
        .{ .f = "requirements.txt", .t = "python" },
        .{ .f = "Gemfile", .t = "ruby" },
        .{ .f = "pom.xml", .t = "java-maven" },
        .{ .f = "build.gradle.kts", .t = "java-gradle" },
        .{ .f = "compose.yaml", .t = "docker-compose" },
        .{ .f = "Package.swift", .t = "swift" },
        .{ .f = "composer.json", .t = "php" },
        .{ .f = "build.sbt", .t = "scala-sbt" },
        .{ .f = "build.mill", .t = "scala-mill" },
        .{ .f = "CMakeLists.txt", .t = "cmake" },
        .{ .f = "configure.ac", .t = "autotools" },
        .{ .f = "DESCRIPTION", .t = "r" },
        .{ .f = "build.zig", .t = "zig" },
        .{ .f = "cpanfile", .t = "perl" },
        .{ .f = "hugo.toml", .t = "hugo" },
        .{ .f = "_config.yml", .t = "jekyll" },
        .{ .f = ".eleventy.js", .t = "eleventy" },
        .{ .f = "astro.config.mjs", .t = "astro" },
        .{ .f = "gatsby-config.js", .t = "gatsby" },
        .{ .f = "mkdocs.yml", .t = "mkdocs" },
        .{ .f = "docusaurus.config.js", .t = "docusaurus" },
        .{ .f = "pelicanconf.py", .t = "pelican" },
    };
    var reg = try pd.Registry.initWithBuiltins(ta);
    defer reg.deinit();
    for (cases) |c| {
        var tree = try Tree.init();
        defer tree.deinit();
        try tree.touch(c.f);
        const m = try reg.detect(ta, tree.root);
        defer ta.free(m);
        try std.testing.expectEqual(@as(usize, 1), m.len);
        try std.testing.expectEqualStrings(c.t, m[0].type);
        try std.testing.expectEqualStrings(c.f, m[0].indicator); // has_file display == filename
    }
}

test "detect glob indicators (type only)" {
    const cases = [_]struct { f: []const u8, t: []const u8 }{
        .{ .f = "main.tf", .t = "terraform" },
        .{ .f = "App.csproj", .t = "dotnet" },
        .{ .f = "App.sln", .t = "dotnet" },
        .{ .f = "App.slnx", .t = "dotnet" },
        .{ .f = "global.json", .t = "dotnet" },
        .{ .f = "NuGet.Config", .t = "dotnet" }, // case-insensitive has_file
        .{ .f = "Alamofire.podspec", .t = "swift" },
        .{ .f = "analysis.Rproj", .t = "r" },
        .{ .f = "toolbox.prj", .t = "matlab" },
    };
    var reg = try pd.Registry.initWithBuiltins(ta);
    defer reg.deinit();
    for (cases) |c| {
        var tree = try Tree.init();
        defer tree.deinit();
        try tree.touch(c.f);
        const m = try reg.detect(ta, tree.root);
        defer ta.free(m);
        try std.testing.expectEqual(@as(usize, 1), m.len);
        try std.testing.expectEqualStrings(c.t, m[0].type);
    }
}

test "detect Xcode subdir-only bundles" {
    var reg = try pd.Registry.initWithBuiltins(ta);
    defer reg.deinit();
    const cases = [_]struct { dir: []const u8, ind: []const u8 }{
        .{ .dir = "App.xcodeproj", .ind = "*.xcodeproj/" },
        .{ .dir = "App.xcworkspace", .ind = "*.xcworkspace/" },
    };
    for (cases) |c| {
        var tree = try Tree.init();
        defer tree.deinit();
        try tree.mkdir(c.dir);
        try tree.touch("README.md");
        const m = try reg.detect(ta, tree.root);
        defer ta.free(m);
        try std.testing.expectEqual(@as(usize, 1), m.len);
        try std.testing.expectEqualStrings("swift", m[0].type);
        try std.testing.expectEqualStrings(c.ind, m[0].indicator);
    }
}

test "detect subdir glob ignores a same-named file" {
    var reg = try pd.Registry.initWithBuiltins(ta);
    defer reg.deinit();
    var tree = try Tree.init();
    defer tree.deinit();
    try tree.touch("x.xcodeproj"); // a FILE, not a bundle dir
    const m = try reg.detect(ta, tree.root);
    defer ta.free(m);
    try std.testing.expectEqual(@as(usize, 0), m.len);
}

test "detect multiple types" {
    var reg = try pd.Registry.initWithBuiltins(ta);
    defer reg.deinit();
    var tree = try Tree.init();
    defer tree.deinit();
    try tree.touch("go.mod");
    try tree.touch("docker-compose.yml");
    const m = try reg.detect(ta, tree.root);
    defer ta.free(m);
    try expectTypes(m, &.{ "docker-compose", "go" });
}

test "detect dotnet .slnx-only root" {
    var reg = try pd.Registry.initWithBuiltins(ta);
    defer reg.deinit();
    var tree = try Tree.init();
    defer tree.deinit();
    try tree.touch("App.slnx");
    try tree.touch("Directory.Build.props");
    const m = try reg.detect(ta, tree.root);
    defer ta.free(m);
    try std.testing.expectEqual(@as(usize, 1), m.len);
    try std.testing.expectEqualStrings("dotnet", m[0].type);
}

test "detect no match" {
    var reg = try pd.Registry.initWithBuiltins(ta);
    defer reg.deinit();
    var tree = try Tree.init();
    defer tree.deinit();
    try tree.touch("random.txt");
    const m = try reg.detect(ta, tree.root);
    defer ta.free(m);
    try std.testing.expectEqual(@as(usize, 0), m.len);
}

test "registry has >= 28 builtins" {
    var reg = try pd.Registry.initWithBuiltins(ta);
    defer reg.deinit();
    try std.testing.expect(reg.projectTypes().len >= 28);
}

// --- find -------------------------------------------------------------------

test "find stops at project root (non-nested)" {
    var reg = try pd.Registry.initWithBuiltins(ta);
    defer reg.deinit();
    var tree = try Tree.init();
    defer tree.deinit();
    try tree.touch("a/go.mod");
    try tree.touch("a/inner/go.mod");

    var res = try reg.find(ta, tree.root, .{});
    defer res.deinit();
    try std.testing.expectEqual(@as(usize, 1), res.count);
    const want = try tree.path("a");
    defer ta.free(want);
    try std.testing.expectEqualStrings(want, res.projects[0].path);
}

test "find nested surfaces sub-projects" {
    var reg = try pd.Registry.initWithBuiltins(ta);
    defer reg.deinit();
    var tree = try Tree.init();
    defer tree.deinit();
    try tree.touch("a/go.mod");
    try tree.touch("a/inner/Cargo.toml");

    var res = try reg.find(ta, tree.root, .{ .nested = true });
    defer res.deinit();
    try std.testing.expectEqual(@as(usize, 2), res.count);
}

test "find types filter" {
    var reg = try pd.Registry.initWithBuiltins(ta);
    defer reg.deinit();
    var tree = try Tree.init();
    defer tree.deinit();
    try tree.touch("go-app/go.mod");
    try tree.touch("rust-app/Cargo.toml");
    try tree.touch("node-app/package.json");

    var res = try reg.find(ta, tree.root, .{ .types = &.{ "go", "rust" } });
    defer res.deinit();
    try std.testing.expectEqual(@as(usize, 2), res.count);
}

test "find excludes prune subtrees" {
    var reg = try pd.Registry.initWithBuiltins(ta);
    defer reg.deinit();
    var tree = try Tree.init();
    defer tree.deinit();
    try tree.touch("real/go.mod");
    try tree.touch("node_modules/vendored/go.mod");

    var res = try reg.find(ta, tree.root, .{ .excludes = &.{"node_modules"} });
    defer res.deinit();
    try std.testing.expectEqual(@as(usize, 1), res.count);
    const want = try tree.path("real");
    defer ta.free(want);
    try std.testing.expectEqualStrings(want, res.projects[0].path);
}

test "find respects root gitignore" {
    var reg = try pd.Registry.initWithBuiltins(ta);
    defer reg.deinit();
    var tree = try Tree.init();
    defer tree.deinit();
    try tree.touch("kept/go.mod");
    try tree.touch("ignored/go.mod");
    try tree.write(".gitignore", "ignored/\n");

    var res = try reg.find(ta, tree.root, .{ .respect_gitignore = true });
    defer res.deinit();
    try std.testing.expectEqual(@as(usize, 1), res.count);
    const want = try tree.path("kept");
    defer ta.free(want);
    try std.testing.expectEqualStrings(want, res.projects[0].path);
}

test "collectBuildExcludes unions detected types" {
    var reg = try pd.Registry.initWithBuiltins(ta);
    defer reg.deinit();
    var tree = try Tree.init();
    defer tree.deinit();
    try tree.touch("g/go.mod");
    try tree.touch("n/package.json");

    const ex = try reg.collectBuildExcludes(ta, tree.root);
    defer ta.free(ex);
    try std.testing.expect(contains(ex, "vendor"));
    try std.testing.expect(contains(ex, "node_modules"));
}

fn contains(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |h| if (std.mem.eql(u8, h, needle)) return true;
    return false;
}

// --- resolver ---------------------------------------------------------------

test "resolver finds nearest project" {
    var reg = try pd.Registry.initWithBuiltins(ta);
    defer reg.deinit();
    var tree = try Tree.init();
    defer tree.deinit();
    try tree.touch("proj/go.mod");
    try tree.touch("proj/cmd/main.go");
    try tree.touch("proj/inner/Cargo.toml");
    try tree.touch("proj/inner/src/lib.rs");

    var r = pd.Resolver.init(ta, tree.root, &reg);
    defer r.deinit();

    const main_go = try tree.path("proj/cmd/main.go");
    defer ta.free(main_go);
    try expectTypes(try r.resolve(main_go), &.{"go"});

    const lib_rs = try tree.path("proj/inner/src/lib.rs");
    defer ta.free(lib_rs);
    try expectTypes(try r.resolve(lib_rs), &.{"rust"});
}

test "resolver returns empty when no project" {
    var reg = try pd.Registry.initWithBuiltins(ta);
    defer reg.deinit();
    var tree = try Tree.init();
    defer tree.deinit();
    try tree.touch("loose.txt");

    var r = pd.Resolver.init(ta, tree.root, &reg);
    defer r.deinit();
    const loose = try tree.path("loose.txt");
    defer ta.free(loose);
    try std.testing.expectEqual(@as(usize, 0), (try r.resolve(loose)).len);
}

test "resolveForPath finds nearest and polyglot" {
    var reg = try pd.Registry.initWithBuiltins(ta);
    defer reg.deinit();
    var tree = try Tree.init();
    defer tree.deinit();
    try tree.touch("go.mod");
    try tree.touch("docker-compose.yml");
    try tree.touch("cmd/main.go");

    const main_go = try tree.path("cmd/main.go");
    defer ta.free(main_go);
    const got = try reg.resolveForPath(ta, main_go);
    try std.testing.expect(got != null);
    defer ta.free(got.?.matches);
    try std.testing.expectEqualStrings(tree.root, got.?.path);
    try expectTypes(got.?.matches, &.{ "docker-compose", "go" });
}

test "resolveForPath returns null when no ancestor matches" {
    var reg = try pd.Registry.initWithBuiltins(ta);
    defer reg.deinit();
    var tree = try Tree.init();
    defer tree.deinit();
    try tree.touch("loose.txt");
    const loose = try tree.path("loose.txt");
    defer ta.free(loose);
    try std.testing.expect((try reg.resolveForPath(ta, loose)) == null);
}

test "resolver respects its custom registry" {
    var reg = pd.Registry.init(ta);
    defer reg.deinit();
    try reg.register(.{
        .name = "custom",
        .description = "Custom",
        .indicators = &.{.{ .has_file = "custom.marker" }},
    });

    var tree = try Tree.init();
    defer tree.deinit();
    try tree.touch("custom.marker");
    try tree.touch("go.mod"); // would match built-in `go` in a full registry
    try tree.touch("sub/file.txt");

    var r = pd.Resolver.init(ta, tree.root, &reg);
    defer r.deinit();
    const f = try tree.path("sub/file.txt");
    defer ta.free(f);
    try expectTypes(try r.resolve(f), &.{"custom"});
}

// --- config -----------------------------------------------------------------

fn detects(reg: *const pd.Registry, path: []const u8, want: []const u8) !bool {
    const m = try reg.detect(ta, path);
    defer ta.free(m);
    for (m) |x| if (std.mem.eql(u8, x.type, want)) return true;
    return false;
}

test "config mixed indicators" {
    var tree = try Tree.init();
    defer tree.deinit();
    try tree.write("types.yaml",
        \\project_types:
        \\  - name: helm-chart
        \\    indicators:
        \\      - has_file: Chart.yaml
        \\  - name: tf-stack
        \\    indicators:
        \\      - has_glob: "*.tf"
    );
    const cfg = try tree.path("types.yaml");
    defer ta.free(cfg);

    var reg = pd.Registry.init(ta);
    defer reg.deinit();
    try std.testing.expectEqual(@as(usize, 2), try pd.loadFromFile(&reg, cfg));

    var chart = try Tree.init();
    defer chart.deinit();
    try chart.touch("Chart.yaml");
    try std.testing.expect(try detects(&reg, chart.root, "helm-chart"));

    var tf = try Tree.init();
    defer tf.deinit();
    try tf.touch("main.tf");
    try std.testing.expect(try detects(&reg, tf.root, "tf-stack"));
}

test "config has_subdir_glob indicator" {
    var tree = try Tree.init();
    defer tree.deinit();
    try tree.write("types.yaml",
        \\project_types:
        \\  - name: xcode-app
        \\    indicators:
        \\      - has_subdir_glob: "*.xcodeproj"
    );
    const cfg = try tree.path("types.yaml");
    defer ta.free(cfg);

    var reg = pd.Registry.init(ta);
    defer reg.deinit();
    try std.testing.expectEqual(@as(usize, 1), try pd.loadFromFile(&reg, cfg));

    var bundle = try Tree.init();
    defer bundle.deinit();
    try bundle.mkdir("App.xcodeproj");
    try std.testing.expect(try detects(&reg, bundle.root, "xcode-app"));

    var as_file = try Tree.init();
    defer as_file.deinit();
    try as_file.touch("App.xcodeproj");
    try std.testing.expect(!try detects(&reg, as_file.root, "xcode-app"));
}

test "config missing indicators errors" {
    var tree = try Tree.init();
    defer tree.deinit();
    try tree.write("types.yaml", "project_types:\n  - name: broken\n");
    const cfg = try tree.path("types.yaml");
    defer ta.free(cfg);

    var reg = pd.Registry.init(ta);
    defer reg.deinit();
    try std.testing.expectError(pd.ConfigError.IndicatorsRequired, pd.loadFromFile(&reg, cfg));
}

test "config cel indicator is unsupported" {
    var tree = try Tree.init();
    defer tree.deinit();
    try tree.write("types.yaml",
        \\project_types:
        \\  - name: c
        \\    indicators:
        \\      - cel: '"x" in files'
    );
    const cfg = try tree.path("types.yaml");
    defer ta.free(cfg);

    var reg = pd.Registry.init(ta);
    defer reg.deinit();
    try std.testing.expectError(error.CelUnsupported, pd.loadFromFile(&reg, cfg));
}

// --- discovery --------------------------------------------------------------

test "discovery entriesFrom order and omission" {
    const both = try discovery.entriesFrom(ta, "/home/u/.config", "/work/proj");
    defer {
        for (both) |e| ta.free(e.path);
        ta.free(both);
    }
    try std.testing.expectEqual(@as(usize, 2), both.len);
    try std.testing.expectEqualStrings("user-wide", both[0].scope);
    try std.testing.expectEqualStrings("per-project", both[1].scope);

    const none = try discovery.entriesFrom(ta, null, null);
    defer ta.free(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);
}

test "discovery loadPaths layers both configs" {
    var tree = try Tree.init();
    defer tree.deinit();
    try tree.write("user/project-types.yaml",
        \\project_types:
        \\  - name: user-wide-app
        \\    indicators:
        \\      - has_file: user.marker
    );
    try tree.write("proj/project-types.yaml",
        \\project_types:
        \\  - name: project-local-app
        \\    indicators:
        \\      - has_file: local.marker
    );
    const user = try tree.path("user/project-types.yaml");
    defer ta.free(user);
    const proj = try tree.path("proj/project-types.yaml");
    defer ta.free(proj);

    var reg = pd.Registry.init(ta);
    defer reg.deinit();
    const n = try discovery.loadPaths(&reg, &.{ user, proj });
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(@as(usize, 2), reg.projectTypes().len);
}

test "discovery loadPaths skips missing and surfaces bad" {
    var reg = pd.Registry.init(ta);
    defer reg.deinit();
    try std.testing.expectEqual(@as(usize, 0), try discovery.loadPaths(&reg, &.{"/definitely/not/here/project-types.yaml"}));

    var tree = try Tree.init();
    defer tree.deinit();
    try tree.write("bad/project-types.yaml", "project_types:\n  - name: broken\n");
    const bad = try tree.path("bad/project-types.yaml");
    defer ta.free(bad);
    try std.testing.expectError(pd.ConfigError.IndicatorsRequired, discovery.loadPaths(&reg, &.{bad}));
}
