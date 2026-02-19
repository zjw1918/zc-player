const std = @import("std");

pub const path_capacity: usize = 1024;

pub const CommandKind = enum {
    open,
    play,
    pause,
    stop,
    seek_abs,
    set_volume,
    set_speed,
    shutdown,
};

pub const Command = struct {
    kind: CommandKind,
    value: f64 = 0.0,
    path: [path_capacity]u8 = [_]u8{0} ** path_capacity,

    pub fn open(path_in: []const u8) Command {
        var cmd = Command{ .kind = .open };
        const n = @min(path_in.len, path_capacity - 1);
        @memcpy(cmd.path[0..n], path_in[0..n]);
        cmd.path[n] = 0;
        return cmd;
    }

    pub fn scalar(kind: CommandKind, value: f64) Command {
        return Command{ .kind = kind, .value = value };
    }

    pub fn simple(kind: CommandKind) Command {
        return Command{ .kind = kind };
    }

    pub fn pathSlice(self: *const Command) []const u8 {
        const end = std.mem.indexOfScalar(u8, self.path[0..], 0) orelse path_capacity;
        return self.path[0..end];
    }
};
