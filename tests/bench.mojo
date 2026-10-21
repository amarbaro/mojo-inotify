# Drain speed: 20 rounds of 5,000 files created and unlinked in a watched dir
# (CREATE|CLOSE_WRITE = 10,000 events per round, under the 16,384 queue limit).
# Only drain() is timed. Same work as tools/bench_oracle.py. argv[1] = a fresh directory.
from std.ffi import external_call
from std.sys import argv
from std.time import perf_counter_ns
from std.os import mkdir
from inotify import Inotify, Event, IN_CREATE, IN_CLOSE_WRITE


def main() raises:
    comptime ROUNDS = 20
    comptime FILES = 5000
    var dir = argv()[1]
    mkdir(dir)
    var paths = List[String](capacity=FILES)
    for i in range(FILES):
        paths.append(dir + "/f" + String(i))
    var ino = Inotify(65536)
    _ = ino.add_watch(dir, IN_CREATE | IN_CLOSE_WRITE)
    var ev = Event()
    var events = 0
    var check = 0
    var ns = 0
    for _ in range(ROUNDS):
        for ref p in paths:
            _ = external_call["close", Int32](external_call["open", Int32, num_fixed_args=2](p.as_c_string_span().ptr(), Int32(0o101), Int32(0o644)))
        var t0 = perf_counter_ns()
        while ino.next(ev):
            events += 1
            check += Int(ev.wd()) + Int(ev.mask()) + ev.name().byte_length()
        ns += Int(perf_counter_ns() - t0)
        for ref p in paths:
            _ = external_call["unlink", Int32](p.as_c_string_span().ptr())
    print("drain_ms", ns // 1000000, "events", events, "check", check)
