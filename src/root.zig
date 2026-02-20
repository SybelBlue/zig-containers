//! By convention, root.zig is the root source file when making a library.
const std = @import("std");
const mem = std.mem;

pub const IndexError = error{InvalidId};

pub fn StaticIndexVector(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: mem.Allocator,

        // data[index[key]].id == key
        index: std.ArrayList(usize),
        // inverse of index aka parallel array where data[i].id == id[i]
        id: std.ArrayList(usize),
        // container of data
        data: std.ArrayList(T),

        pub fn initCapacity(allocator: mem.Allocator, k: usize) !Self {
            return .{
                .allocator = allocator,
                .index = try std.ArrayList(usize).initCapacity(allocator, k),
                .id = try std.ArrayList(usize).initCapacity(allocator, k),
                .data = try std.ArrayList(T).initCapacity(allocator, k),
            };
        }

        pub fn deinit(self: *Self) void {
            self.index.deinit(self.allocator);
            self.id.deinit(self.allocator);
            self.data.deinit(self.allocator);
        }

        pub fn push_back(self: *Self, obj: T) !usize {
            const n = self.data.items.len;
            const reuse_old = n < self.id.items.len;
            const id = if (reuse_old) self.id.items[n] else n;
            if (!reuse_old) {
                try self.index.append(self.allocator, id);
                try self.id.append(self.allocator, id);
            }
            try self.data.append(self.allocator, obj);
            return id;
        }

        pub fn erase(self: *Self, id: usize) ?T {
            const idx = self.indexFor(id) catch return null;
            const last = self.len() - 1;
            mem.swap(T, &self.data.items[idx], &self.data.items[last]);
            const id_entry0 = &self.id.items[idx];
            const id_entry1 = &self.id.items[last];
            mem.swap(usize, id_entry0, id_entry1);
            mem.swap(usize, &self.index.items[id_entry0.*], &self.index.items[id_entry1.*]);
            return self.data.pop();
        }

        fn indexFor(self: *Self, id: usize) !usize {
            if (id >= self.index.items.len) return IndexError.InvalidId;
            const k = self.index.items[id];
            if (k >= self.data.items.len) return IndexError.InvalidId;
            return k;
        }

        pub fn get(self: *Self, id: usize) !*T {
            return &self.data.items[try self.indexFor(id)];
        }

        pub fn len(self: *Self) usize {
            return self.data.items.len;
        }

        pub fn capacity(self: *Self) usize {
            return self.data.capacity;
        }

        pub fn clear(self: *Self) void {
            self.data.clearRetainingCapacity();
        }

        pub fn items(self: *Self) []T {
            return &self.data.items;
        }
    };
}

// ... StaticIndexVector definition ...

const SIVu8 = StaticIndexVector(u8);

// --- Initialization ---

test "initCapacity: len is zero" {
    const alloc = std.testing.allocator;
    var siv = try SIVu8.initCapacity(alloc, 8);
    defer siv.deinit();
    try std.testing.expectEqual(@as(usize, 0), siv.len());
}

test "initCapacity: capacity matches requested" {
    const alloc = std.testing.allocator;
    var siv = try SIVu8.initCapacity(alloc, 8);
    defer siv.deinit();
    try std.testing.expectEqual(@as(usize, 8), siv.capacity());
}

test "initCapacity zero: len and capacity are both zero" {
    const alloc = std.testing.allocator;
    var siv = try SIVu8.initCapacity(alloc, 0);
    defer siv.deinit();
    try std.testing.expectEqual(@as(usize, 0), siv.len());
    try std.testing.expectEqual(@as(usize, 0), siv.capacity());
}

test "initCapacity zero does not allocate" {
    const alloc = std.testing.allocator;
    var siv = try SIVu8.initCapacity(alloc, 0);
    defer siv.deinit();
    // testing.allocator will catch any unexpected allocation or leak
}

// --- push_back ---

test "push_back returns unique ids" {
    const alloc = std.testing.allocator;
    var siv = try SIVu8.initCapacity(alloc, 8);
    defer siv.deinit();
    const id0 = try siv.push_back(0xab);
    const id1 = try siv.push_back(0xcd);
    try std.testing.expect(id0 != id1);
}

