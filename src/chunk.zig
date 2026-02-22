const std = @import("std");
const mem = std.mem;

pub fn Chunk(comptime A: type, comptime n: usize) type {
    return struct {
        const Self = @This();

        left: usize = 0,
        right: usize = 0,
        data: [n]A = [_]A{undefined} ** n,

        pub fn empty() Self {
            return .{};
        }

        pub inline fn unit(value: A) Self {
            comptime std.debug.assert(n >= 1);
            var chunk = Self{ .right = 1 };
            chunk.forceWrite(
                0,
                value,
            );
            return chunk;
        }

        pub inline fn pair(left: A, right: A) Self {
            comptime std.debug.assert(n >= 2);
            var chunk = Self{ .right = 2 };
            chunk.forceWrite(0, left);
            chunk.forceWrite(1, right);
            return chunk;
        }

        pub fn fromRaw(comptime data: []A) Self {
            comptime std.debug.assert(n >= data.len);
            var chunk = Self{ .right = data.len };
            inline for (data, 0..) |d, i|
                chunk.forceWrite(i, d);
            return chunk;
        }

        pub inline fn len(self: *Self) usize {
            return self.right - self.left;
        }

        pub inline fn isEmpty(self: *Self) bool {
            return self.right == self.left;
        }

        pub inline fn isFull(self: *Self) bool {
            return self.left == 0 and self.right == n;
        }

        inline fn ptr(self: *Self, index: usize) *A {
            return &self.data[index];
        }

        inline fn forceRead(self: *Self, index: usize) A {
            return self.ptr(index).*;
        }

        inline fn forceWrite(self: *Self, index: usize, value: A) void {
            self.ptr(index).* = value;
        }

        inline fn forceWriteMany(self: *Self, write_index: usize, values: []A) void {
            const left = self.left;
            self.left = 0;
            defer self.left = left;
            const right = self.right;
            self.right = 0;
            defer self.right = right;
            for (values, write_index..) |value, index|
                self.forceWrite(index, value);
        }

        inline fn forceCopy(self: *Self, from: usize, to: usize, count: usize) void {
            if (count > 0)
                @memmove(
                    self.data[to..][0..count],
                    self.data[from..][0..count],
                );
        }

        inline fn forceCopyTo(self: *Self, other: *Self, from: usize, to: usize, count: usize) void {
            if (count > 0)
                @memcpy(
                    self.data[to..][0..count],
                    other.data[from..][0..count],
                );
        }

        pub fn pushFront(self: *Self, value: A) error{Full}!void {
            if (self.isFull()) return error.Full;
            if (self.isEmpty()) {
                self.left = n;
                self.right = n;
            } else if (self.left == 0) {
                self.left = n - self.right;
                self.forceCopy(0, self.left, self.right);
                self.right = n;
            }
            self.left -= 1;
            self.forceWrite(self.left, value);
        }

        pub fn pushBack(self: *Self, value: A) error{Full}!void {
            if (self.isFull()) return error.Full;
            if (self.isEmpty()) {
                self.left = 0;
                self.right = 0;
            } else if (self.right == n) {
                self.forceCopy(self.left, 0, self.len());
                self.right = n - self.left;
                self.left = 0;
            }
            self.forceWrite(self.right, value);
            self.right += 1;
        }

        pub fn popBack(self: *Self) ?A {
            if (self.isEmpty()) return null;
            defer self.right -= 1;
            return self.forceRead(self.right);
        }

        pub fn popFront(self: *Self) ?A {
            if (self.isEmpty()) return null;
            defer self.left += 1;
            return self.forceRead(self.left);
        }

        pub fn removeLeft(self: *Self, index: usize) void {
            self.left = @max(self.left + index, n);
        }

        pub fn removeRight(self: *Self, index: usize) void {
            self.right = @max(self.left + index, n);
        }

        pub fn splitOff(self: *Self, index: usize) Self {
            if (index > self.len()) @panic("Chunk.splitOff: index out of bounds");
            if (index == self.len()) return .{};
            var right_chunk = Self{};
            const start = self.left + index;
            const right_len = self.right - start;
            self.forceCopyTo(&right_chunk, start, 0, right_len);
            right_chunk.right = right_len;
            self.right = start;
            return right_chunk;
        }

        pub fn append(self: *Self, other: *Self) error{Overflow}!void {
            const self_len = self.len();
            const other_len = other.len();
            if (n > self_len + other_len) return error.Overflow;
            if (self.right + other_len > n) {
                self.forceCopy(self.left, 0, self_len);
                self.right -= self.left;
                self.left = 0;
            }
            other.forceCopyTo(self, other.left, self.right, other_len);
            self.right += other_len;
            other.left = 0;
            other.right = 0;
        }

        pub fn drainFromFront(self: *Self, other: *Self, count: usize) error{ Overflow, NotEnoughItems }!void {
            const self_len = self.len();
            const other_len = other.len();
            if (n > self_len + other_len) return error.Overflow;
            if (count > other_len) return error.NotEnoughItems;
            if (self.right + count > n) {
                self.forceCopy(self.left, 0, self_len);
                self.right -= self.left;
                self.left = 0;
            }
            other.forceCopyTo(self, other.left, self.right, count);
            self.right += count;
            other.left += count;
        }

        pub fn drainFromBack(self: *Self, other: *Self, count: usize) error{ Overflow, NotEnoughItems }!void {
            const self_len = self.len();
            const other_len = other.len();
            if (n > self_len + other_len) return error.Overflow;
            if (count > other_len) return error.NotEnoughItems;
            if (self.left < count) {
                self.forceCopy(self.left, n - self_len, self_len);
                self.left = n - self_len;
                self.right = n;
            }
            other.forceCopyTo(self, other.right - count, self.left - count, count);
            self.right -= count;
            other.left -= count;
        }

        pub fn set(self: *Self, index: usize, value: A) A {
            const out = self.data[index];
            self.data[index] = value;
            return out;
        }

        /// Insert a new value at index `index`, shifting all the following values
        /// to the right.
        ///
        /// Panics if the index is out of bounds.
        ///
        /// Time: O(n) for the number of elements shifted
        pub fn insert(self: *Self, index: usize, value: A) error{Full}!void {
            if (self.isFull()) return error.Full;
            if (index > self.len()) @panic("Chunk.insert: index out of bounds");

            const real_index = index + self.left;
            const left_size = index;
            const right_size = self.right - real_index;
            if (self.right == n or (0 < self.left and left_size < right_size)) {
                self.forceCopy(self.left, self.left - 1, left_size);
                self.forceWrite(real_index - 1, value);
                self.left -= 1;
            } else {
                self.forceCopy(real_index, real_index + 1, right_size);
                self.forceWrite(real_index, value);
                self.right += 1;
            }
        }
        /// Insert a new value at index `index`, shifting all the following values
        /// to the right.
        ///
        /// Panics if the index is out of bounds.
        pub fn insertMany(self: *Self, index: usize, values: []A) error{Overflow}!void {
            const insert_size = values.len;
            if (self.len() + insert_size > n) return error.Overflow;
            if (index > self.len()) @panic("Chunk.insert: index out of bounds");

            const real_index = index + self.left;
            const left_size = index;
            const right_size = self.right - real_index;
            if (self.right == n or (insert_size <= self.left and left_size < right_size)) {
                self.forceCopy(self.left, self.left - insert_size, left_size);
                const write_index = real_index - insert_size;
                self.forceWriteMany(write_index, values);
                self.left -= insert_size;
            } else if (self.left == 0 or (self.right + insert_size <= n)) {
                self.forceCopy(real_index, real_index + insert_size, right_size);
                self.forceWriteMany(real_index, values);
                self.right += insert_size;
            } else {
                self.forceCopy(self.left, 0, left_size);
                self.forceCopy(real_index, left_size + insert_size, right_size);
                self.forceWriteMany(left_size, values);
                self.right -= self.left;
                self.right += insert_size;
                self.left = 0;
            }
        }

        /// Remove the value at index `index`, shifting all the following values to
        /// the left.
        ///
        /// Returns the removed value.
        ///
        /// Time: O(n) for the number of items shifted
        pub fn remove(self: *Self, index: usize) ?A {
            if (index >= self.len()) return null;
            const real_index = index + self.left;
            const value = self.forceRead(real_index);
            const left_size = index;
            const right_size = self.right - real_index - 1;
            if (left_size < right_size) {
                self.forceCopy(self.left, self.left + 1, left_size);
                self.left += 1;
            } else {
                self.forceCopy(real_index + 1, real_index, right_size);
                self.right -= 1;
            }
            return value;
        }

        pub fn clear(self: *Self) void {
            self.left = 0;
            self.right = 0;
        }

        pub fn items(self: *Self) []A {
            return self.data[self.left..self.right];
        }
    };
}

