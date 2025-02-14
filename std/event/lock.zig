const std = @import("../std.zig");
const builtin = @import("builtin");
const assert = std.debug.assert;
const testing = std.testing;
const mem = std.mem;
const AtomicRmwOp = builtin.AtomicRmwOp;
const AtomicOrder = builtin.AtomicOrder;
const Loop = std.event.Loop;

/// Thread-safe async/await lock.
/// coroutines which are waiting for the lock are suspended, and
/// are resumed when the lock is released, in order.
/// Allows only one actor to hold the lock.
pub const Lock = struct {
    loop: *Loop,
    shared_bit: u8, // TODO make this a bool
    queue: Queue,
    queue_empty_bit: u8, // TODO make this a bool

    const Queue = std.atomic.Queue(promise);

    pub const Held = struct {
        lock: *Lock,

        pub fn release(self: Held) void {
            // Resume the next item from the queue.
            if (self.lock.queue.get()) |node| {
                self.lock.loop.onNextTick(node);
                return;
            }

            // We need to release the lock.
            _ = @atomicRmw(u8, &self.lock.queue_empty_bit, AtomicRmwOp.Xchg, 1, AtomicOrder.SeqCst);
            _ = @atomicRmw(u8, &self.lock.shared_bit, AtomicRmwOp.Xchg, 0, AtomicOrder.SeqCst);

            // There might be a queue item. If we know the queue is empty, we can be done,
            // because the other actor will try to obtain the lock.
            // But if there's a queue item, we are the actor which must loop and attempt
            // to grab the lock again.
            if (@atomicLoad(u8, &self.lock.queue_empty_bit, AtomicOrder.SeqCst) == 1) {
                return;
            }

            while (true) {
                const old_bit = @atomicRmw(u8, &self.lock.shared_bit, AtomicRmwOp.Xchg, 1, AtomicOrder.SeqCst);
                if (old_bit != 0) {
                    // We did not obtain the lock. Great, the queue is someone else's problem.
                    return;
                }

                // Resume the next item from the queue.
                if (self.lock.queue.get()) |node| {
                    self.lock.loop.onNextTick(node);
                    return;
                }

                // Release the lock again.
                _ = @atomicRmw(u8, &self.lock.queue_empty_bit, AtomicRmwOp.Xchg, 1, AtomicOrder.SeqCst);
                _ = @atomicRmw(u8, &self.lock.shared_bit, AtomicRmwOp.Xchg, 0, AtomicOrder.SeqCst);

                // Find out if we can be done.
                if (@atomicLoad(u8, &self.lock.queue_empty_bit, AtomicOrder.SeqCst) == 1) {
                    return;
                }
            }
        }
    };

    pub fn init(loop: *Loop) Lock {
        return Lock{
            .loop = loop,
            .shared_bit = 0,
            .queue = Queue.init(),
            .queue_empty_bit = 1,
        };
    }

    pub fn initLocked(loop: *Loop) Lock {
        return Lock{
            .loop = loop,
            .shared_bit = 1,
            .queue = Queue.init(),
            .queue_empty_bit = 1,
        };
    }

    /// Must be called when not locked. Not thread safe.
    /// All calls to acquire() and release() must complete before calling deinit().
    pub fn deinit(self: *Lock) void {
        assert(self.shared_bit == 0);
        while (self.queue.get()) |node| cancel node.data;
    }

    pub async fn acquire(self: *Lock) Held {
        // TODO explicitly put this memory in the coroutine frame #1194
        suspend {
            resume @handle();
        }
        var my_tick_node = Loop.NextTickNode.init(@handle());

        errdefer _ = self.queue.remove(&my_tick_node); // TODO test canceling an acquire
        suspend {
            self.queue.put(&my_tick_node);

            // At this point, we are in the queue, so we might have already been resumed and this coroutine
            // frame might be destroyed. For the rest of the suspend block we cannot access the coroutine frame.

            // We set this bit so that later we can rely on the fact, that if queue_empty_bit is 1, some actor
            // will attempt to grab the lock.
            _ = @atomicRmw(u8, &self.queue_empty_bit, AtomicRmwOp.Xchg, 0, AtomicOrder.SeqCst);

            const old_bit = @atomicRmw(u8, &self.shared_bit, AtomicRmwOp.Xchg, 1, AtomicOrder.SeqCst);
            if (old_bit == 0) {
                if (self.queue.get()) |node| {
                    // Whether this node is us or someone else, we tail resume it.
                    resume node.data;
                }
            }
        }

        return Held{ .lock = self };
    }
};

test "std.event.Lock" {
    // https://github.com/ziglang/zig/issues/1908
    if (builtin.single_threaded) return error.SkipZigTest;

    const allocator = std.heap.direct_allocator;

    var loop: Loop = undefined;
    try loop.initMultiThreaded(allocator);
    defer loop.deinit();

    var lock = Lock.init(&loop);
    defer lock.deinit();

    const handle = try async<allocator> testLock(&loop, &lock);
    defer cancel handle;
    loop.run();

    testing.expectEqualSlices(i32, [1]i32{3 * @intCast(i32, shared_test_data.len)} ** shared_test_data.len, shared_test_data);
}

async fn testLock(loop: *Loop, lock: *Lock) void {
    // TODO explicitly put next tick node memory in the coroutine frame #1194
    suspend {
        resume @handle();
    }
    const handle1 = async lockRunner(lock) catch @panic("out of memory");
    var tick_node1 = Loop.NextTickNode{
        .prev = undefined,
        .next = undefined,
        .data = handle1,
    };
    loop.onNextTick(&tick_node1);

    const handle2 = async lockRunner(lock) catch @panic("out of memory");
    var tick_node2 = Loop.NextTickNode{
        .prev = undefined,
        .next = undefined,
        .data = handle2,
    };
    loop.onNextTick(&tick_node2);

    const handle3 = async lockRunner(lock) catch @panic("out of memory");
    var tick_node3 = Loop.NextTickNode{
        .prev = undefined,
        .next = undefined,
        .data = handle3,
    };
    loop.onNextTick(&tick_node3);

    await handle1;
    await handle2;
    await handle3;
}

var shared_test_data = [1]i32{0} ** 10;
var shared_test_index: usize = 0;

async fn lockRunner(lock: *Lock) void {
    suspend; // resumed by onNextTick

    var i: usize = 0;
    while (i < shared_test_data.len) : (i += 1) {
        const lock_promise = async lock.acquire() catch @panic("out of memory");
        const handle = await lock_promise;
        defer handle.release();

        shared_test_index = 0;
        while (shared_test_index < shared_test_data.len) : (shared_test_index += 1) {
            shared_test_data[shared_test_index] = shared_test_data[shared_test_index] + 1;
        }
    }
}
