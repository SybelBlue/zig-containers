const siv = @import("siv.zig");

pub const StaticIndexVector = siv.StaticIndexVector;
pub const IndexError = siv.IndexError;

pub fn bufferedPrint() !void {
    @import("std").debug.print(
        "hello from {s}\n",
        .{@src().module},
    );
}
