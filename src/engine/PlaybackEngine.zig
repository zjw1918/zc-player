const std = @import("std");
const CommandMod = @import("Command.zig");
const Command = CommandMod.Command;
const Snapshot = @import("Snapshot.zig").Snapshot;
const PlaybackSession = @import("../media/PlaybackSession.zig").PlaybackSession;
const VideoFrame = @import("../video/VideoPipeline.zig").VideoPipeline.VideoFrame;

pub const PlaybackEngine = struct {
    const Self = @This();
    const queue_capacity = 128;
    const tick_ns: u64 = 6 * std.time.ns_per_ms;

    allocator: std.mem.Allocator,
    thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    queue_mutex: std.Thread.Mutex = .{},
    queue_cond: std.Thread.Condition = .{},
    queue: [queue_capacity]Command = undefined,
    queue_head: usize = 0,
    queue_tail: usize = 0,
    queue_count: usize = 0,

    snapshot_mutex: std.Thread.Mutex = .{},
    snapshot: Snapshot = .{},
    session_mutex: std.Thread.Mutex = .{},

    session: PlaybackSession,

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .session = PlaybackSession.init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.stop();
    }

    pub fn start(self: *Self) !void {
        if (self.thread != null) {
            return error.AlreadyStarted;
        }

        try self.session.start();
        errdefer self.session.stop();

        self.running.store(true, .release);
        self.thread = try std.Thread.spawn(.{}, threadMain, .{self});
    }

    pub fn stop(self: *Self) void {
        self.running.store(false, .release);

        self.queue_mutex.lock();
        self.queue_cond.broadcast();
        self.queue_mutex.unlock();

        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }

        self.session_mutex.lock();
        self.session.stop();
        self.session_mutex.unlock();
        self.resetSnapshot();
    }

    pub fn sendOpen(self: *Self, path: []const u8) !void {
        try self.enqueue(Command.open(path));
    }

    pub fn sendPlay(self: *Self) !void {
        try self.enqueue(Command.simple(.play));
    }

    pub fn sendPause(self: *Self) !void {
        try self.enqueue(Command.simple(.pause));
    }

    pub fn sendStop(self: *Self) !void {
        try self.enqueue(Command.simple(.stop));
    }

    pub fn sendSeekAbs(self: *Self, time: f64) !void {
        try self.enqueue(Command.scalar(.seek_abs, time));
    }

    pub fn sendVolume(self: *Self, volume: f64) !void {
        try self.enqueue(Command.scalar(.set_volume, volume));
    }

    pub fn sendSpeed(self: *Self, speed: f64) !void {
        try self.enqueue(Command.scalar(.set_speed, speed));
    }

    pub fn requestShutdown(self: *Self) !void {
        try self.enqueue(Command.simple(.shutdown));
    }

    pub fn getSnapshot(self: *Self) Snapshot {
        self.snapshot_mutex.lock();
        defer self.snapshot_mutex.unlock();
        return self.snapshot;
    }

    pub fn getFrameForRender(self: *Self, master_clock: f64) ?VideoFrame {
        self.session_mutex.lock();
        defer self.session_mutex.unlock();
        return self.session.getFrameForRender(master_clock);
    }

    fn resetSnapshot(self: *Self) void {
        self.snapshot_mutex.lock();
        defer self.snapshot_mutex.unlock();
        self.snapshot = .{};
    }

    fn enqueue(self: *Self, command: Command) error{QueueFull}!void {
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();

        if (self.queue_count >= queue_capacity) {
            return error.QueueFull;
        }

        self.queue[self.queue_tail] = command;
        self.queue_tail = (self.queue_tail + 1) % queue_capacity;
        self.queue_count += 1;
        self.queue_cond.signal();
    }

    fn popNoWait(self: *Self) ?Command {
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();

        if (self.queue_count == 0) {
            return null;
        }

        const command = self.queue[self.queue_head];
        self.queue_head = (self.queue_head + 1) % queue_capacity;
        self.queue_count -= 1;
        return command;
    }

    fn popWait(self: *Self, timeout_ns: u64) ?Command {
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();

        if (self.queue_count == 0 and self.running.load(.acquire)) {
            _ = self.queue_cond.timedWait(&self.queue_mutex, timeout_ns) catch {};
        }

        if (self.queue_count == 0) {
            return null;
        }

        const command = self.queue[self.queue_head];
        self.queue_head = (self.queue_head + 1) % queue_capacity;
        self.queue_count -= 1;
        return command;
    }

    fn threadMain(self: *Self) void {
        while (self.running.load(.acquire)) {
            if (self.popWait(tick_ns)) |command| {
                self.session_mutex.lock();
                self.handleCommand(command);
                self.session_mutex.unlock();
            }

            while (self.popNoWait()) |command| {
                self.session_mutex.lock();
                self.handleCommand(command);
                self.session_mutex.unlock();
            }

            if (!self.running.load(.acquire)) {
                break;
            }

            self.session_mutex.lock();
            self.session.tick();
            self.session_mutex.unlock();
            self.updateSnapshot();
        }

        self.updateSnapshot();
    }

    fn handleCommand(self: *Self, command: Command) void {
        switch (command.kind) {
            .open => {
                self.session.openMedia(command.pathSlice());
            },
            .play => {
                self.session.play();
            },
            .pause => {
                self.session.pause();
            },
            .stop => {
                self.session.stopPlayback();
            },
            .seek_abs => {
                self.session.seek(command.value);
            },
            .set_volume => {
                self.session.setVolume(command.value);
            },
            .set_speed => {
                self.session.setSpeed(command.value);
            },
            .shutdown => {
                self.running.store(false, .release);
            },
        }
    }

    fn updateSnapshot(self: *Self) void {
        self.session_mutex.lock();
        const s = self.session.snapshot();
        self.session_mutex.unlock();
        self.snapshot_mutex.lock();
        self.snapshot = s;
        self.snapshot_mutex.unlock();
    }
};

test "engine start and scalar commands" {
    var engine = PlaybackEngine.init(std.testing.allocator);
    defer engine.deinit();

    try engine.start();

    try engine.sendVolume(0.5);
    try engine.sendSpeed(1.25);

    std.Thread.sleep(30 * std.time.ns_per_ms);

    const snapshot = engine.getSnapshot();
    try std.testing.expect(snapshot.volume > 0.0);
    try std.testing.expect(snapshot.playback_speed >= 0.25);
}

test "engine does not own global sdl lifecycle" {
    try std.testing.expect(!@hasField(PlaybackEngine, "runtime"));
}

test "engine command queue reports full when saturated" {
    var engine = PlaybackEngine.init(std.testing.allocator);
    defer engine.deinit();

    var i: usize = 0;
    while (i < PlaybackEngine.queue_capacity) : (i += 1) {
        try engine.sendPlay();
    }

    try std.testing.expectError(error.QueueFull, engine.sendPlay());
}

test "engine stop is idempotent before start" {
    var engine = PlaybackEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.stop();
    engine.stop();

    const snapshot = engine.getSnapshot();
    try std.testing.expectEqual(.stopped, snapshot.state);
}
