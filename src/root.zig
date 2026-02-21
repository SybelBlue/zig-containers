const siv = @import("siv.zig");
const indexmap = @import("indexmap.zig");

pub const StaticIndexVector = siv.StaticIndexVector;
pub const IndexError = siv.IndexError;

pub const IndexMap = @import("indexmap.zig");

pub fn bufferedPrint() !void {
    @import("std").debug.print(
        "hello from {s}\n",
        .{@src().module},
    );
}