test "push_back increases len" {
    const alloc = std.testing.allocator;
    var siv = try SIVu8.initCapacity(alloc, 4);
    defer siv.deinit();
    try std.testing.expectEqual(@as(usize, 0), siv.len());
    _ = try siv.push_back(0x01);
    try std.testing.expectEqual(@as(usize, 1), siv.len());
    _ = try siv.push_back(0x02);
    try std.testing.expectEqual(@as(usize, 2), siv.len());
}

test "push_back within capacity does not change capacity" {
    const alloc = std.testing.allocator;
    var siv = try SIVu8.initCapacity(alloc, 4);
    defer siv.deinit();
    _ = try siv.push_back(0x01);
    _ = try siv.push_back(0x02);
    try std.testing.expectEqual(@as(usize, 4), siv.capacity());
}

test "push_back beyond capacity grows capacity" {
    const alloc = std.testing.allocator;
    var siv = try SIVu8.initCapacity(alloc, 2);
    defer siv.deinit();
    var i: u8 = 0;
    while (i < 16) : (i += 1) {
        _ = try siv.push_back(i);
    }
    try std.testing.expectEqual(@as(usize, 16), siv.len());
    try std.testing.expect(siv.capacity() >= 16);
}

test "push_back value is retrievable by returned id" {
    const alloc = std.testing.allocator;
    var siv = try SIVu8.initCapacity(alloc, 4);
    defer siv.deinit();
    const id = try siv.push_back(0xbe);
    const val = (try siv.get(id)).*;
    try std.testing.expectEqual(@as(u8, 0xbe), val);
}

