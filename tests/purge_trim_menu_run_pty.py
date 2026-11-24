#!/usr/bin/env python3
"""Run the real `mo purge` menu in a PTY against a fixture HOME ($1, with one
Rust project at ~/www/rs) and tick both the whole `target` row and its trim
row, then confirm. Prints the confirm line, the plain transcript and the exit
status for the Bats case to assert on."""
import fcntl
import os
import pty
import re
import select
import struct
import subprocess
import sys
import termios
import time

home = sys.argv[1]
root = sys.argv[2]
env = dict(
    os.environ,
    HOME=home,
    TMPDIR=f"{home}/tmp",
    TERM="xterm-256color",
    MOLE_TEST_NO_AUTH="1",
    MOLE_TEST_TRASH_DIR=f"{home}/test-trash",
)
master, slave = pty.openpty()
fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 140, 0, 0))


def own_terminal() -> None:
    os.setsid()
    fcntl.ioctl(0, termios.TIOCSCTTY, 0)


p = subprocess.Popen([f"{root}/mole", "purge"], stdin=slave, stdout=slave, stderr=slave, env=env,
                     preexec_fn=own_terminal)
os.close(slave)
seen = b""


def read_some() -> bool:
    global seen
    if select.select([master], [], [], .05)[0]:
        try:
            chunk = os.read(master, 65536)
        except OSError:
            return False
        if not chunk:
            return False
        seen += chunk
    return True


def wait_for(marker: bytes, timeout: float = 60) -> None:
    deadline = time.monotonic() + timeout
    while marker not in seen:
        assert time.monotonic() < deadline, ("timeout", marker, seen[-2000:])
        assert read_some(), ("terminal ended", marker, seen[-2000:])


def plain(data: bytes) -> str:
    return re.sub(rb"\x1b\[[0-?]*[ -/]*[@-~]", b"", data).decode("utf-8", "replace").replace("\r", "")


try:
    wait_for(b"Select Artifacts to Purge")
    wait_for(b"\x1b[J")
    time.sleep(0.3)
    # Row 0 is the whole target (recent, so unticked), row 1 its trim.
    for key in (b" ", b"j", b" "):
        os.write(master, key)
        time.sleep(0.3)
    os.write(master, b"\r")
    wait_for(b"confirm, ")
    confirm = [line for line in plain(seen).splitlines() if "Remove " in line]
    print("CONFIRM " + (confirm[-1].strip() if confirm else "<none>"))
    time.sleep(0.3)
    os.write(master, b"\r")
    deadline = time.monotonic() + 60
    while p.poll() is None and time.monotonic() < deadline:
        read_some()
    while read_some() and select.select([master], [], [], 0)[0]:
        pass
    p.wait(timeout=5)
    print(plain(seen))
    print(f"EXIT {p.returncode}")
finally:
    if p.poll() is None:
        p.kill()
        p.wait()
    os.close(master)