const testing = std.testing;
const Allocator = std.mem.Allocator;

// NOTE: These tests assume the existence of a `Chunk` type with the following interface:
//   Chunk(comptime T: type, comptime CAPACITY: usize)
//   Methods: pushBack, pushFront, popFront, popBack, insert, insertFrom,
//            remove, dropLeft, dropRight, splitOff, append, isFull,
//            len, iter, iterMut, toOwnedSlice, unit, pair, fromInlineArray
//
// And an `InlineArray` type with:
//   InlineArray(comptime T: type, comptime Storage: type)
//   Methods: push
//
// Adjust imports/namespaces to match your actual implementation.

// ─── Drop Detector ────────────────────────────────────────────────────────────

const DropDetector = struct {
    value: u32,

    fn init(num: u32) DropDetector {
        return .{ .value = num };
    }

    fn deinit(self: DropDetector) void {
        std.debug.assert(self.value == 42 or self.value == 43);
    }

    fn clone(self: DropDetector) DropDetector {
        if (self.value == 42) @panic("panic on clone");
        return DropDetector.init(self.value);
    }
};

// ─── Panicking Iterator ───────────────────────────────────────────────────────

const PanickingIterator = struct {
    current: u32,
    panic_at: u32,
    len: usize,

    fn next(self: *PanickingIterator) ?DropDetector {
        const num = self.current;
        if (num == self.panic_at) @panic("panicking index");
        self.current += 1;
        return DropDetector.init(num);
    }
};

