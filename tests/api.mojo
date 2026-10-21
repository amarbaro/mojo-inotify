# Edge cases a binding gets wrong: buffer limits, moves, views, errors, polling, reuse.
from std.ffi import external_call
from std.os import mkdir, remove
from std.testing import assert_equal, assert_true, assert_false, assert_raises
from inotify import Inotify, Event, IN_CREATE, IN_DELETE, IN_MOVED_FROM, IN_MOVED_TO, IN_ISDIR, IN_ONLYDIR, IN_IGNORED, IN_MASK_ADD, IN_ALL_EVENTS


def touch(path: String) raises:
    with open(path, "w") as f:
        f.write("")


def rename(a: String, b: String):
    var x = a
    var y = b
    _ = external_call["rename", Int32](x.as_c_string_span().ptr(), y.as_c_string_span().ptr())


def made() raises -> Inotify:
    # moved out of this frame: the moved-from value must not close the fd
    return Inotify()


def main() raises:
    var base = String(".work/api")
    try:
        mkdir(".work")
    except:
        pass
    try:
        mkdir(base)
    except:
        pass
    var d = base + "/d"
    mkdir(d)

    with assert_raises(contains="buffer_size must be at least 272"):
        _ = Inotify(271)

    var ino = made()
    var ev = Event()
    assert_false(ino.next(ev))  # empty queue: no block, no error
    assert_false(ino.wait(0))

    var wd = ino.add_watch(d, IN_CREATE | IN_DELETE | IN_MOVED_FROM | IN_MOVED_TO)
    assert_equal(ino.add_watch(d, IN_CREATE), wd)  # same path, same wd, mask replaced

    touch(d + "/a")
    assert_true(ino.wait(0))
    assert_true(ino.wait(-1))  # events queued: -1 returns at once
    assert_true(ino.wait(0))  # waiting does not consume
    assert_true(ino.next(ev))
    assert_equal(ev.wd(), wd)
    assert_equal(ev.mask(), IN_CREATE)
    assert_equal(ev.name(), "a")
    assert_equal(ev.size(), 32)  # 16 + name padded to 16
    assert_equal(ev.cookie(), UInt32(0))
    assert_false(ino.next(ev))  # IN_CREATE only after the replace: nothing else queued

    # IN_MASK_ADD keeps the old bits
    _ = ino.add_watch(d, IN_DELETE | IN_MASK_ADD)
    mkdir(d + "/sub")
    remove(d + "/a")
    assert_true(ino.next(ev))
    assert_equal(ev.mask(), IN_CREATE | IN_ISDIR)
    assert_equal(ev.name(), "sub")
    assert_true(ino.next(ev))
    assert_equal(ev.mask(), IN_DELETE)
    assert_equal(ev.name(), "a")
    assert_false(ino.next(ev))

    # a rename queues a pair with one cookie; wait() counts events already read into the buffer
    _ = ino.add_watch(d, IN_MOVED_FROM | IN_MOVED_TO | IN_MASK_ADD)
    rename(d + "/sub", d + "/sub2")
    assert_true(ino.next(ev))
    var cookie = ev.cookie()
    assert_true(cookie != 0)
    assert_equal(ev.mask(), IN_MOVED_FROM | IN_ISDIR)
    assert_true(ino.wait(0))  # the second record is parsed from the buffer, not the kernel
    assert_true(ino.next(ev))
    assert_equal(ev.cookie(), cookie)
    assert_equal(ev.name(), "sub2")

    # rm_watch queues IN_IGNORED for the wd; a bad wd raises
    ino.rm_watch(wd)
    assert_true(ino.next(ev))
    assert_equal(ev.mask(), IN_IGNORED)
    assert_equal(ev.wd(), wd)
    assert_equal(ev.name(), "")
    with assert_raises(contains="rm_watch: Invalid argument (errno 22)"):
        ino.rm_watch(wd)

    # errors carry strerror and errno
    with assert_raises(contains="add_watch 'nosuch': No such file or directory (errno 2)"):
        _ = ino.add_watch("nosuch", IN_CREATE)
    touch(base + "/x")
    with assert_raises(contains="Not a directory (errno 20)"):
        _ = ino.add_watch(base + "/x", IN_ONLYDIR)

    # the smallest buffer holds the longest name, and a queue larger than the buffer is read in pieces
    var small = Inotify(272)
    var w2 = small.add_watch(d, IN_CREATE)
    var longest = String("n") * 255
    touch(d + "/" + longest)
    for i in range(1, 255):
        touch(d + "/" + String("m") * i)
    var seen = 0
    assert_true(small.next(ev))
    assert_equal(ev.name(), longest)
    assert_equal(ev.size(), 16 + 256)
    seen += 1
    while small.next(ev):
        seen += 1
        assert_equal(ev.name().byte_length(), seen - 1)
    assert_equal(seen, 255)
    assert_equal(w2, Int32(1))

    # close() is idempotent; reading a closed instance raises instead of reading fd -1 or a reused fd
    small.close()
    small.close()
    with assert_raises(contains="Bad file descriptor"):
        _ = small.next(ev)
    # destructor after an explicit close does not close twice (second instance keeps its fd)
    var other = Inotify()
    assert_true(other.fd() >= 0)
    assert_false(other.next(ev))
