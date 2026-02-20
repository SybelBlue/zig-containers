//! By convention, root.zig is the root source file when making a library.
const std = @import("std");
const mem = std.mem;

pub const IndexError = error{InvalidId};

/// A container that has constant-time access, remove, insert, and (out-of-order) iteration.
/// Each inserted object is assigned an ID which is used to retrieve it. Note that invalidated
/// IDs will be recycled!
pub fn StaticIndexVector(comptime T: type) type {
    const Handle = struct { id: usize, data: *T };

    const IdOrderIterator = struct {
        const Self = @This();

        curr_id: usize = 0,
        siv: *StaticIndexVector(T),

        fn next(self: *Self) ?Handle {
            while (self.curr_id < self.siv.index.items.len) {
                defer self.curr_id += 1;
                const idx = self.siv.index.items[self.curr_id];
                if (idx < self.siv.data.items.len) return .{
                    .id = self.curr_id,
                    .data = &self.siv.data.items[idx],
                };
            }
            return null;
        }
    };

    return struct {
        const Self = @This();

        allocator: mem.Allocator,

        // data[index[idx]].id == idx
        index: std.ArrayList(usize),
        // parallel array where data[i].id == ids[i] (inverse of self.index)
        ids: std.ArrayList(usize),
        // container of data
        data: std.ArrayList(T),

        pub fn initCapacity(allocator: mem.Allocator, k: usize) !Self {
            return .{
                .allocator = allocator,
                .index = try std.ArrayList(usize).initCapacity(allocator, k),
                .ids = try std.ArrayList(usize).initCapacity(allocator, k),
                .data = try std.ArrayList(T).initCapacity(allocator, k),
            };
        }

        pub fn deinit(self: *Self) void {
            self.index.deinit(self.allocator);
            self.ids.deinit(self.allocator);
            self.data.deinit(self.allocator);
        }

        /// stores the data and assigns it an ID. raises an error if
        /// there is no space remaining to store the new data
        pub fn insert(self: *Self, data: T) error{OutOfMemory}!usize {
            const n = self.data.items.len;
            const reuse_old = n < self.ids.items.len;
            const id = if (reuse_old) self.ids.items[n] else n;
            if (!reuse_old) {
                try self.index.append(self.allocator, id);
                errdefer _ = self.index.pop();
                try self.ids.append(self.allocator, id);
            }
            // guaranteed to succeed if reuse_old
            try self.data.append(self.allocator, data);
            return id;
        }

        /// removes the data with the given ID, invalidating the
        /// ID in the process. null iff the ID is invalid.
        pub fn remove(self: *Self, id: usize) ?T {
            const idx = self.indexFor(id) catch return null;
            const last = self.len() - 1;
            mem.swap(T, &self.data.items[idx], &self.data.items[last]);
            const id_entry0 = &self.ids.items[idx];
            const id_entry1 = &self.ids.items[last];
            mem.swap(usize, id_entry0, id_entry1);
            mem.swap(usize, &self.index.items[id_entry0.*], &self.index.items[id_entry1.*]);
            return self.data.pop();
        }

        fn indexFor(self: *Self, id: usize) IndexError!usize {
            if (id >= self.index.items.len) return IndexError.InvalidId;
            const k = self.index.items[id];
            if (k >= self.data.items.len) return IndexError.InvalidId;
            return k;
        }

        /// returns a pointer to the data with the given id (constant time)
        pub fn get(self: *Self, id: usize) IndexError!*T {
            return &self.data.items[try self.indexFor(id)];
        }

        /// the amount of data stored
        pub fn len(self: *Self) usize {
            return self.data.items.len;
        }

        /// how many values self can hold without allocating memory
        pub fn capacity(self: *Self) usize {
            return self.data.capacity;
        }

        /// invalidates all data pointers and ids
        pub fn clear(self: *Self) void {
            self.data.clearRetainingCapacity();
        }

        /// returns an unordered slice of all valid data
        pub fn items(self: *Self) []T {
            return self.data.items;
        }

        /// returns an iterator object that provides all valid handles
        /// in ascending order of ID. use `items()` if ordering is unnecessary
        pub fn idOrderIterator(self: *Self) IdOrderIterator {
            return .{ .siv = self };
        }

        /// finds the id for the given data. warning, slow and
        /// non-deterministic if the container has multiple copies of data!
        pub fn findId(self: *Self, data: T) ?usize {
            for (self.data.items, self.ids.items) |d, id|
                if (d == data)
                    return id;
            return null;
        }
    };
}