// ─── Fake Size Iterator ───────────────────────────────────────────────────────

const FakeSizeIterator = struct {
    reported: usize,
    actual: usize,

    fn next(self: *FakeSizeIterator) ?u8 {
        if (self.actual == 0) return null;
        self.actual -= 1;
        return 1;
    }

    fn len(self: FakeSizeIterator) usize {
        return self.reported;
    }
};

// ─── Tests ────────────────────────────────────────────────────────────────────

test "issue_11_testcase1d: push_back to full chunk panics" {
    // const chunk = Chunk(usize, 2).pair(123, 456);
    // // Expect panic: "Chunk::push_back: can't push to full chunk"
    // try testing.expectPanic(struct {
    //     fn call() void {
    //         try chunk.pushBack(789);
    //     }
    // }.call);
}

test "issue_11_testcase3a: clone with panic drops correctly (miri)" {
    // var chunk = Chunk(DropDetector, 3).init();
    // try chunk.pushBack(DropDetector.init(42));
    // try chunk.pushBack(DropDetector.init(42));
    // try chunk.pushBack(DropDetector.init(43));
    // _ = chunk.popFront();

    // // Catch the clone panic; miri checks for memory safety / correct drops
    // const result = std.testing.expectPanic(struct {
    //     fn call(c: *Chunk(DropDetector, 3)) void {
    //         _ = c.clone();
    //     }
    // }.call);
    // _ = result;
}

// test "issue_11_testcase3b: insert_from with panicking iterator drops correctly" {
//     const result = std.testing.expectPanic(struct {
//         fn call() void {
//             var chunk = Chunk(DropDetector, 5).init();
//             try chunk.pushBack(DropDetector.init(1));
//             try chunk.pushBack(DropDetector.init(2));
//             try chunk.pushBack(DropDetector.init(3));
//             var it = PanickingIterator{ .current = 1, .panic_at = 1, .len = 1 };
//             try chunk.insertFrom(1, &it);
//         }
//     }.call);
//     _ = result;
// }

// test "iterator_too_long: inserting from oversized iterator is handled" {
//     {
//         var chunk = Chunk(u8, 5).empty();
//         try chunk.pushBack(0);
//         try chunk.pushBack(1);
//         try chunk.pushBack(2);
//         var it = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
//         try chunk.insertMany(1, &it);
//     }
//     {
//         var chunk = Chunk(u8, 5).empty();
//         try chunk.pushBack(1);
//         var it = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
//         try chunk.insertMany(0, &it);
//     }
//     {
//         var chunk = Chunk(u8, 5).empty();
//         var it = FakeSizeIterator{ .reported = 1, .actual = 10 };
//         try chunk.insertMany(0, &it);
//     }
// }

