# API

Everything here is asserted in `tests/api.mojo` or played by `tests/scenarios/*.txt`
against the Python oracle. `from inotify import ...`.

## Inotify

| Call | Behaviour |
|---|---|
| `Inotify(buffer_size=16384)` | Creates a non-blocking, close-on-exec instance. `buffer_size` below 272 (one event with the longest name) raises `inotify: buffer_size must be at least 272`. |
| `fd() -> Int32` | The descriptor. It is readable when events are queued, so it works with `poll` and `epoll`. |
| `add_watch(path, mask) -> Int32` | Returns the watch descriptor (`wd`). A path watched again keeps its `wd` and gets the new mask, unless `IN_MASK_ADD` is set, which adds to the old one. |
| `rm_watch(wd)` | Removes the watch; the kernel queues an `IN_IGNORED` event for it. An unknown `wd` raises `inotify: rm_watch: Invalid argument (errno 22)`. |
| `wait(timeout_ms) -> Bool` | `poll(2)` on `fd()`. `-1` waits forever, `0` only checks. Returns True at once when a read buffer still holds events `next()` has not returned. Restarts on `EINTR`. |
| `next(mut ev) -> Bool` | Points `ev` at the next event, reading from the kernel only when the buffer is empty. Returns False when none is queued; never blocks. A queue larger than the buffer is read in pieces. |
| `close()` | Closes the descriptor. Calling it twice is fine; `next()` after it raises `Bad file descriptor`. The destructor closes too. |

Errors raise `Error("inotify: <call> ...: <strerror> (errno N)")`; for `add_watch` the
call text includes the path in quotes.

An `Inotify` can be returned from a function or moved: the moved-from value does not close
the descriptor.

## Event

| Call | Behaviour |
|---|---|
| `wd() -> Int32` | The watch descriptor `add_watch` returned. `-1` for `IN_Q_OVERFLOW`. |
| `mask() -> UInt32` | The `IN_*` bits, including `IN_ISDIR` for a directory. |
| `cookie() -> UInt32` | `0`, except that the `IN_MOVED_FROM` and `IN_MOVED_TO` of one rename carry the same non-zero value. |
| `name() -> StringSlice` | The name inside a watched directory; empty when the event is on the watched path itself, and for `IN_IGNORED`. Points into the buffer. |
| `size() -> Int` | Bytes of this record in the kernel stream: 16 plus the name padded to a multiple of 16. |

An `Event` is 8 bytes and valid until the next call to `next()` on the same `Inotify`.

## Constants

`IN_ACCESS IN_MODIFY IN_ATTRIB IN_CLOSE_WRITE IN_CLOSE_NOWRITE IN_OPEN IN_MOVED_FROM
IN_MOVED_TO IN_CREATE IN_DELETE IN_DELETE_SELF IN_MOVE_SELF IN_ALL_EVENTS` are watch masks.
`IN_UNMOUNT IN_Q_OVERFLOW IN_IGNORED IN_ISDIR` appear in events. `IN_ONLYDIR
IN_DONT_FOLLOW IN_EXCL_UNLINK IN_MASK_ADD IN_ONESHOT` change how a watch is added.

## Kernel behaviour the oracle pins down

- Consecutive identical events merge: `write f a b c` on one open file queues one
  `IN_MODIFY`.
- A directory watch reports `IN_CREATE`, `IN_OPEN`, `IN_CLOSE_WRITE` for a new file; a
  watch on the file itself reports `IN_OPEN` etc. with an empty name.
- Moving a watched directory queues `IN_MOVE_SELF` on its own watch.
- Deleting a watched path queues `IN_DELETE_SELF`, then `IN_IGNORED`.
- 1,000 files created under a `CREATE|CLOSE_WRITE` watch arrive in order, 2,000 events,
  read through a 4,096-byte buffer.
