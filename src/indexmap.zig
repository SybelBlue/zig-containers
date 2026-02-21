const std = @import("std");
const mem = std.mem;
const math = std.math;

const Wyhash = std.hash.Wyhash;
const List = std.ArrayList;

const Bucket = struct {
    const Self = @This();

    /// upper 3 bytes: dist to original bucket. lower byte: fingerprint from hash
    dist_and_fingerprint: u32 = 0,
    data_index: u32 = 0,

    const dist_inc: u32 = 1 << 8;
    const fingerprint_mask = dist_inc -% 1;

    fn incrementDist(dist_and_fingerprint: u32) u32 {
        return dist_and_fingerprint +% dist_inc;
    }

    fn decrementDist(dist_and_fingerprint: u32) u32 {
        return dist_and_fingerprint -% dist_inc;
    }

    fn incrementDistN(dist_and_fingerprint: u32, n: u32) void {
        return dist_and_fingerprint +% (n *% dist_inc);
    }

    fn dist_and_fingerprint_from_hash(hash: u64) u32 {
        return (@as(u32, @truncate(hash)) & fingerprint_mask) | dist_inc;
    }

    fn bucket_index_from_hash(hash: u64, shifts: u8) u64 {
        return hash >> shifts;
    }
};

const initial_shifts: u8 = 64 -% 3;

const max_size: u64 = 1 << 32;
const max_bucket_count = max_size;

fn nextBucketIndex(bucket_index: u32, max_buckets: u32) u32 {
    return if (bucket_index +% 1 != max_buckets) bucket_index +% 1 else 0;
}

fn calcNumBuckets(shifts: u8) u8 {
    return @min(((64 -% shifts) << 1), max_bucket_count);
}

fn calcShiftsForSize(size: u64, max_load_factor: f32) u8 {
    return calcShiftsForSizeHelper(initial_shifts, size, max_load_factor);
}

fn calcShiftsForSizeHelper(shifts: u8, size: u64, max_load_factor: f32) u8 {
    // todo, either tail call or make iterative
    const max_bucket_capacity = math.floor(
        max_load_factor * @as(f32, @floatFromInt(calcNumBuckets(shifts))),
    );
    if (shifts > 0 and max_bucket_capacity < @as(f32, @floatFromInt(size))) {
        return calcShiftsForSizeHelper(shifts -% 1, size, max_load_factor);
    }
    return shifts;
}

fn allocBucketsFromShift(allocator: mem.Allocator, shifts: u8, max_load_factor: u32) !struct { Buckets, u64 } {
    // TODO: refactor for values to be taken from self if possible
    const bucket_count = calcNumBuckets(shifts);
    const new_capacity = if (bucket_count == max_bucket_count)
        max_bucket_count
    else
        @as(usize, @intFromFloat(
            math.floor(max_load_factor * @as(f32, @floatFromInt(bucket_count))),
        ));
    const out = try Buckets.initCapacity(allocator, new_capacity);
    @memset(out.items, .{});
    return .{ out, max_bucket_count };
}

// TODO: group Buckets methods into thin wrapper struct
const Buckets = List(Bucket);

fn listGetUnsafe(comptime T: type, list: List(T), index: usize) *T {
    std.debug.assert(index < list.capacity);
    const out = &list.items[0..list.capacity][index];
    list.items.len = @max(index, list.items.len);
    return out;
}

fn nextWhileLessHelper(buckets: Buckets, bucket_index: u64, dist_and_fingerprint: u32) Bucket {
    // TODO: make iterative or tail call
    const loaded = listGetUnsafe(Bucket, buckets, bucket_index);
    if (dist_and_fingerprint >= loaded.*.dist_and_fingerprint) return .{ bucket_index, dist_and_fingerprint };
    return nextWhileLessHelper(
        buckets,
        nextBucketIndex(bucket_index, buckets.items.len),
        Bucket.incrementDist(dist_and_fingerprint),
    );
}

fn placeAndShiftUp(buckets0: Buckets, bucket: Bucket, bucket_index: u32) void {
    const loaded = listGetUnsafe(Bucket, buckets0, bucket_index);
    if (loaded.*.dist_and_fingerprint != 0) {
        mem.swap(Bucket, &bucket, loaded);
        placeAndShiftUp(
            buckets0,
            .{
                .data_index = bucket.data_index,
                .dist_and_fingerprint = Bucket.incrementDist(bucket.dist_and_fingerprint),
            },
            buckets0.items.len,
        );
    } else {
        loaded.* = bucket;
    }
}

