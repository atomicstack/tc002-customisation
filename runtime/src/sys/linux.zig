//! typed wrappers over the linux syscalls the runtime uses. linux only; the device kernel is 4.9,
//! so nothing newer than that is used. errors are a small explicit set; anything else is
//! `Unexpected` with the errno logged by the caller when it matters.
const std = @import("std");
pub const linux = std.os.linux;

pub const Fd = i32;
pub const Pid = linux.pid_t;

pub const Error = error{ WouldBlock, Interrupted, NotFound, AccessDenied, Busy, Exists, Truncated, Closed, NoChild, Unexpected };

pub fn errno(rc: usize) linux.E {
    const signed: isize = @bitCast(rc);
    if (signed < 0 and signed > -4096) return @enumFromInt(@as(u16, @intCast(-signed)));
    return .SUCCESS;
}

fn check(rc: usize) Error!usize {
    return switch (errno(rc)) {
        .SUCCESS => rc,
        .AGAIN => error.WouldBlock,
        .INTR => error.Interrupted,
        .NOENT, .NODEV, .NXIO => error.NotFound,
        .ACCES, .PERM => error.AccessDenied,
        .BUSY => error.Busy,
        .EXIST => error.Exists,
        .CHILD => error.NoChild,
        else => error.Unexpected,
    };
}

/// lowercase text for an error, for log lines.
pub fn errText(e: anyerror) []const u8 {
    return switch (e) {
        error.WouldBlock => "would block",
        error.Interrupted => "interrupted",
        error.NotFound => "not found",
        error.AccessDenied => "access denied",
        error.Busy => "busy",
        error.Exists => "exists",
        error.Truncated => "truncated",
        error.Closed => "closed",
        error.NoChild => "no child",
        error.Unexpected => "unexpected errno",
        error.InvalidRule => "invalid tz rule",
        else => "error",
    };
}

// files

pub fn open(path: [*:0]const u8, flags: linux.O, mode: linux.mode_t) Error!Fd {
    return @intCast(try check(linux.openat(linux.AT.FDCWD, path, flags, mode)));
}

pub fn close(fd: Fd) void {
    _ = linux.close(fd);
}

pub fn read(fd: Fd, buf: []u8) Error!usize {
    return check(linux.read(fd, buf.ptr, buf.len));
}

pub fn write(fd: Fd, bytes: []const u8) Error!usize {
    return check(linux.write(fd, bytes.ptr, bytes.len));
}

pub fn writeAll(fd: Fd, bytes: []const u8) Error!void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = write(fd, bytes[off..]) catch |e| switch (e) {
            error.Interrupted => continue,
            else => return e,
        };
        if (n == 0) return error.Closed;
        off += n;
    }
}

/// sysfs value files want a fresh single-byte write from offset 0 each time (pwrite rather than
/// lseek+write: the std lseek wrapper does not build for 32-bit arm in zig 0.16).
pub fn pwriteByte(fd: Fd, byte: u8) Error!void {
    const n = try check(linux.pwrite(fd, &[1]u8{byte}, 1, 0));
    if (n != 1) return error.Truncated;
}

pub fn ioctl(fd: Fd, request: u32, arg: usize) Error!usize {
    return check(linux.ioctl(fd, request, arg));
}

pub fn readlink(path: [*:0]const u8, buf: []u8) Error![]u8 {
    const n = try check(linux.readlink(path, buf.ptr, buf.len));
    return buf[0..n];
}

pub fn mkdir(path: [*:0]const u8, mode: linux.mode_t) Error!void {
    _ = check(linux.mkdir(path, mode)) catch |e| switch (e) {
        error.Exists => return,
        else => return e,
    };
}

pub fn chdir(path: [*:0]const u8) Error!void {
    _ = try check(linux.chdir(path));
}

pub fn dup2(old: Fd, new: Fd) Error!void {
    _ = try check(linux.dup2(old, new));
}

/// try to take an exclusive advisory lock; false when someone else holds it.
pub fn flockTry(fd: Fd) Error!bool {
    while (true) {
        const rc = linux.flock(fd, std.posix.LOCK.EX | std.posix.LOCK.NB);
        return switch (errno(rc)) {
            .SUCCESS => true,
            .AGAIN => false,
            .INTR => continue,
            else => error.Unexpected,
        };
    }
}

