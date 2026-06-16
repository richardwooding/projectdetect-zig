//! The built-in project types, ported 1:1 from the Go/Rust libraries.

const types = @import("types.zig");
const Indicator = types.Indicator;
const ProjectType = types.ProjectType;

fn file(comptime s: []const u8) Indicator {
    return .{ .has_file = s };
}
fn glob(comptime s: []const u8) Indicator {
    return .{ .has_glob = s };
}
fn subdir(comptime s: []const u8) Indicator {
    return .{ .has_subdir_glob = s };
}

/// All built-in project types (28). Static, comptime-known data; the strings
/// are literals with `'static` lifetime, so a `Registry` can borrow them
/// without copying.
pub const all = [_]ProjectType{
    .{ .name = "go", .description = "Go module (go.mod)", .indicators = &.{file("go.mod")}, .build_excludes = &.{"vendor"} },
    .{ .name = "node", .description = "Node.js / npm / yarn / pnpm (package.json)", .indicators = &.{file("package.json")}, .build_excludes = &.{"node_modules"} },
    .{ .name = "rust", .description = "Rust crate (Cargo.toml)", .indicators = &.{file("Cargo.toml")}, .build_excludes = &.{"target"} },
    .{
        .name = "python",
        .description = "Python project (pyproject.toml / requirements.txt / Pipfile / setup.py / setup.cfg)",
        .indicators = &.{ file("pyproject.toml"), file("requirements.txt"), file("Pipfile"), file("setup.py"), file("setup.cfg") },
        .build_excludes = &.{ "__pycache__", ".venv", "venv", ".tox", ".pytest_cache", ".mypy_cache", ".ruff_cache" },
    },
    .{ .name = "ruby", .description = "Ruby Bundler project (Gemfile)", .indicators = &.{file("Gemfile")}, .build_excludes = &.{".bundle"} },
    .{ .name = "java-maven", .description = "Java Maven project (pom.xml)", .indicators = &.{file("pom.xml")}, .build_excludes = &.{"target"} },
    .{
        .name = "java-gradle",
        .description = "Java/Kotlin Gradle project (build.gradle / build.gradle.kts)",
        .indicators = &.{ file("build.gradle"), file("build.gradle.kts"), file("settings.gradle"), file("settings.gradle.kts") },
        .build_excludes = &.{ "build", ".gradle" },
    },
    .{
        .name = "dotnet",
        .description = ".NET project (*.csproj / *.fsproj / *.vbproj / *.sln / *.slnx, MSBuild + SDK markers)",
        .indicators = &.{
            glob("*.csproj"),                 glob("*.fsproj"),
            glob("*.vbproj"),                 glob("*.sln"),
            glob("*.slnx"),                   glob("*.slnf"),
            file("global.json"),              file("Directory.Build.props"),
            file("Directory.Packages.props"), file("nuget.config"),
        },
        .build_excludes = &.{ "bin", "obj" },
    },
    .{ .name = "terraform", .description = "Terraform / OpenTofu (*.tf)", .indicators = &.{glob("*.tf")}, .build_excludes = &.{".terraform"} },
    .{
        .name = "docker-compose",
        .description = "Docker Compose stack (docker-compose.{yml,yaml} / compose.{yml,yaml})",
        .indicators = &.{ file("docker-compose.yml"), file("docker-compose.yaml"), file("compose.yml"), file("compose.yaml") },
    },
    .{
        .name = "swift",
        .description = "Swift package (Package.swift) / CocoaPods (*.podspec) / Xcode (*.xcodeproj, *.xcworkspace)",
        .indicators = &.{ file("Package.swift"), glob("*.podspec"), subdir("*.xcodeproj"), subdir("*.xcworkspace") },
        .build_excludes = &.{ ".build", ".swiftpm", "DerivedData" },
    },
    .{ .name = "php", .description = "PHP Composer project (composer.json)", .indicators = &.{file("composer.json")}, .build_excludes = &.{"vendor"} },
    .{ .name = "scala-sbt", .description = "Scala sbt project (build.sbt)", .indicators = &.{file("build.sbt")}, .build_excludes = &.{ "target", ".bsp" } },
    .{ .name = "scala-mill", .description = "Scala Mill project (build.mill / build.sc)", .indicators = &.{ file("build.mill"), file("build.sc") }, .build_excludes = &.{"out"} },
    .{
        .name = "cmake",
        .description = "C/C++ CMake project (CMakeLists.txt)",
        .indicators = &.{file("CMakeLists.txt")},
        .build_excludes = &.{ "build", "cmake-build-debug", "cmake-build-release", "_build" },
    },
    .{
        .name = "autotools",
        .description = "GNU Autotools project (configure.ac / configure.in / Makefile.am)",
        .indicators = &.{ file("configure.ac"), file("configure.in"), file("Makefile.am") },
        .build_excludes = &.{"autom4te.cache"},
    },
    .{ .name = "r", .description = "R package / project (DESCRIPTION / *.Rproj)", .indicators = &.{ file("DESCRIPTION"), glob("*.Rproj") } },
    .{
        .name = "zig",
        .description = "Zig project (build.zig / build.zig.zon)",
        .indicators = &.{ file("build.zig"), file("build.zig.zon") },
        .build_excludes = &.{ "zig-out", "zig-cache", ".zig-cache" },
    },
    .{
        .name = "perl",
        .description = "Perl distribution (Makefile.PL / Build.PL / cpanfile / dist.ini)",
        .indicators = &.{ file("Makefile.PL"), file("Build.PL"), file("cpanfile"), file("dist.ini") },
        .build_excludes = &.{ "blib", "_build" },
    },
    .{ .name = "matlab", .description = "MATLAB project / toolbox (*.prj)", .indicators = &.{glob("*.prj")} },
    .{
        .name = "hugo",
        .description = "Hugo static site (hugo.{toml,yaml,yml})",
        .indicators = &.{ file("hugo.toml"), file("hugo.yaml"), file("hugo.yml") },
        .build_excludes = &.{ "public", "resources" },
    },
    .{
        .name = "jekyll",
        .description = "Jekyll static site (_config.{yml,yaml})",
        .indicators = &.{ file("_config.yml"), file("_config.yaml") },
        .build_excludes = &.{ "_site", ".jekyll-cache", ".sass-cache" },
    },
    .{
        .name = "eleventy",
        .description = "Eleventy static site (.eleventy.js / eleventy.config.*)",
        .indicators = &.{ file(".eleventy.js"), file("eleventy.config.js"), file("eleventy.config.cjs"), file("eleventy.config.mjs"), file("eleventy.config.ts") },
        .build_excludes = &.{"_site"},
    },
    .{
        .name = "astro",
        .description = "Astro static site (astro.config.{mjs,cjs,js,ts})",
        .indicators = &.{ file("astro.config.mjs"), file("astro.config.cjs"), file("astro.config.js"), file("astro.config.ts") },
        .build_excludes = &.{ "dist", ".astro" },
    },
    .{
        .name = "gatsby",
        .description = "Gatsby static site (gatsby-config.{js,ts,mjs})",
        .indicators = &.{ file("gatsby-config.js"), file("gatsby-config.ts"), file("gatsby-config.mjs") },
        .build_excludes = &.{ "public", ".cache", ".gatsby" },
    },
    .{ .name = "mkdocs", .description = "MkDocs documentation site (mkdocs.{yml,yaml})", .indicators = &.{ file("mkdocs.yml"), file("mkdocs.yaml") }, .build_excludes = &.{"site"} },
    .{
        .name = "docusaurus",
        .description = "Docusaurus documentation site (docusaurus.config.{js,ts,mjs})",
        .indicators = &.{ file("docusaurus.config.js"), file("docusaurus.config.ts"), file("docusaurus.config.mjs") },
        .build_excludes = &.{ "build", ".docusaurus" },
    },
    .{ .name = "pelican", .description = "Pelican static site (pelicanconf.py)", .indicators = &.{file("pelicanconf.py")}, .build_excludes = &.{"output"} },
};
