const std = @import("std");

pub const TaskId = u32;

pub const TaskType = enum(u8) {
    immediate,
    deferred,
    delayed,
};

pub const TaskState = enum(u8) {
    pending,
    running,
    completed,
    cancelled,
};

pub const TaskCallback = *const fn (ctx: ?*anyopaque) void;

pub const TaskEntry = struct {
    id: TaskId,
    task_type: TaskType,
    state: TaskState = .pending,
    callback: ?TaskCallback = null,
    ctx: ?*anyopaque = null,

    // Timing parameters
    target_delay: f32 = 0.0,
    remaining: f32 = 0.0,
    elapsed: f32 = 0.0,
    created_at: f32 = 0.0,
};

pub const WaitSlot = struct {
    active: bool = false,
    target: f32 = 0.0,
    elapsed: f32 = 0.0,
    completed_this_frame: bool = false,
    last_resumed_elapsed: f32 = 0.0,
};

pub const MAX_WAIT_SLOTS: usize = 64;

pub const TaskScheduler = struct {
    allocator: std.mem.Allocator,
    tasks: std.ArrayListUnmanaged(TaskEntry) = .empty,
    deferred_queue: std.ArrayListUnmanaged(TaskEntry) = .empty,
    next_task_id: TaskId = 1,
    current_time: f32 = 0.0,
    current_dt: f32 = 0.0,

    wait_slots: [MAX_WAIT_SLOTS]WaitSlot = [_]WaitSlot{.{}} ** MAX_WAIT_SLOTS,

    total_tasks_scheduled: u64 = 0,
    total_tasks_executed: u64 = 0,
    total_tasks_cancelled: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) TaskScheduler {
        return .{
            .allocator = allocator,
            .tasks = .empty,
            .deferred_queue = .empty,
            .wait_slots = [_]WaitSlot{.{}} ** MAX_WAIT_SLOTS,
        };
    }

    pub fn deinit(self: *TaskScheduler) void {
        self.tasks.deinit(self.allocator);
        self.deferred_queue.deinit(self.allocator);
    }

    /// Spawns a task to execute in the current task cycle
    pub fn spawn(self: *TaskScheduler, callback: TaskCallback, ctx: ?*anyopaque) !TaskId {
        const id = self.next_task_id;
        self.next_task_id += 1;

        const entry = TaskEntry{
            .id = id,
            .task_type = .immediate,
            .state = .pending,
            .callback = callback,
            .ctx = ctx,
            .created_at = self.current_time,
        };

        try self.tasks.append(self.allocator, entry);
        self.total_tasks_scheduled += 1;
        return id;
    }

    /// Defers a task to execute at the end of the frame tick
    pub fn deferTask(self: *TaskScheduler, callback: TaskCallback, ctx: ?*anyopaque) !TaskId {
        const id = self.next_task_id;
        self.next_task_id += 1;

        const entry = TaskEntry{
            .id = id,
            .task_type = .deferred,
            .state = .pending,
            .callback = callback,
            .ctx = ctx,
            .created_at = self.current_time,
        };

        try self.deferred_queue.append(self.allocator, entry);
        self.total_tasks_scheduled += 1;
        return id;
    }

    /// Schedules a task to execute after `seconds` have elapsed
    pub fn delay(self: *TaskScheduler, seconds: f32, callback: TaskCallback, ctx: ?*anyopaque) !TaskId {
        const id = self.next_task_id;
        self.next_task_id += 1;

        const dur = @max(0.0, seconds);
        const entry = TaskEntry{
            .id = id,
            .task_type = .delayed,
            .state = .pending,
            .callback = callback,
            .ctx = ctx,
            .target_delay = dur,
            .remaining = dur,
            .elapsed = 0.0,
            .created_at = self.current_time,
        };

        try self.tasks.append(self.allocator, entry);
        self.total_tasks_scheduled += 1;
        return id;
    }

    /// Cancels a pending or delayed task
    pub fn cancel(self: *TaskScheduler, task_id: TaskId) bool {
        for (self.tasks.items) |*t| {
            if (t.id == task_id and t.state == .pending) {
                t.state = .cancelled;
                self.total_tasks_cancelled += 1;
                return true;
            }
        }
        for (self.deferred_queue.items) |*t| {
            if (t.id == task_id and t.state == .pending) {
                t.state = .cancelled;
                self.total_tasks_cancelled += 1;
                return true;
            }
        }
        return false;
    }

    /// Cooperative wait query for a specific slot.
    /// If not active, arms the timer with `seconds`.
    /// On each tick, accumulates dt.
    /// When elapsed >= target, returns the exact elapsed duration on that frame and resets.
    /// While waiting, returns 0.0.
    pub fn wait(self: *TaskScheduler, slot_id: u32, seconds: f32) f32 {
        const idx = slot_id % MAX_WAIT_SLOTS;
        var slot = &self.wait_slots[idx];

        if (!slot.active) {
            // First time called: arm the timer
            slot.active = true;
            slot.target = @max(0.0, seconds);
            slot.elapsed = 0.0;
            slot.completed_this_frame = false;
            slot.last_resumed_elapsed = 0.0;
            return 0.0;
        }

        if (slot.completed_this_frame) {
            const res = slot.last_resumed_elapsed;
            slot.active = false;
            slot.completed_this_frame = false;
            slot.last_resumed_elapsed = 0.0;
            slot.elapsed = 0.0;
            return res;
        }

        return 0.0;
    }

    /// Steps the task scheduler with frame delta time
    pub fn step(self: *TaskScheduler, dt: f32) void {
        self.current_dt = dt;
        self.current_time += dt;

        // 1. Advance wait slots
        for (&self.wait_slots) |*slot| {
            if (slot.active) {
                slot.elapsed += dt;
                if (slot.elapsed >= slot.target) {
                    slot.completed_this_frame = true;
                    slot.last_resumed_elapsed = slot.elapsed;
                }
            } else {
                slot.completed_this_frame = false;
            }
        }

        // 2. Process immediate and delayed tasks in main queue
        var i: usize = 0;
        while (i < self.tasks.items.len) {
            var t = &self.tasks.items[i];
            if (t.state == .cancelled) {
                _ = self.tasks.swapRemove(i);
                continue;
            }

            var should_run = false;
            if (t.task_type == .immediate) {
                should_run = true;
            } else if (t.task_type == .delayed) {
                t.remaining -= dt;
                t.elapsed += dt;
                if (t.remaining <= 0.0001) {
                    should_run = true;
                }
            }

            if (should_run) {
                t.state = .running;
                if (t.callback) |cb| {
                    cb(t.ctx);
                }
                t.state = .completed;
                self.total_tasks_executed += 1;
                _ = self.tasks.swapRemove(i);
            } else {
                i += 1;
            }
        }

        // 3. Process deferred queue at end of tick
        self.runDeferred();
    }

    /// Executes all currently queued deferred tasks
    pub fn runDeferred(self: *TaskScheduler) void {
        var i: usize = 0;
        while (i < self.deferred_queue.items.len) {
            var t = &self.deferred_queue.items[i];
            if (t.state == .pending) {
                t.state = .running;
                if (t.callback) |cb| {
                    cb(t.ctx);
                }
                t.state = .completed;
                self.total_tasks_executed += 1;
            }
            i += 1;
        }
        self.deferred_queue.clearRetainingCapacity();
    }

    pub fn getPendingCount(self: *const TaskScheduler) usize {
        var count: usize = 0;
        for (self.tasks.items) |t| {
            if (t.state == .pending) count += 1;
        }
        for (self.deferred_queue.items) |t| {
            if (t.state == .pending) count += 1;
        }
        return count;
    }
};
