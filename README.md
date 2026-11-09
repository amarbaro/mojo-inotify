# mojo-inotify

<!-- badges -->
[![ci](https://github.com/amarbaro/mojo-inotify/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/amarbaro/mojo-inotify/actions/workflows/ci.yml) [![latest release](https://img.shields.io/github/v/release/amarbaro/mojo-inotify)](https://github.com/amarbaro/mojo-inotify/releases/latest) [![license](https://img.shields.io/github/license/amarbaro/mojo-inotify)](https://github.com/amarbaro/mojo-inotify/blob/main/LICENSE)
<!-- /badges -->

<!-- install -->
Install: `pixi workspace channel add https://conda.modular.com/max https://prefix.dev/amarbaro/amarbaro`, then `pixi add mojo-inotify` (import `inotify`). From source: `git clone https://github.com/amarbaro/mojo-inotify`, then `mojo run -I mojo-inotify/src app.mojo`.
Toolchains: Mojo 1.2 stable, and the nightly 1.3.0.dev2026110805 in the weekly [mojo-libs](https://github.com/amarbaro/mojo-libs) matrix (36 libraries on stable, 35 on nightly).

```mojo
from std.os import remove
from inotify import Inotify, Event, IN_CREATE, IN_DELETE


def main() raises:
    var ino = Inotify()
    _ = ino.add_watch(".", IN_CREATE | IN_DELETE)  # the current directory
    with open("quickstart.tmp", "w") as f:
        f.write("hi")
    remove("quickstart.tmp")
    var ev = Event()
    while ino.wait(100) and ino.next(ev):
        print("created" if ev.mask() & IN_CREATE != 0 else "deleted", ev.name())
```
<!-- /install -->

Watch files and directories from Mojo with Linux inotify. One read buffer, events read in
place, a file descriptor you can `poll`. Its event streams are checked against a Python
`ctypes` oracle on the same inotify calls, and it drains events 3.3× faster than Python.

Requires Mojo 1.2 on Linux. The calls go straight to libc, so no linker flags.

## What you get

- `Inotify(buffer_size=16384)`: a non-blocking inotify instance. The read buffer is the
  only allocation, made once.
- `add_watch(path, mask)`, `rm_watch(wd)`, `close()`.
- `next(ev)`: points `ev` at the next event. It never blocks and never allocates.
- `wait(timeout_ms)`: block until events are queued (`poll(2)`).
- `fd()`: the descriptor, for your own `poll` or `epoll` loop.
- `Event`: 8 bytes. `wd()`, `mask()`, `cookie()`, `name()` (a `StringSlice` into the
  buffer), `size()`.
- Every `IN_*` constant.
- Errors carry libc's message: `inotify: add_watch 'x': No such file or directory (errno 2)`.

The API is in [docs/api.md](docs/api.md). The memory and speed design is in
[docs/design.md](docs/design.md).

## Performance

`tests/bench.mojo` against `tools/bench_oracle.py`: 20 rounds of 5,000 files created and
unlinked in a watched directory, 10,000 events a round, 200,000 events in all. Only the
drain is timed. Three runs each.

| | drain 200k events | peak RSS |
|---|---|---|
| Python `ctypes` + `struct` | 121 to 125 ms | 11.5 to 11.9 MB |
| mojo-inotify | 37 to 38 ms | 11.6 to 11.9 MB |

The `read` syscalls alone take 36 to 38 ms, so parsing costs nothing measurable. The
memory is the same because both are dominated by the runtime: an empty Mojo program uses
11.6 MB.

## Limits

- Linux only. One `Inotify` per thread: do not share it.
- Not recursive: a watch covers one directory, not its subdirectories.
- An `Event` is valid until the next `next()`: copy `name()` with `String(...)` to keep it.
- A full kernel queue (default 16,384 events) ends in one `IN_Q_OVERFLOW` event with `wd` -1.
  The library hands it to you like any event and does not recover; the gate does not cover
  overflow.
- No `fanotify`, no `epoll` wrapper: use `fd()`.
