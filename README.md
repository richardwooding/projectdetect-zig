# projectdetect

[![CI](https://github.com/richardwooding/projectdetect-zig/actions/workflows/ci.yml/badge.svg)](https://github.com/richardwooding/projectdetect-zig/actions/workflows/ci.yml)
[![Zig 0.16](https://img.shields.io/badge/Zig-0.16.0-f7a41d.svg)](https://ziglang.org/)

Detect what kind of project a directory is — **Zig 0.16.0**, zero third-party dependencies.

**Website:** [richardwooding.github.io/projectdetect-zig](https://richardwooding.github.io/projectdetect-zig/)

A Zig port of the Go library [`github.com/richardwooding/projectdetect`](https://github.com/richardwooding/projectdetect).

`projectdetect` answers a few questions over a filesystem:

- **`detect(dir)`** — what project type(s) does *this* directory look like? (a directory can match several at once — a Go module that also ships a `docker-compose.yml` matches both)
- **`find(root, opts)`** — walk a tree and report every project root under it.
- **`resolveForPath(file)`** / **`Resolver`** — which project does a given file belong to (nearest-ancestor walk-up)?
- **`collectBuildExcludes(root)`** — the union of canonical build-artefact dirs under a tree.

A type matches by **indicators**: an exact filename (`has_file`, case-insensitive), a file-basename glob (`has_glob`), or a subdirectory-basename glob (`has_subdir_glob`, for directory markers like `*.xcodeproj`).

## Built-in types

`go`, `node`, `rust`, `python`, `ruby`, `java-maven`, `java-gradle`, `dotnet`, `terraform`, `docker-compose`, the language / build-tool ecosystems `swift`, `php`, `scala-sbt`, `scala-mill`, `cmake`, `autotools`, `r`, `zig`, `perl`, `matlab`, and the static-site generators `hugo`, `jekyll`, `eleventy`, `astro`, `gatsby`, `mkdocs`, `docusaurus`, `pelican` (28 total). `dotnet` covers `*.csproj` / `*.fsproj` / `*.vbproj` / `*.sln` / `*.slnx` plus `global.json` / `Directory.Build.props` / `Directory.Packages.props` / `nuget.config`. `swift` matches `Package.swift` (SwiftPM), `*.podspec` (CocoaPods), and the `*.xcodeproj` / `*.xcworkspace` bundles (Xcode); `cmake` matches `CMakeLists.txt` (C/C++).

Each type also declares its canonical build-artefact dirs (`bin`/`obj`, `node_modules`, `target`, …) — see `collectBuildExcludes`.

## Install

Add it to your `build.zig.zon`:

```sh
zig fetch --save git+https://github.com/richardwooding/projectdetect-zig
```

Then in `build.zig`:

```zig
const pd = b.dependency("projectdetect", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("projectdetect", pd.module("projectdetect"));
```

## Usage

```zig
const std = @import("std");
const projectdetect = @import("projectdetect");

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var reg = try projectdetect.Registry.initWithBuiltins(gpa);
    defer reg.deinit();

    // What is this directory?
    const matches = try reg.detect(gpa, ".");
    defer gpa.free(matches);
    for (matches) |m| std.debug.print("{s} (via {s})\n", .{ m.type, m.indicator });

    // Recursively find project roots.
    var result = try reg.find(gpa, "/path/to/code", .{});
    defer result.deinit();
    for (result.projects) |p| std.debug.print("{s}\n", .{p.path});
}
```

`zig build example` runs a small demo against the current directory.

## Custom types (YAML)

Load extra project types from YAML — `has_file`, `has_glob`, or `has_subdir_glob`:

```yaml
project_types:
  - name: my-stack
    indicators:
      - has_file: "my.config"
      - has_glob: "*.mytool"
      - has_subdir_glob: "*.bundle"
```

```zig
const n = try projectdetect.loadFromFile(&reg, "project-types.yaml");
```

The config loader ships a small, zero-dependency YAML reader covering exactly this schema.

## Differences from the Go/Rust ports

This is a faithful port of the detection model — same 28 built-ins, the same files-vs-subdirs indicator split, ASCII-case-insensitive `has_file`, and the same nested / excludes / root-`.gitignore` / timeout `find` behaviour. Two deliberate differences, driven by the Zig ecosystem:

- **No CEL indicators.** Zig has no CEL engine, so the `cel:` indicator is unsupported; registering one returns `error.CelUnsupported`. All built-ins and the other three indicator kinds work normally.
- **User-wide config discovery is limited.** Per-project discovery (`./.file-search-on/project-types.yaml`) works. Zig 0.16's standard library routes the process environment through its new `Io` interface and exposes no stable public env-var accessor, so the *user-wide* config-dir layer is omitted from automatic discovery; pass an explicit directory via `entriesFrom` if you need it.

## License

MIT © Richard Wooding