// --- Initialization ---

test "initCapacity: len is zero" {
    const alloc = std.testing.allocator;
    var siv = try StaticIndexVector(u8).initCapacity(alloc, 8);
    defer siv.deinit();
    try std.testing.expectEqual(@as(usize, 0), siv.len());
}

test "initCapacity: capacity matches requested" {
    const alloc = std.testing.allocator;
    var siv = try StaticIndexVector(u8).initCapacity(alloc, 8);
    defer siv.deinit();
    try std.testing.expectEqual(@as(usize, 8), siv.capacity());
}

test "initCapacity zero: len and capacity are both zero" {
    const alloc = std.testing.allocator;
    var siv = try StaticIndexVector(u8).initCapacity(alloc, 0);
    defer siv.deinit();
    try std.testing.expectEqual(@as(usize, 0), siv.len());
    try std.testing.expectEqual(@as(usize, 0), siv.capacity());
}

test "initCapacity zero does not allocate" {
    const alloc = std.testing.allocator;
    _ = try StaticIndexVector(u8).initCapacity(alloc, 0);
    // testing.allocator will catch any unexpected allocation or leak
}

// --- push_back ---

test "push_back returns unique ids" {
    const alloc = std.testing.allocator;
    var siv = try StaticIndexVector(u8).initCapacity(alloc, 8);
    defer siv.deinit();
    const id0 = try siv.insert(0xab);
    const id1 = try siv.insert(0xcd);
    try std.testing.expect(id0 != id1);
}

test "push_back increases len" {
    const alloc = std.testing.allocator;
    var siv = try StaticIndexVector(u8).initCapacity(alloc, 4);
    defer siv.deinit();
    try std.testing.expectEqual(@as(usize, 0), siv.len());
    _ = try siv.insert(0x01);
    try std.testing.expectEqual(@as(usize, 1), siv.len());
    _ = try siv.insert(0x02);
    try std.testing.expectEqual(@as(usize, 2), siv.len());
}

test "push_back within capacity does not change capacity" {
    const alloc = std.testing.allocator;
    var siv = try StaticIndexVector(u8).initCapacity(alloc, 4);
    defer siv.deinit();
    _ = try siv.insert(0x01);
    _ = try siv.insert(0x02);
    try std.testing.expectEqual(@as(usize, 4), siv.capacity());
}

test "push_back beyond capacity grows capacity" {
    const alloc = std.testing.allocator;
    var siv = try StaticIndexVector(u8).initCapacity(alloc, 2);
    defer siv.deinit();
    var i: u8 = 0;
    while (i < 16) : (i += 1) {
        _ = try siv.insert(i);
    }
    try std.testing.expectEqual(@as(usize, 16), siv.len());
    try std.testing.expect(siv.capacity() >= 16);
}

test "push_back value is retrievable by returned id" {
    const alloc = std.testing.allocator;
    var siv = try StaticIndexVector(u8).initCapacity(alloc, 4);
    defer siv.deinit();
    const id = try siv.insert(0xbe);
    const val = (try siv.get(id)).*;
    try std.testing.expectEqual(@as(u8, 0xbe), val);
}

test "push_back all ids are unique across many insertions" {
    const alloc = std.testing.allocator;
    var siv = try StaticIndexVector(u8).initCapacity(alloc, 16);
    defer siv.deinit();
    var ids: [16]usize = undefined;
    for (&ids, 0..) |*id, i| {
        id.* = try siv.insert(@intCast(i));
    }
    for (ids, 0..) |a, i| {
        for (ids, 0..) |b, j| {
            if (i != j) try std.testing.expect(a != b);
        }
    }
}

// --- get ---

test "get returns error on out-of-range id" {
    const alloc = std.testing.allocator;
    var siv = try StaticIndexVector(u8).initCapacity(alloc, 4);
    defer siv.deinit();
    try std.testing.expectError(error.InvalidId, siv.get(9999));
}

test "get returns error on erased id" {
    const alloc = std.testing.allocator;
    var siv = try StaticIndexVector(u8).initCapacity(alloc, 4);
    defer siv.deinit();
    const id = try siv.insert(0x42);
    _ = siv.remove(id);
    try std.testing.expectError(error.InvalidId, siv.get(id));
}