// test "iterator_too_short1: ExactSizeIterator fewer values panics" {
//     try testing.expectPanic(struct {
//         fn call() void {
//             var chunk = Chunk(u8, 5).init();
//             try chunk.pushBack(0);
//             try chunk.pushBack(1);
//             try chunk.pushBack(2);
//             var it = FakeSizeIterator{ .reported = 2, .actual = 0 };
//             try chunk.insertFrom(1, &it);
//         }
//     }.call);
// }

// test "iterator_too_short2: ExactSizeIterator fewer values panics" {
//     try testing.expectPanic(struct {
//         fn call() void {
//             var chunk = Chunk(u8, 5).init();
//             try chunk.pushBack(1);
//             var it = FakeSizeIterator{ .reported = 4, .actual = 2 };
//             try chunk.insertFrom(1, &it);
//         }
//     }.call);
// }

test "is_full" {
    var chunk = Chunk(i32, 64).empty();
    for (0..64) |i| {
        try testing.expectEqual(false, chunk.isFull());
        try chunk.pushBack(@intCast(i));
    }
    try testing.expectEqual(true, chunk.isFull());
}

test "push_back_front" {
    var chunk = Chunk(i32, 64).empty();
    for (12..20) |i| try chunk.pushBack(@intCast(i));
    try testing.expectEqual(@as(usize, 8), chunk.len());

    var i: i32 = 11;
    while (i >= 0) : (i -= 1) try chunk.pushFront(i);
    try testing.expectEqual(@as(usize, 20), chunk.len());

    for (20..32) |j| try chunk.pushBack(@intCast(j));
    try testing.expectEqual(@as(usize, 32), chunk.len());

    var out = try std.ArrayList(i32).initCapacity(testing.allocator, 32);
    defer out.deinit(testing.allocator);
    for (chunk.items()) |v| try out.append(testing.allocator, v);

    for (0..32) |j| try testing.expectEqual(@as(i32, @intCast(j)), out.items[j]);
}

test "push_and_pop" {
    var chunk = Chunk(i32, 64).empty();
    for (0..64) |i| try chunk.pushBack(@intCast(i));
    for (0..64) |i| try testing.expectEqual(@as(i32, @intCast(i)), chunk.popFront());
    for (0..64) |i| try chunk.pushFront(@intCast(i));
    for (0..64) |i| try testing.expectEqual(@as(i32, @intCast(i)), chunk.popBack());
}

test "drop_left" {
    var chunk = Chunk(i32, 64).empty();
    for (0..6) |i| try chunk.pushBack(@intCast(i));
    chunk.removeLeft(3);

    var out = try std.ArrayList(i32).initCapacity(testing.allocator, 6);
    defer out.deinit(testing.allocator);
    for (chunk.items()) |v| try out.append(testing.allocator, v);

    try testing.expectEqualSlices(i32, &[_]i32{ 3, 4, 5 }, out.items);
}

test "drop_right" {
    var chunk = Chunk(i32, 64).empty();
    for (0..6) |i| try chunk.pushBack(@intCast(i));
    chunk.removeRight(3);

    var out = try std.ArrayList(i32).initCapacity(testing.allocator, 6);
    defer out.deinit(testing.allocator);
    for (chunk.items()) |v| try out.append(testing.allocator, v);

    try testing.expectEqualSlices(i32, &[_]i32{ 0, 1, 2 }, out.items);
}

test "split_off" {
    var left = Chunk(i32, 64).empty();
    for (0..6) |i| try left.pushBack(@intCast(i));
    var right = left.splitOff(3);

    var left_out = try std.ArrayList(i32).initCapacity(testing.allocator, 6);
    defer left_out.deinit(testing.allocator);
    var right_out = try std.ArrayList(i32).initCapacity(testing.allocator, 6);
    defer right_out.deinit(testing.allocator);

    for (left.items()) |v| try left_out.append(testing.allocator, v);
    for (right.items()) |v| try right_out.append(testing.allocator, v);

    try testing.expectEqualSlices(i32, &[_]i32{ 0, 1, 2 }, left_out.items);
    try testing.expectEqualSlices(i32, &[_]i32{ 3, 4, 5 }, right_out.items);
}

