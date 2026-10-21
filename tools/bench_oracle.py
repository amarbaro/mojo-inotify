"""Same work as tests/bench.mojo with Python ctypes + os + struct."""
import ctypes, os, struct, sys, time
ROUNDS, FILES = 20, 5000
d = sys.argv[1]
os.mkdir(d)
libc = ctypes.CDLL(None, use_errno=True)
fd = libc.inotify_init1(os.O_NONBLOCK | os.O_CLOEXEC)
libc.inotify_add_watch(fd, d.encode(), 0x100 | 0x8)
paths = [f"{d}/f{i}" for i in range(FILES)]
events = check = 0
t = 0.0
unpack = struct.Struct("iIII").unpack_from
for _ in range(ROUNDS):
    for p in paths:
        os.close(os.open(p, os.O_CREAT | os.O_WRONLY, 0o644))
    t0 = time.perf_counter()
    while True:
        try:
            buf = os.read(fd, 65536)
        except BlockingIOError:
            break
        off, n = 0, len(buf)
        while off < n:
            wd, mask, _c, ln = unpack(buf, off)
            name = buf[off + 16:off + 16 + ln].split(b"\0", 1)[0]
            events += 1
            check += wd + mask + len(name)
            off += 16 + ln
    t += time.perf_counter() - t0
    for p in paths:
        os.unlink(p)
print("drain_ms", int(t * 1000), "events", events, "check", check)
