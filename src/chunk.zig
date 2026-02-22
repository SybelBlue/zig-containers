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

        inline fn rawPtr(self: *Self, index: usize) *A {
            return &self.data[index];
        }

        inline fn forceRead(self: *Self, index: usize) A {
            return self.rawPtr(index).*;
        }

        inline fn forceWrite(self: *Self, index: usize, value: A) void {
            self.rawPtr(index).* = value;
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
                    other.data[to..][0..count],
                    self.data[from..][0..count],
                );
        }

        pub fn ptr(self: *Self, index: usize) *A {
            if (index >= self.len()) @panic("Chunk.getPtr: index out of bounds");
            return &self.data[self.left + index];
        }

        pub fn get(self: *Self, index: usize) A {
            return self.ptr(index).*;
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
            self.right -= 1;
            return self.forceRead(self.right);
        }

        pub fn popFront(self: *Self) ?A {
            if (self.isEmpty()) return null;
            defer self.left += 1;
            return self.forceRead(self.left);
        }

        pub fn removeLeft(self: *Self, index: usize) void {
            self.left = @min(self.left + index, n);
        }

        pub fn removeRight(self: *Self, index: usize) void {
            self.right = @min(self.left + index, n);
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

        pub fn append(self: *Self, other: *Self) error{TooManyItems}!void {
            const self_len = self.len();
            const other_len = other.len();
            if (n > self_len + other_len) return error.TooManyItems;
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

        pub fn drainFromFront(self: *Self, other: *Self, count: usize) error{ TooManyItems, NotEnoughItems }!void {
            const self_len = self.len();
            const other_len = other.len();
            if (n > self_len + other_len) return error.TooManyItems;
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

        pub fn drainFromBack(self: *Self, other: *Self, count: usize) error{ TooManyItems, NotEnoughItems }!void {
            const self_len = self.len();
            const other_len = other.len();
            if (n > self_len + other_len) return error.TooManyItems;
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
        pub fn insertMany(self: *Self, index: usize, values: []A) error{TooManyItems}!void {
            const insert_size = values.len;
            if (self.len() + insert_size > n) return error.TooManyItems;
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

    try testing.expectEqualSlices(i32, &[_]i32{ 0, 1, 2 }, left.items());
    try testing.expectEqualSlices(i32, &[_]i32{ 3, 4, 5 }, right.items());
}

test "append" {
    var out = try std.ArrayList(i32).initCapacity(testing.allocator, 64);
    defer out.deinit(testing.allocator);
    var left = Chunk(i32, 64).empty();
    for (0..32) |i| {
        try left.pushBack(@intCast(i));
        try out.append(testing.allocator, @intCast(i));
    }

    var right = Chunk(i32, 64).empty();
    var i: i32 = 63;
    while (i >= 32) : (i -= 1) {
        try right.pushFront(i);
        try out.insert(testing.allocator, 32, i);
    }

    try left.append(&right);

    try testing.expectEqualSlices(i32, out.items, left.items());
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
    _ = chunk.remove(32).?;

    var out = try std.ArrayList(i32).initCapacity(testing.allocator, 64);
    defer out.deinit(testing.allocator);
    for (chunk.items()) |v| try out.append(testing.allocator, v);

    var expected = try std.ArrayList(i32).initCapacity(testing.allocator, 64);
    defer expected.deinit(testing.allocator);
    for (0..32) |i| try expected.append(testing.allocator, @intCast(i));
    for (33..64) |i| try expected.append(testing.allocator, @intCast(i));

    try testing.expectEqualSlices(i32, expected.items, out.items);
}

test "insertMany: overflow returns error" {
    var chunk = Chunk(i32, 4).empty();
    try chunk.pushBack(0);
    try chunk.pushBack(1);
    try chunk.pushBack(2);
    var values = [_]i32{ 10, 11, 12 };
    // 2 slots left, trying to insert 3
    try testing.expectError(error.TooManyItems, chunk.insertMany(1, &values));
}

test "insertMany: into empty chunk" {
    var chunk = Chunk(i32, 8).empty();
    var values = [_]i32{ 1, 2, 3 };
    try chunk.insertMany(0, &values);
    try testing.expectEqual(@as(usize, 3), chunk.len());
    try testing.expectEqual(@as(i32, 1), chunk.get(0));
    try testing.expectEqual(@as(i32, 2), chunk.get(1));
    try testing.expectEqual(@as(i32, 3), chunk.get(2));
}

test "insertMany: at front" {
    var chunk = Chunk(i32, 8).empty();
    try chunk.pushBack(10);
    try chunk.pushBack(11);
    try chunk.pushBack(12);
    var values = [_]i32{ 1, 2, 3 };
    try chunk.insertMany(0, &values);
    try testing.expectEqual(@as(usize, 6), chunk.len());
    try testing.expectEqual(@as(i32, 1), chunk.get(0));
    try testing.expectEqual(@as(i32, 2), chunk.get(1));
    try testing.expectEqual(@as(i32, 3), chunk.get(2));
    try testing.expectEqual(@as(i32, 10), chunk.get(3));
    try testing.expectEqual(@as(i32, 11), chunk.get(4));
    try testing.expectEqual(@as(i32, 12), chunk.get(5));
}

test "insertMany: at back" {
    var chunk = Chunk(i32, 8).empty();
    try chunk.pushBack(1);
    try chunk.pushBack(2);
    try chunk.pushBack(3);
    var values = [_]i32{ 10, 11, 12 };
    try chunk.insertMany(3, &values);
    try testing.expectEqual(@as(usize, 6), chunk.len());
    try testing.expectEqual(@as(i32, 1), chunk.get(0));
    try testing.expectEqual(@as(i32, 2), chunk.get(1));
    try testing.expectEqual(@as(i32, 3), chunk.get(2));
    try testing.expectEqual(@as(i32, 10), chunk.get(3));
    try testing.expectEqual(@as(i32, 11), chunk.get(4));
    try testing.expectEqual(@as(i32, 12), chunk.get(5));
}

test "insertMany: in middle" {
    var chunk = Chunk(i32, 8).empty();
    try chunk.pushBack(1);
    try chunk.pushBack(2);
    try chunk.pushBack(5);
    try chunk.pushBack(6);
    var values = [_]i32{ 3, 4 };
    try chunk.insertMany(2, &values);
    try testing.expectEqual(@as(usize, 6), chunk.len());
    for (0..6) |i| {
        try testing.expectEqual(@as(i32, @intCast(i + 1)), chunk.get(i));
    }
}

// Force the shift-left branch:
//   Condition: self.right == n  OR  (insert_size <= self.left AND left_size < right_size)
// Push from the front so that self.left > 0, leaving room on the left,
// then insert near the front so left_size < right_size.
test "insertMany: shift-left branch" {
    var chunk = Chunk(i32, 8).empty();
    // Push from the front to create left headroom (left > 0)
    try chunk.pushFront(4);
    try chunk.pushFront(3);
    try chunk.pushFront(2);
    try chunk.pushFront(1);
    // State: left=4, right=8, values=[1,2,3,4]
    // Insert 1 value at index 0: left_size=0 < right_size=4, insert_size=1 <= left=4
    var values = [_]i32{0};
    try chunk.insertMany(0, &values);
    try testing.expectEqual(@as(usize, 5), chunk.len());
    for (0..5) |i| {
        try testing.expectEqual(@as(i32, @intCast(i)), chunk.get(i));
    }
}

// Force the shift-right branch:
//   Condition: self.left == 0  OR  self.right + insert_size <= n
// Fill from the back (left=0), so shifting right is the only option.
test "insertMany: shift-right branch" {
    var chunk = Chunk(i32, 8).empty();
    // Push from the back so left=0
    try chunk.pushBack(1);
    try chunk.pushBack(2);
    try chunk.pushBack(5);
    try chunk.pushBack(6);
    // left=0, right=4; right + insert_size = 4+2 = 6 <= 8
    var values = [_]i32{ 3, 4 };
    try chunk.insertMany(2, &values);
    try testing.expectEqual(@as(usize, 6), chunk.len());
    for (0..6) |i| {
        try testing.expectEqual(@as(i32, @intCast(i + 1)), chunk.get(i));
    }
}

// Force the full-reorganize branch:
//   Condition: left > 0 AND right + insert_size > n
// Arrange so there is left headroom but not enough room on the right,
// and the insert favors right (left_size >= right_size) to skip the shift-left branch.
test "insertMany: full-reorganize branch" {
    var chunk = Chunk(i32, 6).empty();
    // Build: pushBack 3 then pushFront 2, giving left=2, right=6 (full on right)
    // values: [1, 2, 3, 4, 5]
    try chunk.pushBack(3);
    try chunk.pushBack(4);
    try chunk.pushBack(5);
    try chunk.pushFront(2);
    try chunk.pushFront(1);
    // left=1, right=6 (using 0-based internal layout with capacity 6)
    // Insert at index 3 (left_size=3 >= right_size=2): skip shift-left.
    // right + insert_size = 6 + 1 = 7 > 6: skip shift-right. --> reorganize.
    var values = [_]i32{99};
    try chunk.insertMany(3, &values);
    try testing.expectEqual(@as(usize, 6), chunk.len());
    try testing.expectEqual(@as(i32, 1), chunk.get(0));
    try testing.expectEqual(@as(i32, 2), chunk.get(1));
    try testing.expectEqual(@as(i32, 3), chunk.get(2));
    try testing.expectEqual(@as(i32, 99), chunk.get(3));
    try testing.expectEqual(@as(i32, 4), chunk.get(4));
    try testing.expectEqual(@as(i32, 5), chunk.get(5));
}

test "insertMany: exact capacity fill" {
    var chunk = Chunk(i32, 5).empty();
    try chunk.pushBack(1);
    try chunk.pushBack(5);
    var values = [_]i32{ 2, 3, 4 };
    try chunk.insertMany(1, &values);
    try testing.expectEqual(@as(usize, 5), chunk.len());
    for (0..5) |i| {
        try testing.expectEqual(@as(i32, @intCast(i + 1)), chunk.get(i));
    }
}

test "insertMany: single value behaves like insert" {
    var chunk = Chunk(i32, 8).empty();
    for (0..4) |i| try chunk.pushBack(@intCast(i));
    var values = [_]i32{99};
    try chunk.insertMany(2, &values);
    try testing.expectEqual(@as(usize, 5), chunk.len());
    try testing.expectEqual(@as(i32, 0), chunk.get(0));
    try testing.expectEqual(@as(i32, 1), chunk.get(1));
    try testing.expectEqual(@as(i32, 99), chunk.get(2));
    try testing.expectEqual(@as(i32, 2), chunk.get(3));
    try testing.expectEqual(@as(i32, 3), chunk.get(4));
}

test "insertMany: empty slice is a no-op" {
    var chunk = Chunk(i32, 8).empty();
    try chunk.pushBack(1);
    try chunk.pushBack(2);
    try chunk.pushBack(3);
    var values = [_]i32{};
    try chunk.insertMany(1, &values);
    try testing.expectEqual(@as(usize, 3), chunk.len());
    try testing.expectEqual(@as(i32, 1), chunk.get(0));
    try testing.expectEqual(@as(i32, 2), chunk.get(1));
    try testing.expectEqual(@as(i32, 3), chunk.get(2));
}
