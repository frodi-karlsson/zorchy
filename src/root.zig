//! By convention, root.zig is the root source file when making a library.
const std = @import("std");
pub const task = @import("./task.zig");
pub const workflow = @import("./workflow.zig");
pub const json = @import("./json.zig");

test "run all tests" {
    std.testing.refAllDecls(@This());
}