test "push_back all ids are unique across many insertions" {
    const alloc = std.testing.allocator;
    var siv = try SIVu8.initCapacity(alloc, 16);
    defer siv.deinit();
    var ids: [16]usize = undefined;
    for (&ids, 0..) |*id, i| {
        id.* = try siv.push_back(@intCast(i));
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
    var siv = try SIVu8.initCapacity(alloc, 4);
    defer siv.deinit();
    try std.testing.expectError(error.InvalidId, siv.get(9999));
}

test "get returns error on erased id" {
    const alloc = std.testing.allocator;
    var siv = try SIVu8.initCapacity(alloc, 4);
    defer siv.deinit();
    const id = try siv.push_back(0x42);
    _ = siv.erase(id);
    try std.testing.expectError(error.InvalidId, siv.get(id));
}

// --- erase ---

test "erase decreases len" {
    const alloc = std.testing.allocator;
    var siv = try SIVu8.initCapacity(alloc, 4);
    defer siv.deinit();
    const id = try siv.push_back(0x10);
    _ = try siv.push_back(0x20);
    try std.testing.expectEqual(@as(usize, 2), siv.len());
    _ = siv.erase(id);
    try std.testing.expectEqual(@as(usize, 1), siv.len());
}

test "erase does not shrink capacity" {
    const alloc = std.testing.allocator;
    var siv = try SIVu8.initCapacity(alloc, 4);
    defer siv.deinit();
    const id = try siv.push_back(0x10);
    _ = try siv.push_back(0x20);
    const cap_before = siv.capacity();
    _ = siv.erase(id);
    try std.testing.expectEqual(cap_before, siv.capacity());
}

test "erase: surviving ids remain stable" {
    const alloc = std.testing.allocator;
    var siv = try SIVu8.initCapacity(alloc, 4);
    defer siv.deinit();
    const id0 = try siv.push_back(0xaa);
    const id1 = try siv.push_back(0xbb);
    try std.testing.expectEqual(@as(u8, 0xaa), siv.erase(id0));
    try std.testing.expectEqual(@as(u8, 0xbb), (try siv.get(id1)).*);
}

test "erase: freed slot is recycled, new id does not collide with live ids" {
    const alloc = std.testing.allocator;
    var siv = try SIVu8.initCapacity(alloc, 4);
    defer siv.deinit();
    const id0 = try siv.push_back(0x11);
    const id1 = try siv.push_back(0x22);
    _ = siv.erase(id0);
    const id2 = try siv.push_back(0x33);
    try std.testing.expect(id2 != id1);
    try std.testing.expectEqual(@as(u8, 0x33), (try siv.get(id2)).*);
}

test "erase then push_back does not increase len beyond expected" {
    const alloc = std.testing.allocator;
    var siv = try SIVu8.initCapacity(alloc, 4);
    defer siv.deinit();
    const id = try siv.push_back(0x01);
    _ = try siv.push_back(0x02);
    _ = siv.erase(id);
    _ = try siv.push_back(0x03);
    try std.testing.expectEqual(@as(usize, 2), siv.len());
}

// --- clear ---

test "clear sets len to zero" {
    const alloc = std.testing.allocator;
    var siv = try SIVu8.initCapacity(alloc, 4);
    defer siv.deinit();
    _ = try siv.push_back(0x01);
    _ = try siv.push_back(0x02);
    siv.clear();
    try std.testing.expectEqual(@as(usize, 0), siv.len());
}

test "clear retains capacity" {
    const alloc = std.testing.allocator;
    var siv = try SIVu8.initCapacity(alloc, 4);
    defer siv.deinit();
    _ = try siv.push_back(0x01);
    _ = try siv.push_back(0x02);
    siv.clear();
    try std.testing.expectEqual(@as(usize, 4), siv.capacity());
}

test "clear invalidates all previous ids" {
    const alloc = std.testing.allocator;
    var siv = try SIVu8.initCapacity(alloc, 4);
    defer siv.deinit();
    const id = try siv.push_back(0xff);
    siv.clear();
    try std.testing.expectError(error.InvalidId, siv.get(id));
}

test "push_back after clear works normally" {
    const alloc = std.testing.allocator;
    var siv = try SIVu8.initCapacity(alloc, 4);
    defer siv.deinit();
    _ = try siv.push_back(0x01);
    siv.clear();
    const id = try siv.push_back(0x99);
    try std.testing.expectEqual(@as(u8, 0x99), (try siv.get(id)).*);
    try std.testing.expectEqual(@as(usize, 1), siv.len());
}

test "interleaved push_back and erase maintain consistent state" {
    const alloc = std.testing.allocator;
    var siv = try SIVu8.initCapacity(alloc, 4);
    defer siv.deinit();

    // Insert five elements
    const id0 = try siv.push_back(0x10);
    const id1 = try siv.push_back(0x20);
    const id2 = try siv.push_back(0x30);
    const id3 = try siv.push_back(0x40);
    const id4 = try siv.push_back(0x50);
    try std.testing.expectEqual(@as(usize, 5), siv.len());

    // Remove two from the middle
    _ = siv.erase(id1);
    _ = siv.erase(id3);
    try std.testing.expectEqual(@as(usize, 3), siv.len());

    // Survivors are untouched
    try std.testing.expectEqual(@as(u8, 0x10), (try siv.get(id0)).*);
    try std.testing.expectEqual(@as(u8, 0x30), (try siv.get(id2)).*);
    try std.testing.expectEqual(@as(u8, 0x50), (try siv.get(id4)).*);

    // Erased ids are gone
    try std.testing.expectError(error.InvalidId, siv.get(id1));
    try std.testing.expectError(error.InvalidId, siv.get(id3));

    // Fill the two freed slots
    const id5 = try siv.push_back(0x60);
    const id6 = try siv.push_back(0x70);
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
    _ = siv.erase(id0);
    _ = siv.erase(id4);
    try std.testing.expectEqual(@as(usize, 3), siv.len());
    const id7 = try siv.push_back(0x80);
    try std.testing.expectEqual(@as(usize, 4), siv.len());

    // The two survivors from before are still intact
    try std.testing.expectEqual(@as(u8, 0x30), (try siv.get(id2)).*);
    try std.testing.expectEqual(@as(u8, 0x60), (try siv.get(id5)).*);
    try std.testing.expectEqual(@as(u8, 0x70), (try siv.get(id6)).*);
    try std.testing.expectEqual(@as(u8, 0x80), (try siv.get(id7)).*);
}