// --- erase ---

test "erase decreases len" {
    const alloc = std.testing.allocator;
    var siv = try StaticIndexVector(u8).initCapacity(alloc, 4);
    defer siv.deinit();
    const id = try siv.insert(0x10);
    _ = try siv.insert(0x20);
    try std.testing.expectEqual(@as(usize, 2), siv.len());
    _ = siv.remove(id);
    try std.testing.expectEqual(@as(usize, 1), siv.len());
}

test "erase does not shrink capacity" {
    const alloc = std.testing.allocator;
    var siv = try StaticIndexVector(u8).initCapacity(alloc, 4);
    defer siv.deinit();
    const id = try siv.insert(0x10);
    _ = try siv.insert(0x20);
    const cap_before = siv.capacity();
    _ = siv.remove(id);
    try std.testing.expectEqual(cap_before, siv.capacity());
}

test "erase: surviving ids remain stable" {
    const alloc = std.testing.allocator;
    var siv = try StaticIndexVector(u8).initCapacity(alloc, 4);
    defer siv.deinit();
    const id0 = try siv.insert(0xaa);
    const id1 = try siv.insert(0xbb);
    try std.testing.expectEqual(@as(u8, 0xaa), siv.remove(id0));
    try std.testing.expectEqual(@as(u8, 0xbb), (try siv.get(id1)).*);
}

test "erase: freed slot is recycled, new id does not collide with live ids" {
    const alloc = std.testing.allocator;
    var siv = try StaticIndexVector(u8).initCapacity(alloc, 4);
    defer siv.deinit();
    const id0 = try siv.insert(0x11);
    const id1 = try siv.insert(0x22);
    _ = siv.remove(id0);
    const id2 = try siv.insert(0x33);
    try std.testing.expect(id2 != id1);
    try std.testing.expectEqual(@as(u8, 0x33), (try siv.get(id2)).*);
}

test "erase then push_back does not increase len beyond expected" {
    const alloc = std.testing.allocator;
    var siv = try StaticIndexVector(u8).initCapacity(alloc, 4);
    defer siv.deinit();
    const id = try siv.insert(0x01);
    _ = try siv.insert(0x02);
    _ = siv.remove(id);
    _ = try siv.insert(0x03);
    try std.testing.expectEqual(@as(usize, 2), siv.len());
}

// --- clear ---

test "clear sets len to zero" {
    const alloc = std.testing.allocator;
    var siv = try StaticIndexVector(u8).initCapacity(alloc, 4);
    defer siv.deinit();
    _ = try siv.insert(0x01);
    _ = try siv.insert(0x02);
    siv.clear();
    try std.testing.expectEqual(@as(usize, 0), siv.len());
}

test "clear retains capacity" {
    const alloc = std.testing.allocator;
    var siv = try StaticIndexVector(u8).initCapacity(alloc, 4);
    defer siv.deinit();
    _ = try siv.insert(0x01);
    _ = try siv.insert(0x02);
    siv.clear();
    try std.testing.expectEqual(@as(usize, 4), siv.capacity());
}

test "clear invalidates all previous ids" {
    const alloc = std.testing.allocator;
    var siv = try StaticIndexVector(u8).initCapacity(alloc, 4);
    defer siv.deinit();
    const id = try siv.insert(0xff);
    siv.clear();
    try std.testing.expectError(error.InvalidId, siv.get(id));
}

test "push_back after clear works normally" {
    const alloc = std.testing.allocator;
    var siv = try StaticIndexVector(u8).initCapacity(alloc, 4);
    defer siv.deinit();
    _ = try siv.insert(0x01);
    siv.clear();
    const id = try siv.insert(0x99);
    try std.testing.expectEqual(@as(u8, 0x99), (try siv.get(id)).*);
    try std.testing.expectEqual(@as(usize, 1), siv.len());
}