pub fn funlock(fd: Fd) void {
    _ = linux.flock(fd, std.posix.LOCK.UN);
}

// event loop primitives

pub const Event = linux.epoll_event;

pub fn epollCreate() Error!Fd {
    return @intCast(try check(linux.epoll_create1(linux.EPOLL.CLOEXEC)));
}

pub fn epollAdd(ep: Fd, fd: Fd, events: u32, tag: u64) Error!void {
    var ev = Event{ .events = events, .data = .{ .u64 = tag } };
    _ = try check(linux.epoll_ctl(ep, linux.EPOLL.CTL_ADD, fd, &ev));
}

pub fn epollDel(ep: Fd, fd: Fd) void {
    _ = linux.epoll_ctl(ep, linux.EPOLL.CTL_DEL, fd, null);
}

pub fn epollWait(ep: Fd, events: []Event, timeout_ms: i32) Error!usize {
    while (true) {
        return check(linux.epoll_wait(ep, events.ptr, @intCast(events.len), timeout_ms)) catch |e| switch (e) {
            error.Interrupted => continue,
            else => return e,
        };
    }
}

pub fn timerfdCreate() Error!Fd {
    return @intCast(try check(linux.timerfd_create(.MONOTONIC, .{ .CLOEXEC = true, .NONBLOCK = true })));
}

fn nsToTimespec(ns: u64) linux.timespec {
    return .{ .sec = @intCast(ns / std.time.ns_per_s), .nsec = @intCast(ns % std.time.ns_per_s) };
}

fn timespecToNs(ts: linux.timespec) u64 {
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// one-shot absolute monotonic expiry; zero would disarm, so it is rounded up to one nanosecond.
pub fn timerfdArmAt(fd: Fd, abs_ns: u64) Error!void {
    const spec = linux.itimerspec{ .it_interval = .{ .sec = 0, .nsec = 0 }, .it_value = nsToTimespec(@max(abs_ns, 1)) };
    _ = try check(linux.timerfd_settime(fd, .{ .ABSTIME = true }, &spec, null));
}

pub fn timerfdDisarm(fd: Fd) Error!void {
    const spec = linux.itimerspec{ .it_interval = .{ .sec = 0, .nsec = 0 }, .it_value = .{ .sec = 0, .nsec = 0 } };
    _ = try check(linux.timerfd_settime(fd, .{}, &spec, null));
}

pub fn timerfdDrain(fd: Fd) void {
    var expirations: [8]u8 = undefined;
    _ = linux.read(fd, &expirations, expirations.len);
}

/// block the given signals and return a signalfd that reports them.
pub fn signalfdFor(signals: []const linux.SIG) Error!Fd {
    var set = linux.sigemptyset();
    for (signals) |s| linux.sigaddset(&set, s);
    _ = try check(linux.sigprocmask(linux.SIG.BLOCK, &set, null));
    return @intCast(try check(linux.signalfd(-1, &set, linux.SFD.CLOEXEC | linux.SFD.NONBLOCK)));
}

pub fn readSignal(fd: Fd) Error!?linux.signalfd_siginfo {
    var info: linux.signalfd_siginfo = undefined;
    const n = read(fd, std.mem.asBytes(&info)) catch |e| switch (e) {
        error.WouldBlock => return null,
        error.Interrupted => return null,
        else => return e,
    };
    if (n != @sizeOf(linux.signalfd_siginfo)) return error.Truncated;
    return info;
}

pub fn unblockAllSignals() void {
    const empty = linux.sigemptyset();
    _ = linux.sigprocmask(linux.SIG.SETMASK, &empty, null);
}

pub fn setSignalDisposition(sig: linux.SIG, handler: ?linux.Sigaction.handler_fn) void {
    var act = linux.Sigaction{ .handler = .{ .handler = handler }, .mask = linux.sigemptyset(), .flags = 0 };
    _ = linux.sigaction(sig, &act, null);
}

// sockets

pub fn socketpairSeqpacket() Error![2]Fd {
    var fds: [2]i32 = undefined;
    _ = try check(linux.socketpair(linux.AF.UNIX, linux.SOCK.SEQPACKET | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK, 0, &fds));
    return fds;
}

pub fn sendPacket(fd: Fd, bytes: []const u8) Error!void {
    const n = try check(linux.sendto(fd, bytes.ptr, bytes.len, linux.MSG.NOSIGNAL | linux.MSG.DONTWAIT, null, 0));
    if (n != bytes.len) return error.Truncated;
}

/// one datagram, or null when none is waiting. a message larger than `buf` is an error.
pub fn recvPacket(fd: Fd, buf: []u8) Error!?[]u8 {
    const rc = linux.recvfrom(fd, buf.ptr, buf.len, linux.MSG.DONTWAIT | linux.MSG.TRUNC, null, null);
    const n = check(rc) catch |e| switch (e) {
        error.WouldBlock, error.Interrupted => return null,
        else => return e,
    };
    if (n > buf.len) return error.Truncated;
    if (n == 0) return error.Closed;
    return buf[0..n];
}

/// the ipv4 address of an interface via SIOCGIFADDR, or null when it has none.
pub fn ifAddr(ifname: []const u8) Error!?[4]u8 {
    const sock: Fd = @intCast(try check(linux.socket(linux.AF.INET, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0)));
    defer close(sock);
    var req: linux.ifreq = std.mem.zeroes(linux.ifreq);
    if (ifname.len >= req.ifrn.name.len) return error.Unexpected;
    @memcpy(req.ifrn.name[0..ifname.len], ifname);
    const rc = linux.ioctl(sock, linux.SIOCGIFADDR, @intFromPtr(&req));
    switch (errno(rc)) {
        .SUCCESS => {},
        .ADDRNOTAVAIL, .NODEV => return null,
        else => return error.Unexpected,
    }
    const in: *const linux.sockaddr.in = @ptrCast(@alignCast(&req.ifru.addr));
    return @bitCast(in.addr);
}

// time and sleep

pub fn monotonicNs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return timespecToNs(ts);
}

