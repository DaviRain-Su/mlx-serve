const std = @import("std");

pub const Timer = struct {
    start_ns: u64,

    pub fn start() !Timer {
        return .{ .start_ns = monotonicNs() };
    }

    pub fn read(self: *Timer) u64 {
        const now = monotonicNs();
        return if (now >= self.start_ns) now - self.start_ns else 0;
    }

    pub fn reset(self: *Timer) void {
        self.start_ns = monotonicNs();
    }

    fn monotonicNs() u64 {
        var ts: std.c.timespec = undefined;
        if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
        return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
    }
};

fn realtimeNs() i128 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.REALTIME, &ts) != 0) return 0;
    return @as(i128, @intCast(ts.sec)) * std.time.ns_per_s + @as(i128, @intCast(ts.nsec));
}

pub fn timestamp() i64 {
    return @intCast(@divTrunc(realtimeNs(), std.time.ns_per_s));
}

pub fn milliTimestamp() i64 {
    return @intCast(@divTrunc(realtimeNs(), std.time.ns_per_ms));
}

pub fn openFile(io: std.Io, path: []const u8, options: std.Io.Dir.OpenFileOptions) !std.Io.File {
    if (std.fs.path.isAbsolute(path)) {
        return std.Io.Dir.openFileAbsolute(io, path, options);
    }
    return std.Io.Dir.cwd().openFile(io, path, options);
}

pub fn openDir(io: std.Io, path: []const u8, options: std.Io.Dir.OpenOptions) !std.Io.Dir {
    if (std.fs.path.isAbsolute(path)) {
        return std.Io.Dir.openDirAbsolute(io, path, options);
    }
    return std.Io.Dir.cwd().openDir(io, path, options);
}
