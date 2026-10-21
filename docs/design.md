# Design

Three rules: the event stream is never copied, nothing is allocated after `Inotify()`
returns, and nothing is looked up at run time.

## One buffer, events parsed in place

`Inotify` allocates its read buffer once (a `List[UInt8]`, default 16 KiB). `next()` calls
`read(2)` only when the buffer is used up; otherwise it moves a cursor. The `Event` it
fills is one `Int`, the address of the kernel's record: `wd()`, `mask()`, `cookie()` read
the fields where they lie, and `name()` is a `StringSlice` over the name bytes (`strnlen`
trims the kernel's NUL padding).

| | drain 200k events |
|---|---|
| `read` into the buffer, no parsing (floor) | 36 to 38 ms |
| `next()` with `Event` views | 37 to 38 ms |
| `next()` plus `String(ev.name())` per event | 39 to 41 ms |
| Python `struct.unpack_from` + slice per event | 121 to 125 ms |

The loop is at the syscall floor, so the view costs nothing. The copy of the name adds
about 10 ns an event; short names fit inline in a `String`, so it does not even allocate.
`Event` is 8 bytes (`size_of`, measured); `Inotify` is 64: the list (24), `cap`, `len`,
`pos` and the reused `pollfd` (8 each), then the 4-byte descriptor, widest first.

The kernel hands out whole records and pads every name to a multiple of 16, so the buffer
is 16-byte aligned from the allocator and every field read is aligned. The smallest legal
buffer, 272 bytes, holds the longest name (255 + NUL + 16); `tests/api.mojo` reads 255
events through it.

## libc by direct call, not dlopen

`inotify_*`, `read`, `poll` are in the process already, so `external_call` links them at
build time: no `dlopen`, no `dlsym` on the hot path. (mojo-sqlite measured `dlsym` per call
at 42 ns against 1 ns for a cached address; here there is nothing to resolve.)

One trap, found building the runner: the Mojo standard library declares some libc symbols
with its own signature (`read` and `write` take the descriptor as `Int`, `mkdir` takes the
mode as `Int`, `strerror` and `__errno_location` return a `Pointer`). Declaring the same
symbol again with another argument type compiles alone and fails in the whole program with
`existing function with conflicting signature`. The library therefore calls `read` with
`Int(fd)` and reads `errno` through `__errno_location`'s `Pointer`.

## Pollable, never blocking

The descriptor is `IN_NONBLOCK`, so `next()` returns False on `EAGAIN` and the caller owns
the waiting: `wait()` is `poll(2)` on a `pollfd` kept in the struct (no allocation per
call), or hand `fd()` to your own loop. `wait()` returns True when events are parsed-but-
not-returned, so `while ino.wait(t): while ino.next(ev)` never sleeps with work in hand.

## Why the gate looks like this

Kernel event order and coalescing are the behaviour, so the oracle is the kernel through
Python: `tools/oracle.py` and `tests/cases.mojo` play the same script (watch, create,
write, move, delete, burst) and print the same lines. `scripts/check.sh` runs every
scenario twice in fresh directories through each, and all four outputs must match.
`scripts/selfcheck.sh` shows the gate rejects a runner that drops a line, changes a flag,
loses a record, or varies from run to run.