pub fn realtimeNs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    return timespecToNs(ts);
}

pub fn nanosleep(ns: u64) void {
    var req = nsToTimespec(ns);
    while (true) {
        var rem: linux.timespec = undefined;
        const rc = linux.nanosleep(&req, &rem);
        if (errno(rc) == .INTR) {
            req = rem;
            continue;
        }
        return;
    }
}

// processes

pub fn fork() Error!Pid {
    return @intCast(try check(linux.fork()));
}

/// returns only on failure.
pub fn execve(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) Error!void {
    _ = try check(linux.execve(path, argv, envp));
}

/// reap without blocking: the wait status when the child has exited, null while it is alive.
pub fn waitNoHang(pid: Pid) Error!?u32 {
    while (true) {
        var status: u32 = 0;
        const rc = linux.wait4(pid, &status, linux.W.NOHANG, null);
        return switch (errno(rc)) {
            .SUCCESS => if (rc == 0) null else status,
            .INTR => continue,
            .CHILD => error.NoChild,
            else => error.Unexpected,
        };
    }
}

pub fn kill(pid: Pid, sig: linux.SIG) void {
    _ = linux.kill(pid, sig);
}

pub fn getpid() Pid {
    return linux.getpid();
}

pub fn getppid() Pid {
    return linux.getppid();
}

pub fn prctlPdeathsig(sig: linux.SIG) Error!void {
    _ = try check(linux.prctl(@intFromEnum(linux.PR.SET_PDEATHSIG), @intFromEnum(sig), 0, 0, 0));
}

pub fn exit(status: u8) noreturn {
    linux.exit_group(status);
}

pub fn getrandom(buf: []u8) Error!void {
    var off: usize = 0;
    while (off < buf.len) {
        const n = check(linux.getrandom(buf[off..].ptr, buf.len - off, 0)) catch |e| switch (e) {
            error.Interrupted => continue,
            else => return e,
        };
        off += n;
    }
}

// input devices

/// EVIOCGKEY: whether a key is currently down according to the driver's state bitmap.
pub fn evdevKeyDown(fd: Fd, code: u16) Error!bool {
    var bits: [96]u8 = undefined; // KEY_MAX (0x2ff) / 8 + 1
    const request = linux.IOCTL.IOR('E', 0x18, [96]u8);
    _ = try check(linux.ioctl(fd, request, @intFromPtr(&bits)));
    if (code / 8 >= bits.len) return false;
    return (bits[code / 8] >> @intCast(code % 8)) & 1 == 1;
}

