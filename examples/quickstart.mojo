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
