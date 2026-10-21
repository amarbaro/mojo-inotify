---
name: mojo-inotify
description: "Watch files and directories from Mojo with inotify: add_watch, wait, next, Event views, pollable fd. Use when Mojo code must react to file creation, change, move or delete on Linux."
---

# mojo-inotify

inotify for Mojo 1.1 on Linux, straight to libc. Event streams are checked against a Python
`ctypes` oracle.

## Install

`mojo run -I <repo>/src app.mojo`, or `mojo precompile <repo>/src/inotify -o inotify.mojoc`,
or copy `src/inotify/`.

## Use

```mojo
from inotify import Inotify, Event, IN_CREATE, IN_CLOSE_WRITE

def main() raises:
    var ino = Inotify()
    _ = ino.add_watch("inbox", IN_CREATE | IN_CLOSE_WRITE)
    var ev = Event()
    while ino.wait(-1):
        while ino.next(ev):
            if ev.mask() & IN_CLOSE_WRITE != 0:
                print("ready:", ev.name())
```

## Rules

- `next(ev)` never blocks: False means the queue is empty. Block with `wait(ms)` (`-1` forever)
  or poll `fd()` yourself.
- An `Event` points into the read buffer: valid until the next `next()`. Keep a name with
  `String(ev.name())`.
- Watches are per directory, not recursive. Add a watch for each new subdirectory on its
  `IN_CREATE | IN_ISDIR` event.
- A finished write is `IN_CLOSE_WRITE`, not `IN_MODIFY` (which fires per write and merges).
- A rename gives `IN_MOVED_FROM` then `IN_MOVED_TO` with the same `cookie()`.
- `buffer_size` must be at least 272. A queue over 16,384 events overflows: one `IN_Q_OVERFLOW`
  event, `wd` -1; rescan the directory.
- Calling a libc symbol the standard library already declares, with other argument types,
  fails the build with `existing function with conflicting signature`: use `Int` for fds in
  `read`/`write`.
- Errors: `inotify: add_watch 'p': No such file or directory (errno 2)`.
