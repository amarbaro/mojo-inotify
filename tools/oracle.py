#!/usr/bin/env python3
"""Oracle and stand-in runner for the mojo-inotify gate.

usage: oracle.py SCRIPT      (run inside a fresh directory; paths in SCRIPT are relative)

Plays a scenario script against Linux inotify through libc (ctypes) and prints one
line per event. tests/cases.mojo plays the same scripts through the library; the gate
diffs the two outputs. Script ops, one per line, '#' starts a comment:
  watch P MASK      add a watch, MASK = NAME|NAME|... or a number; P is its label
  unwatch P         rm_watch the watch labelled P
  mkdir P  rmdir P  touch P  rm P  chmod P  mv A B  cat P
  write P TEXT...   open (truncate), one write() per TEXT, close
  append P TEXT...  same with O_APPEND
  burst N PREFIX    touch PREFIX0 .. PREFIX<N-1>
  ladder N DIR      touch DIR/n, DIR/nn, ... names of 1..N bytes
  poll MS           poll(2) the inotify fd: prints "poll ready" or "poll empty"
  drain             read until EAGAIN with a 4096 byte buffer, print each event
Event line: LABEL FLAG|FLAG NAME [cN]   (NAME is - when empty, cN = cookie by first sight)
Last line of every drain: "drained E events B bytes".
"""
import ctypes, os, select, struct, sys

BUF = 4096
FLAGS = [("ACCESS", 0x1), ("MODIFY", 0x2), ("ATTRIB", 0x4), ("CLOSE_WRITE", 0x8), ("CLOSE_NOWRITE", 0x10),
         ("OPEN", 0x20), ("MOVED_FROM", 0x40), ("MOVED_TO", 0x80), ("CREATE", 0x100), ("DELETE", 0x200),
         ("DELETE_SELF", 0x400), ("MOVE_SELF", 0x800), ("UNMOUNT", 0x2000), ("Q_OVERFLOW", 0x4000),
         ("IGNORED", 0x8000), ("ISDIR", 0x40000000)]
NAMES = dict(FLAGS, ALL=0xFFF)


def main():
    libc = ctypes.CDLL(None, use_errno=True)
    libc.inotify_add_watch.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_uint32]
    fd = libc.inotify_init1(os.O_NONBLOCK | os.O_CLOEXEC)
    labels, cookies = {}, {}
    for line in open(sys.argv[1]).read().splitlines():
        a = line.split("#")[0].split()
        if not a:
            continue
        op = a[0]
        if op == "watch":
            m = 0
            for t in a[2].split("|"):
                m |= int(t) if t.isdigit() else NAMES[t]
            wd = libc.inotify_add_watch(fd, a[1].encode(), m)
            if wd < 0:
                e = ctypes.get_errno()
                print(f"error inotify: add_watch '{a[1]}': {os.strerror(e)} (errno {e})")
            else:
                labels.setdefault(wd, a[1])
        elif op == "unwatch":
            libc.inotify_rm_watch(fd, [w for w, l in labels.items() if l == a[1]][0])
        elif op == "mkdir": os.mkdir(a[1])
        elif op == "rmdir": os.rmdir(a[1])
        elif op == "touch": os.close(os.open(a[1], os.O_CREAT | os.O_WRONLY, 0o644))
        elif op == "rm": os.unlink(a[1])
        elif op == "chmod": os.chmod(a[1], 0o600)
        elif op == "mv": os.rename(a[1], a[2])
        elif op == "cat":
            f = os.open(a[1], os.O_RDONLY)
            os.read(f, 64)
            os.close(f)
        elif op in ("write", "append"):
            f = os.open(a[1], os.O_CREAT | os.O_WRONLY | (os.O_APPEND if op == "append" else os.O_TRUNC), 0o644)
            for t in a[2:]:
                os.write(f, t.encode())
            os.close(f)
        elif op == "burst":
            for i in range(int(a[1])): os.close(os.open(f"{a[2]}{i}", os.O_CREAT | os.O_WRONLY, 0o644))
        elif op == "ladder":
            for k in range(1, int(a[1]) + 1): os.close(os.open(f"{a[2]}/{'n' * k}", os.O_CREAT | os.O_WRONLY, 0o644))
        elif op == "poll":
            p = select.poll()
            p.register(fd, select.POLLIN)
            print("poll ready" if p.poll(int(a[1])) else "poll empty")
        elif op == "drain":
            e = b = 0
            while True:
                try:
                    buf = os.read(fd, BUF)
                except BlockingIOError:
                    break
                b += len(buf)
                off = 0
                while off < len(buf):
                    wd, mask, cookie, n = struct.unpack_from("iIII", buf, off)
                    name = buf[off + 16:off + 16 + n].split(b"\0")[0].decode()
                    off += 16 + n
                    f = "|".join(s for s, v in FLAGS if mask & v)
                    c = ""
                    if cookie:
                        c = f" c{cookies.setdefault(cookie, len(cookies) + 1)}"
                    print(f"{labels.get(wd, '?')} {f} {name or '-'}{c}")
                    e += 1
            print(f"drained {e} events {b} bytes")
        else:
            sys.exit(f"FAIL oracle: unknown op {op}")
    os.close(fd)


main()