fn getAutoHashFn(comptime K: type) (fn (K) u64) {
    if (K == []const u8) {
        return std.hash_map.hashString;
    }

    return struct {
        fn hash(key: K) u64 {
            if (std.meta.hasUniqueRepresentation(K)) {
                return Wyhash.hash(0, std.mem.asBytes(&key));
            } else {
                var hasher = Wyhash.init(0);
                std.hash_map.autoHash(&hasher, key);
                return hasher.final();
            }
        }
    }.hash;
}

fn getAutoEqlFn(comptime K: type) (fn (K, K) bool) {
    return struct {
        fn eql(a: K, b: K) bool {
            return std.meta.eql(a, b);
        }
    }.eql;
}

pub fn IndexMap(comptime K: type, comptime V: type) type {
    const Entry = struct { key: K, value: V };
    const FindResult = struct { bucket_index: u64, result: ?*V };

    const hashKey = getAutoHashFn(K);
    const keyEql = getAutoEqlFn(K);

    return struct {
        const Self = @This();

        allocator: mem.Allocator,

        buckets: Buckets,
        data: List(Entry),
        max_bucket_capacity: usize,
        max_load_factor: f32 = 0.8,
        shifts: u8 = initial_shifts,

        pub fn empty(allocator: mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .buckets = Buckets.empty,
                .data = List(Entry).empty,
                .max_bucket_capacity = 0,
            };
        }

        pub fn single(allocator: mem.Allocator, key: K, value: V) !Self {
            var out = try initCapacity(allocator, 1);
            try out.insert(key, value);
            return out;
        }

        pub fn initCapacity(allocator: mem.Allocator, k: usize) !Self {
            var out = empty(allocator);
            try out.reserve(k);
            return out;
        }

        pub fn reserve(self: *Self, requested: usize) !void {
            const current_size = self.len();
            const requested_size = current_size +% requested;
            const size = @max(requested_size, max_size);

            const requested_shifts = calcShiftsForSize(size, self.max_load_factor);
            if (!(self.buckets.items.len == 0 or requested_shifts > self.shifts))
                return; // return original self, make no mutations!

            try self.data.resize(self.allocator, size);
            try self.reallocAndRefillBuckets(requested_shifts);
        }

        pub fn minimizeCapacity(self: *Self) !void {
            const size = self.data.items.len;
            const min_shifts = calcShiftsForSize(size, self.max_load_factor);
            if (min_shifts >= self.shifts) return;

            self.reallocAndRefillBuckets(min_shifts);
            self.data.shrinkAndFree(self.allocator, size);
        }

        /// zeroes out length but retains the same capacity
        pub fn clear(self: *Self) void {
            @memset(self.buckets.items, .{});
            self.data.clearRetainingCapacity();
        }

        pub fn capacity(self: *Self) usize {
            return self.max_bucket_capacity;
        }

        pub fn len(self: *Self) usize {
            return self.data.len;
        }

        pub fn eql(self: *Self, other: *Self) bool {
            if (self.len() != other.len()) return false;
            for (self.data.items) |e| {
                const v = other.get(e.key) catch return false;
                if (v != e.value) return false;
            }
            return true;
        }

        fn find(self: *Self, key: K) FindResult {
            const hash = hashKey(key);
            const dist_and_fingerprint = Bucket.dist_and_fingerprint_from_hash(hash);
            const bucket_index = Bucket.bucket_index_from_hash(hash, self.shifts);
            if (self.data.items.len == 0) return .{ .bucket_index = bucket_index, .result = null };
            return findFirstUnroll(self.buckets, bucket_index, dist_and_fingerprint, self.data.items, key);
        }

        pub fn conains(self: *Self, key: K) bool {
            return self.find(key) != null;
        }

        pub fn get(self: *Self, key: K) error{KeyNotFound}!*V {
            return self.find(key) orelse error.KeyNotFound;
        }

        pub fn entries(self: *Self) *List(Entry) {
            return &self.data;
        }

        pub fn insert(self: *Self, key: K, value: V) !*Entry {
            if (self.len() >= self.capacity()) try self.increase_size();

            const hash = hashKey(key);
            const dist_and_fingerprint = Bucket.dist_and_fingerprint_from_hash(hash);
            const bucket_index = Bucket.bucket_index_from_hash(hash, self.shifts);

            return self.insertHelper(bucket_index, dist_and_fingerprint, key, value);
        }

        pub fn remove(self: *Self, key: K) ?V {
            if (self.data.items.len == 0) return null;
            const b0 = nextWhileLess(self.buckets, key, self.shifts);
            const helper = self.removeHelper(b0.data_index, b0.dist_and_fingerprint, key);
            const bucket = listGetUnsafe(Bucket, self.buckets, helper.@"0");
            if (helper.@"1" != bucket.dist_and_fingerprint) return null;
            return self.removeBucket(helper.@"0");
        }

        // TODO: hashing (self.hash, hash_key, hash_unordered)
        // TODO: traversals (walk, walk_until, map, join_map)
        // TODO: mutators (keep_if, drop_if, keep_all, remove_all, insert_all, update, keep_shared, remove_shared)

        fn increase_size(self: *Self) !void {
            if (self.max_bucket_capacity == max_bucket_count)
                @panic("crash: dict hit max number of elements, unable to resize");
            try self.reallocAndRefillBuckets(self.shifts -% 1);
        }

        fn reallocAndRefillBuckets(self: *Self, new_shifts: u8) !void {
            // TODO: attempt resizing before reallocating and copying, will have to empty if resized!

            const alloc_result = try allocBucketsFromShift(
                self.allocator,
                new_shifts,
                self.max_load_factor,
            );

            fillBucketsFromData(&alloc_result.@"0", &self.data, new_shifts);

            self.buckets.deinit(self.allocator);
            self.buckets = &alloc_result.@"0";
            self.max_bucket_capacity = alloc_result.@"1";
            self.shifts = new_shifts;
        }

        fn fillBucketsFromData(buckets: Buckets, data: List(Entry), shifts: u8) void {
            for (data.items, 0..) |bucket, data_index| {
                const key = bucket.key;
                const b = nextWhileLess(buckets, key, shifts);
                placeAndShiftUp(
                    buckets,
                    .{
                        .dist_and_fingerprint = b.dist_and_fingerprint,
                        .data_index = @intCast(data_index),
                    },
                    b.data_index,
                );
            }
        }

        fn nextWhileLess(buckets: Buckets, key: K, shifts: u8) Bucket {
            const hash = hashKey(key);
            const dist_and_fingerprint = Bucket.dist_and_fingerprint_from_hash(hash);
            const bucket_index = Bucket.bucket_index_from_hash(hash, shifts);
            return nextWhileLessHelper(buckets, bucket_index, dist_and_fingerprint);
        }

        fn insertHelper(self: *Self, bucket_index0: u64, dist_and_fingerprint0: u32, key: K, value: V) !*Entry {
            // TODO: rearrange cases so base case (>) is last, resulting in fewer checks
            const loaded = listGetUnsafe(Bucket, self.buckets, bucket_index0);
            if (dist_and_fingerprint0 > loaded.dist_and_fingerprint) {
                try self.data.append(self.allocator, .{ .key = key, .value = value });
                const data_index = self.data.items.len -% 1;
                placeAndShiftUp(
                    self.buckets,
                    .{
                        .dist_and_fingerprint = dist_and_fingerprint0,
                        .data_index = data_index,
                    },
                    bucket_index0,
                );
                return &self.data[data_index];
            }
            if (dist_and_fingerprint0 == loaded.dist_and_fingerprint) {
                const found = listGetUnsafe(Entry, self.data, loaded.data_index);
                if (keyEql(found.key, key)) {
                    found.value = value;
                    return found;
                }
            }
            const bucket_index1 = nextBucketIndex(bucket_index0, self.buckets.items.len);
            const dist_and_fingerprint1 = Bucket.incrementDist(dist_and_fingerprint0);
            return insertHelper(self, bucket_index1, dist_and_fingerprint1, key, value);
        }

        fn removeHelper(self: *Self, bucket_index: u64, dist_and_fingerprint: u32, key: K) struct { u64, u32 } {
            const bucket = listGetUnsafe(Bucket, self.buckets, bucket_index);
            if (dist_and_fingerprint != bucket.dist_and_fingerprint) return .{ bucket_index, dist_and_fingerprint };
            const found = listGetUnsafe(Entry, self.data, bucket.data_index);
            if (keyEql(found.key, key)) return .{ bucket_index, dist_and_fingerprint };
            return self.removeHelper(
                nextBucketIndex(bucket_index, self.data.items.len),
                Bucket.incrementDist(dist_and_fingerprint),
                key,
            );
        }

        fn removeBucket(self: *Self, bucket_index: u64) ?V {
            const data_index_to_remove = listGetUnsafe(Bucket, self.buckets, bucket_index).data_index;
            const bucket_index1 = removeBucketHelper(self.buckets, bucket_index);
            listGetUnsafe(Bucket, self.buckets, bucket_index1).* = .{};

            const last_data_index = self.data.items.len -% 1;
            if (data_index_to_remove == last_data_index) {
                if (self.data.pop()) |e| return e.value;
                return null;
            }

            const popped = self.data.swapRemove(data_index_to_remove);
            const key = listGetUnsafe(Entry, self.data, data_index_to_remove).key;

            const hash = hashKey(key);
            const bucket_index2 = Bucket.bucket_index_from_hash(hash, self.shifts);
            const bucket_index3 = scanForIndex(self.buckets, bucket_index2, @as(u32, @truncate(last_data_index)));

            const swap_bucket = listGetUnsafe(Bucket, self.buckets, bucket_index3);
            swap_bucket.data_index = data_index_to_remove;

            return popped.value;
        }

        fn scanForIndex(buckets: Buckets, bucket_index: u64, data_index: u32) u64 {
            // TODO make iterative or tail call
            const bucket = listGetUnsafe(Bucket, buckets, bucket_index);
            if (bucket.data_index == data_index) return data_index;
            return scanForIndex(buckets, nextBucketIndex(bucket_index, buckets.items.len), data_index);
        }

        fn removeBucketHelper(buckets: Buckets, bucket_index: u64) u64 {
            // TODO: make iterative or tail call
            const next_index = nextBucketIndex(bucket_index, buckets.items.len);
            const next_bucket = listGetUnsafe(Bucket, buckets, next_index);
            if (next_bucket.dist_and_fingerprint < Bucket.dist_inc *% 2) return bucket_index;
            next_bucket.dist_and_fingerprint = Bucket.decrementDist(next_bucket.dist_and_fingerprint);
            return removeBucketHelper(buckets, next_index);
        }

        inline fn findFirstUnroll(buckets: Buckets, bucket_index: u64, dist_and_fingerprint: u32, data: List(Entry), key: K) FindResult {
            const bucket = listGetUnsafe(Bucket, buckets, bucket_index);
            if (dist_and_fingerprint == bucket.dist_and_fingerprint) {
                const found = listGetUnsafe(Entry, data, bucket.data_index);
                if (keyEql(found.key, key))
                    return .{ .bucket_index = bucket_index, .result = &found.value };
            }
            return findFirstUnroll(
                buckets,
                nextBucketIndex(bucket_index, buckets.items.len),
                Bucket.incrementDist(dist_and_fingerprint),
                data,
                key,
            );
        }

        inline fn findSecondUnroll(buckets: Buckets, bucket_index: u64, dist_and_fingerprint: u32, data: List(Entry), key: K) FindResult {
            const bucket = listGetUnsafe(Bucket, buckets, bucket_index);
            if (dist_and_fingerprint == bucket.dist_and_fingerprint) {
                const found = listGetUnsafe(Entry, data, bucket.data_index);
                if (keyEql(found.key, key))
                    return .{ .bucket_index = bucket_index, .result = &found.value };
            }
            return findHelper(
                buckets,
                nextBucketIndex(bucket_index, buckets.items.len),
                Bucket.incrementDist(dist_and_fingerprint),
                data,
                key,
            );
        }

        fn findHelper(buckets: Buckets, bucket_index: u64, dist_and_fingerprint: u32, data: List(Entry), key: K) FindResult {
            // TODO: make iterative or tail call
            const bucket = listGetUnsafe(Bucket, buckets, bucket_index);
            if (dist_and_fingerprint > bucket.dist_and_fingerprint)
                return .{ .bucket_index = bucket_index, .result = null };

            if (dist_and_fingerprint == bucket.dist_and_fingerprint) {
                const found = listGetUnsafe(Entry, data, bucket.data_index);
                if (keyEql(found.key, key))
                    return .{ .bucket_index = bucket_index, .result = &found.value };
            }
            return findHelper(
                buckets,
                nextBucketIndex(bucket_index, buckets.items.len),
                Bucket.incrementDist(dist_and_fingerprint),
                data,
                key,
            );
        }
    };
}
