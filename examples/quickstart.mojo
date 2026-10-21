from std.os import mkdir, remove
from inotify import Inotify, Event, IN_CREATE, IN_DELETE


def main() raises:
    try:
        mkdir(".work")
    except:
        pass
    try:
        mkdir(".work/quick")
    except:
        pass
    var ino = Inotify()
    _ = ino.add_watch(".work/quick", IN_CREATE | IN_DELETE)
    with open(".work/quick/hello.txt", "w") as f:
        f.write("hi")
    remove(".work/quick/hello.txt")
    var ev = Event()
    while ino.wait(100) and ino.next(ev):
        print("created" if ev.mask() & IN_CREATE != 0 else "deleted", ev.name())
