//! View layer — server-rendered HTML.
//!
//! Views turn data into a presentation format. Keeping rendering out of the
//! controller keeps handlers thin and makes the markup easy to find. This
//! minimal example uses `allocPrint`; swap in a template engine (e.g. zmpl)
//! when the surface grows.

const std = @import("std");

/// Render the home page. Allocates into the request arena, so the result is
/// freed automatically when the request ends.
pub fn render(arena: std.mem.Allocator, greeting: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena,
        \\<!doctype html>
        \\<html lang="en">
        \\<head><meta charset="utf-8"><title>wing-app</title></head>
        \\<body>
        \\  <h1>{s}</h1>
        \\  <p>Served by the wing web framework.</p>
        \\</body>
        \\</html>
        \\
    , .{greeting});
}