// tcp

fn inetAddr(addr: [4]u8, port: u16) linux.sockaddr.in {
    return .{ .port = std.mem.nativeToBig(u16, port), .addr = @bitCast(addr) };
}

/// a nonblocking listening socket on 0.0.0.0:port (needs root for ports below 1024).
pub fn tcpListener(port: u16, backlog: u32) Error!Fd {
    const fd: Fd = @intCast(try check(linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK, 0)));
    errdefer close(fd);
    const one: u32 = 1;
    _ = try check(linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, @ptrCast(&one), @sizeOf(u32)));
    const sa = inetAddr(.{ 0, 0, 0, 0 }, port);
    _ = try check(linux.bind(fd, @ptrCast(&sa), @sizeOf(linux.sockaddr.in)));
    _ = try check(linux.listen(fd, backlog));
    return fd;
}

/// accept one nonblocking, close-on-exec connection, or null when none is waiting.
pub fn accept(listener: Fd) Error!?Fd {
    const rc = linux.accept4(listener, null, null, linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC);
    const fd = check(rc) catch |e| switch (e) {
        error.WouldBlock, error.Interrupted => return null,
        else => return e,
    };
    return @intCast(fd);
}

/// start a nonblocking tcp connect; completion is reported by epoll OUT and `socketConnected`.
pub fn tcpConnect(addr: [4]u8, port: u16) Error!Fd {
    const fd: Fd = @intCast(try check(linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK, 0)));
    errdefer close(fd);
    const sa = inetAddr(addr, port);
    const rc = linux.connect(fd, &sa, @sizeOf(linux.sockaddr.in));
    switch (errno(rc)) {
        .SUCCESS, .INPROGRESS => return fd,
        else => return error.Unexpected,
    }
}

/// after epoll reports writability on a connecting socket: true when the connect succeeded.
pub fn socketConnected(fd: Fd) bool {
    var err: i32 = 0;
    var len: linux.socklen_t = @sizeOf(i32);
    const rc = linux.getsockopt(fd, linux.SOL.SOCKET, linux.SO.ERROR, @ptrCast(&err), &len);
    return errno(rc) == .SUCCESS and err == 0;
}

pub fn epollMod(ep: Fd, fd: Fd, events: u32, tag: u64) void {
    var ev = Event{ .events = events, .data = .{ .u64 = tag } };
    _ = linux.epoll_ctl(ep, linux.EPOLL.CTL_MOD, fd, &ev);
}

pub fn setTcpNodelay(fd: Fd) void {
    const one: u32 = 1;
    _ = linux.setsockopt(fd, linux.IPPROTO.TCP, linux.TCP.NODELAY, @ptrCast(&one), @sizeOf(u32));
}

// privileges and files

/// drop to an unprivileged uid/gid with no supplementary groups; verified, never assumed.
pub fn dropPrivileges(uid: u32, gid: u32) Error!void {
    const no_groups: [0]u32 = .{};
    _ = try check(linux.setgroups(0, &no_groups));
    _ = try check(linux.setresgid(gid, gid, gid));
    _ = try check(linux.setresuid(uid, uid, uid));
    if (linux.getuid() != uid) return error.Unexpected;
}

/// read a whole small file (procfs or a config file) into `buf`.
pub fn readFile(path: [*:0]const u8, buf: []u8) Error![]u8 {
    const fd = try open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    defer close(fd);
    var len: usize = 0;
    while (len < buf.len) {
        const n = read(fd, buf[len..]) catch |e| switch (e) {
            error.Interrupted => continue,
            else => return e,
        };
        if (n == 0) break;
        len += n;
    }
    return buf[0..len];
}

/// temp file, checked flush, atomic rename, directory flush; the last valid file survives a crash.
pub fn saveFileAtomic(dir_path: [*:0]const u8, tmp_path: [*:0]const u8, final_path: [*:0]const u8, bytes: []const u8) Error!void {
    const fd = try open(tmp_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o600);
    {
        defer close(fd);
        try writeAll(fd, bytes);
        _ = try check(linux.fsync(fd));
    }
    _ = try check(linux.rename(tmp_path, final_path));
    const dfd = try open(dir_path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
    defer close(dfd);
    _ = try check(linux.fsync(dfd));
}
