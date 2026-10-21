# Plays a scenario script (see tools/oracle.py for the ops) through the library and prints
# the same event lines as the oracle. Run it inside a fresh directory.
from std.ffi import external_call
from std.sys import argv
from inotify import Inotify, Event


def _open(path: String, flags: Int32) -> Int32:
    var p = path
    return external_call["open", Int32, num_fixed_args=2](p.as_c_string_span().ptr(), flags, Int32(0o644))


def _touch(path: String, flags: Int32 = 0o101):  # O_WRONLY | O_CREAT
    _ = external_call["close", Int32](_open(path, flags))


def _path[op: StaticString](p: String) -> Int32:
    var q = p
    return external_call[op, Int32](q.as_c_string_span().ptr())


def _mask(spec: StringSlice, names: List[String], vals: List[UInt32]) raises -> UInt32:
    var m = UInt32(0)
    for t in spec.split("|"):
        if t.as_bytes()[0] <= 57:
            m |= UInt32(atol(t))
        elif t == "ALL":
            m |= 0xFFF
        else:
            for i in range(len(names)):
                if names[i] == t:
                    m |= vals[i]
    return m


def main() raises:
    var names: List[String] = ["ACCESS", "MODIFY", "ATTRIB", "CLOSE_WRITE", "CLOSE_NOWRITE", "OPEN", "MOVED_FROM",
                               "MOVED_TO", "CREATE", "DELETE", "DELETE_SELF", "MOVE_SELF", "UNMOUNT", "Q_OVERFLOW",
                               "IGNORED", "ISDIR"]
    var vals: List[UInt32] = [0x1, 0x2, 0x4, 0x8, 0x10, 0x20, 0x40, 0x80, 0x100, 0x200, 0x400, 0x800, 0x2000,
                              0x4000, 0x8000, 0x40000000]
    var ino = Inotify(4096)
    var labels = Dict[Int32, String]()
    var cookies = Dict[UInt32, Int]()
    for line in open(argv()[1], "r").read().splitlines():
        var a = line.split("#")[0].split()
        if len(a) == 0:
            continue
        var op = a[0]
        if op == "watch":
            try:
                var wd = ino.add_watch(String(a[1]), _mask(a[2], names, vals))
                if wd not in labels:
                    labels[wd] = String(a[1])
            except e:
                print("error", e)
        elif op == "unwatch":
            for kv in labels.items():
                if kv.value == a[1]:
                    ino.rm_watch(kv.key)
                    break
        elif op == "mkdir":
            var p = String(a[1])
            _ = external_call["mkdir", Int32](p.as_c_string_span().ptr(), Int(0o755))
        elif op == "rmdir":
            _ = _path["rmdir"](String(a[1]))
        elif op == "touch":
            _touch(String(a[1]))
        elif op == "rm":
            _ = _path["unlink"](String(a[1]))
        elif op == "chmod":
            var p = String(a[1])
            _ = external_call["chmod", Int32](p.as_c_string_span().ptr(), Int32(0o600))
        elif op == "mv":
            var f = String(a[1])
            var t = String(a[2])
            _ = external_call["rename", Int32](f.as_c_string_span().ptr(), t.as_c_string_span().ptr())
        elif op == "cat":
            var fd = _open(String(a[1]), 0)
            var b = Int64(0)
            _ = external_call["read", Int](Int(fd), Pointer(to=b), 8)
            _ = external_call["close", Int32](fd)
        elif op == "write" or op == "append":
            var fd = _open(String(a[1]), Int32(0o2101) if op == "append" else Int32(0o1101))
            for i in range(2, len(a)):
                _ = external_call["write", Int](Int(fd), a[i].unsafe_ptr(), a[i].byte_length())
            _ = external_call["close", Int32](fd)
        elif op == "burst":
            for i in range(atol(a[1])):
                _touch(String(a[2]) + String(i))
        elif op == "ladder":
            for k in range(1, atol(a[1]) + 1):
                _touch(String(a[2]) + "/" + String("n") * k)
        elif op == "poll":
            print("poll ready" if ino.wait(atol(a[1])) else "poll empty")
        elif op == "drain":
            var ev = Event()
            var count = 0
            var bytes = 0
            while ino.next(ev):
                var out = labels.get(ev.wd(), "?") + " "
                var first = True
                for i in range(len(names)):
                    if ev.mask() & vals[i] != 0:
                        out += ("" if first else "|") + names[i]
                        first = False
                var n = ev.name()
                out += " " + (String(n) if n.byte_length() > 0 else "-")
                if ev.cookie() != 0:
                    if ev.cookie() not in cookies:
                        cookies[ev.cookie()] = len(cookies) + 1
                    out += " c" + String(cookies[ev.cookie()])
                print(out)
                count += 1
                bytes += ev.size()
            print("drained", count, "events", bytes, "bytes")
        else:
            print("FAIL cases: unknown op", op)
            raise Error("unknown op")
