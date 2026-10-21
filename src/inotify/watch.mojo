from std.ffi import external_call, c_ssize_t

comptime IN_ACCESS: UInt32 = 0x1
comptime IN_MODIFY: UInt32 = 0x2
comptime IN_ATTRIB: UInt32 = 0x4
comptime IN_CLOSE_WRITE: UInt32 = 0x8
comptime IN_CLOSE_NOWRITE: UInt32 = 0x10
comptime IN_OPEN: UInt32 = 0x20
comptime IN_MOVED_FROM: UInt32 = 0x40
comptime IN_MOVED_TO: UInt32 = 0x80
comptime IN_CREATE: UInt32 = 0x100
comptime IN_DELETE: UInt32 = 0x200
comptime IN_DELETE_SELF: UInt32 = 0x400
comptime IN_MOVE_SELF: UInt32 = 0x800
comptime IN_ALL_EVENTS: UInt32 = 0xFFF
# reported by the kernel only
comptime IN_UNMOUNT: UInt32 = 0x2000
comptime IN_Q_OVERFLOW: UInt32 = 0x4000
comptime IN_IGNORED: UInt32 = 0x8000
comptime IN_ISDIR: UInt32 = 0x40000000
# add_watch options
comptime IN_ONLYDIR: UInt32 = 0x1000000
comptime IN_DONT_FOLLOW: UInt32 = 0x2000000
comptime IN_EXCL_UNLINK: UInt32 = 0x4000000
comptime IN_MASK_ADD: UInt32 = 0x20000000
comptime IN_ONESHOT: UInt32 = 0x80000000

comptime _NONBLOCK_CLOEXEC = Int32(0o4000 | 0o2000000)
comptime _POLLIN: Int64 = 1 << 32  # pollfd{fd, events, revents} packed little-endian: events = POLLIN
comptime _EINTR = 4
comptime _EAGAIN = 11
comptime _HEADER = 16  # struct inotify_event before the name
comptime MIN_BUFFER = 16 + 255 + 1  # one event with the longest name


def _errno() -> Int:
    return Int(external_call["__errno_location", Pointer[Int32, MutAnyOrigin]]()[])


def _error(what: String) -> Error:
    var e = _errno()
    var p = external_call["strerror", Pointer[UInt8, MutAnyOrigin]](Int32(e))
    var msg = StringSlice(unsafe_from_utf8=Span(unsafe_ptr=p, length=external_call["strlen", Int](p)))
    return Error("inotify: ", what, ": ", msg, " (errno ", e, ")")


struct Event(Defaultable, TrivialRegisterPassable):
    """One event, read in place from the Inotify buffer: 8 bytes, no copy.
    Valid until the next call to Inotify.next()."""

    var rec: Int  # address of the inotify_event record

    def __init__(out self):
        self.rec = 0

    def wd(self) -> Int32:
        return Pointer[Int32, ImmUntrackedOrigin](unsafe_from_address=self.rec)[]

    def mask(self) -> UInt32:
        return Pointer[UInt32, ImmUntrackedOrigin](unsafe_from_address=self.rec + 4)[]

    def cookie(self) -> UInt32:
        return Pointer[UInt32, ImmUntrackedOrigin](unsafe_from_address=self.rec + 8)[]

    def size(self) -> Int:
        """Bytes the record takes in the kernel stream: 16 plus the padded name."""
        return _HEADER + Int(Pointer[UInt32, ImmUntrackedOrigin](unsafe_from_address=self.rec + 12)[])

    def name(self) -> StringSlice[ImmUntrackedOrigin]:
        """File name inside a watched directory, empty for events on the watched path itself."""
        var cap = Int(Pointer[UInt32, ImmUntrackedOrigin](unsafe_from_address=self.rec + 12)[])
        var p = Pointer[UInt8, ImmUntrackedOrigin](unsafe_from_address=self.rec + _HEADER)
        var n = external_call["strnlen", Int](p, cap) if cap > 0 else 0
        return StringSlice(unsafe_from_utf8=Span(unsafe_ptr=p, length=n))


struct Inotify(Movable):
    """A non-blocking inotify instance with one read buffer. `fd()` is pollable."""

    var buf: List[UInt8]  # the only allocation, made once
    var cap: Int
    var len: Int  # bytes of the last read()
    var pos: Int  # offset of the next unparsed event
    var pfd: Int64  # a pollfd, reused by wait()
    var fdn: Int32

    def __init__(out self, buffer_size: Int = 16384) raises:
        if buffer_size < MIN_BUFFER:
            raise Error("inotify: buffer_size must be at least ", MIN_BUFFER)
        self.buf = List[UInt8](unsafe_uninit_length=buffer_size)
        self.cap = buffer_size
        self.len = 0
        self.pos = 0
        self.fdn = external_call["inotify_init1", Int32](_NONBLOCK_CLOEXEC)
        self.pfd = 0
        if self.fdn < 0:
            raise _error("init")
        self.pfd = _POLLIN | Int64(self.fdn)

    def __deinit__(deinit self):
        if self.fdn >= 0:
            _ = external_call["close", Int32](self.fdn)

    def fd(self) -> Int32:
        """The file descriptor, readable when events are queued: hand it to poll/epoll."""
        return self.fdn

    def add_watch(self, path: String, mask: UInt32) raises -> Int32:
        """Watch path for mask. Watching a path again updates its mask and returns the same wd."""
        var p = path
        var wd = external_call["inotify_add_watch", Int32](self.fdn, p.as_c_string_span().ptr(), mask)
        if wd < 0:
            raise _error("add_watch '" + path + "'")
        return wd

    def rm_watch(self, wd: Int32) raises:
        """Stop watching; the kernel queues an IN_IGNORED event for wd."""
        if external_call["inotify_rm_watch", Int32](self.fdn, wd) < 0:
            raise _error("rm_watch")

    def wait(mut self, timeout_ms: Int) raises -> Bool:
        """Block up to timeout_ms (-1 forever, 0 poll) until events are queued. Events already
        read into the buffer but not yet returned by next() count as ready."""
        if self.pos < self.len:
            return True
        while True:
            var r = external_call["poll", Int32](Pointer(to=self.pfd), UInt64(1), Int32(timeout_ms))
            if r >= 0:
                return r > 0
            if _errno() != _EINTR:
                raise _error("poll")

    def next(mut self, mut ev: Event) raises -> Bool:
        """Point ev at the next event; False when none is queued. Never blocks."""
        if self.pos >= self.len:
            var n = Int(external_call["__read", c_ssize_t](Int(self.fdn), self.buf.unsafe_ptr(), self.cap))
            while n < 0 and _errno() == _EINTR:
                n = Int(external_call["__read", c_ssize_t](Int(self.fdn), self.buf.unsafe_ptr(), self.cap))
            if n < 0:
                if _errno() == _EAGAIN:
                    return False
                raise _error("read")
            if n == 0:
                return False
            self.len = n
            self.pos = 0
        ev.rec = Int(self.buf.unsafe_ptr()) + self.pos
        self.pos += ev.size()
        return True

    def close(mut self):
        if self.fdn >= 0:
            _ = external_call["close", Int32](self.fdn)
            self.fdn = -1