test "append" {
    var left = Chunk(i32, 64).empty();
    for (0..32) |i| try left.pushBack(@intCast(i));

    var right = Chunk(i32, 64).empty();
    var i: i32 = 63;
    while (i >= 32) : (i -= 1) try right.pushFront(i);

    try left.append(&right);

    var out = try std.ArrayList(i32).initCapacity(testing.allocator, 64);
    defer out.deinit(testing.allocator);
    for (left.items()) |v| try out.append(testing.allocator, v);

    for (0..64) |j| try testing.expectEqual(@as(i32, @intCast(j)), out.items[j]);
}

test "items" {
    var chunk = Chunk(i32, 64).empty();
    for (0..64) |i| try chunk.pushBack(@intCast(i));

    for (chunk.items(), 0..) |v, idx| {
        try testing.expectEqual(@as(i32, @intCast(idx)), v);
    }
    try testing.expectEqual(@as(usize, 64), chunk.items().len);
}

test "insert_middle" {
    var chunk = Chunk(i32, 64).empty();
    for (0..32) |i| try chunk.pushBack(@intCast(i));
    for (33..64) |i| try chunk.pushBack(@intCast(i));
    try chunk.insert(32, 32);

    for (chunk.items(), 0..) |v, idx| {
        try testing.expectEqual(@as(i32, @intCast(idx)), v);
    }
}

test "insert_back" {
    var chunk = Chunk(i32, 64).empty();
    for (0..63) |i| try chunk.pushBack(@intCast(i));
    try chunk.insert(63, 63);

    for (chunk.items(), 0..) |v, idx| {
        try testing.expectEqual(@as(i32, @intCast(idx)), v);
    }
}

test "insert_front" {
    var chunk = Chunk(i32, 64).empty();
    var i: usize = 1;
    while (i < 64) : (i += 1) try chunk.pushFront(@intCast(64 - i));
    try chunk.insert(0, 0);

    for (chunk.items(), 0..) |v, idx| {
        try testing.expectEqual(@as(i32, @intCast(idx)), v);
    }
}

test "remove_value" {
    var chunk = Chunk(i32, 64).empty();
    for (0..64) |i| try chunk.pushBack(@intCast(i));
    _ = chunk.remove(32);

    var out = try std.ArrayList(i32).initCapacity(testing.allocator, 64);
    defer out.deinit(testing.allocator);
    for (chunk.items()) |v| try out.append(testing.allocator, v);

    var expected = try std.ArrayList(i32).initCapacity(testing.allocator, 64);
    defer expected.deinit(testing.allocator);
    for (0..32) |i| try expected.append(testing.allocator, @intCast(i));
    for (33..64) |i| try expected.append(testing.allocator, @intCast(i));

    try testing.expectEqualSlices(i32, expected.items, out.items);
}

// test "dropping: all elements dropped correctly" {
//     var counter = std.atomic.Value(usize).init(0);

//     const DropTest = struct {
//         ctr: *std.atomic.Value(usize),

//         fn init(c: *std.atomic.Value(usize)) @This() {
//             _ = c.fetchAdd(1, .monotonic);
//             return .{ .ctr = c };
//         }

//         fn deinit(self: @This()) void {
//             _ = self.ctr.fetchSub(1, .monotonic);
//         }
//     };

//     {
//         var chunk = Chunk(DropTest, 64).init();
//         for (0..20) |_| try chunk.pushBack(DropTest.init(&counter));
//         for (0..20) |_| try chunk.pushFront(DropTest.init(&counter));
//         try testing.expectEqual(@as(usize, 40), counter.load(.));
//         for (0..10) |_| chunk.popBack().deinit();
//         try testing.expectEqual(@as(usize, 30), counter.load(.relaxed));
//         // chunk goes out of scope here; all remaining elements should be dropped
//         var it = chunk.intoIter();
//         while (it.next()) |v| v.deinit();
//     }
//     try testing.expectEqual(@as(usize, 0), counter.load(.relaxed));
// }
