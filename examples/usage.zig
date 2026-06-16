//! Detect and print the project type(s) of the current directory.
//!
//! ```sh
//! zig build example
//! ```

const std = @import("std");
const projectdetect = @import("projectdetect");

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var reg = try projectdetect.Registry.initWithBuiltins(gpa);
    defer reg.deinit();

    const matches = try reg.detect(gpa, ".");
    defer gpa.free(matches);

    if (matches.len == 0) {
        std.debug.print(". -> (no project type detected)\n", .{});
        return;
    }
    for (matches) |m| {
        std.debug.print(". -> {s} (via {s})\n", .{ m.type, m.indicator });
    }
}