test "interleaved push_back and erase maintain consistent state" {
    const alloc = std.testing.allocator;
    var siv = try StaticIndexVector(u8).initCapacity(alloc, 4);
    defer siv.deinit();

    // Insert five elements
    const id0 = try siv.insert(0x10);
    const id1 = try siv.insert(0x20);
    const id2 = try siv.insert(0x30);
    const id3 = try siv.insert(0x40);
    const id4 = try siv.insert(0x50);
    try std.testing.expectEqual(@as(usize, 5), siv.len());

    // Remove two from the middle
    _ = siv.remove(id1);
    _ = siv.remove(id3);
    try std.testing.expectEqual(@as(usize, 3), siv.len());

    // Survivors are untouched
    try std.testing.expectEqual(@as(u8, 0x10), (try siv.get(id0)).*);
    try std.testing.expectEqual(@as(u8, 0x30), (try siv.get(id2)).*);
    try std.testing.expectEqual(@as(u8, 0x50), (try siv.get(id4)).*);

    // Erased ids are gone
    try std.testing.expectError(error.InvalidId, siv.get(id1));
    try std.testing.expectError(error.InvalidId, siv.get(id3));

    // Fill the two freed slots
    const id5 = try siv.insert(0x60);
    const id6 = try siv.insert(0x70);
    try std.testing.expectEqual(@as(usize, 5), siv.len());

    // New ids don't collide with any live id
    const live_ids = [_]usize{ id0, id2, id4, id5, id6 };
    for (live_ids, 0..) |a, i| {
        for (live_ids, 0..) |b, j| {
            if (i != j) try std.testing.expect(a != b);
        }
    }

    // New values are retrievable
    try std.testing.expectEqual(@as(u8, 0x60), (try siv.get(id5)).*);
    try std.testing.expectEqual(@as(u8, 0x70), (try siv.get(id6)).*);

    // Remove the head and tail, insert one more
    _ = siv.remove(id0);
    _ = siv.remove(id4);
    try std.testing.expectEqual(@as(usize, 3), siv.len());
    const id7 = try siv.insert(0x80);
    try std.testing.expectEqual(@as(usize, 4), siv.len());

    // The two survivors from before are still intact
    try std.testing.expectEqual(@as(u8, 0x30), (try siv.get(id2)).*);
    try std.testing.expectEqual(@as(u8, 0x60), (try siv.get(id5)).*);
    try std.testing.expectEqual(@as(u8, 0x70), (try siv.get(id6)).*);
    try std.testing.expectEqual(@as(u8, 0x80), (try siv.get(id7)).*);
}

test "items provides only live data" {
    const alloc = std.testing.allocator;
    var siv = try StaticIndexVector(u8).initCapacity(alloc, 4);
    defer siv.deinit();

    // Insert five elements
    const id0 = try siv.insert(0x10);
    const id1 = try siv.insert(0x20);
    _ = try siv.insert(0x30);
    const id3 = try siv.insert(0x40);
    const id4 = try siv.insert(0x50);

    // Remove two from the middle
    _ = siv.remove(id1);
    _ = siv.remove(id3);

    // Fill the two freed slots
    _ = try siv.insert(0x60);
    _ = try siv.insert(0x70);

    // Remove the head and tail, insert one more
    _ = siv.remove(id0);
    _ = siv.remove(id4);
    _ = try siv.insert(0x80);

    const items = siv.items();
    try std.testing.expectEqual(4, items.len);

    const remaining_data = [_]u8{ 0x30, 0x60, 0x70, 0x80 };
    for (remaining_data) |item|
        try std.testing.expectEqual(1, mem.count(u8, items, &[_]u8{item}));
}

test "IDOrderIterator provides live data in ascending id order" {
    const alloc = std.testing.allocator;
    var siv = try StaticIndexVector(u8).initCapacity(alloc, 4);
    defer siv.deinit();

    // Insert five elements
    const id0 = try siv.insert(0x10);
    const id1 = try siv.insert(0x20);
    const id2 = try siv.insert(0x30);
    const id3 = try siv.insert(0x40);
    const id4 = try siv.insert(0x50);

    // Remove two from the middle
    _ = siv.remove(id1);
    _ = siv.remove(id3);

    // Fill the two freed slots
    const id5 = try siv.insert(0x60);
    const id6 = try siv.insert(0x70);

    // Remove the head and tail, insert one more
    _ = siv.remove(id0);
    _ = siv.remove(id4);
    const id7 = try siv.insert(0x80);

    var remaining_ids = [_]usize{ id2, id5, id6, id7 };
    mem.sort(usize, &remaining_ids, {}, std.sort.asc(usize));

    var iterator = siv.idOrderIterator();
    for (remaining_ids) |id| {
        const x = iterator.next() orelse return error.IteratorTerminatedEarly;
        try std.testing.expectEqual(id, x.id);
        try std.testing.expectEqual(try siv.get(id), x.data);
    }
}
