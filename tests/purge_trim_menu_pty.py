#!/usr/bin/env python3
"""Drive the real purge selector in a PTY with one Rust target and its trim row
(fabricated metadata only): the trim starts unticked, adds its size alone, and
adds nothing while its whole target row is ticked."""
import fcntl
import os
import pty
import re
import select
import struct
import subprocess
import tempfile
import termios
import time
from pathlib import Path

root = Path(__file__).resolve().parents[1]
fixture = tempfile.TemporaryDirectory(prefix="mole-purge-trim-menu-")
home = Path(fixture.name)
env = dict(
    os.environ,
    HOME=str(home),
    TEST_ROOT=str(root),
    TERM='xterm-256color',
    MOLE_TEST_NO_AUTH='1',
    MOLE_DRY_RUN='1',
    XDG_CACHE_HOME=str(home / '.cache'),
)
# Row 0: the whole target, 1024 KB, old (ticked). Row 1: its trim, 256 KB.
# Row 2: another project's dist, 2048 KB, recent (unticked).
script = r'''
source "$TEST_ROOT/lib/clean/project.sh"
categories=("target" "  trim" "dist")
PURGE_CATEGORY_PROJECT_IDS_ARRAY=(p1 p1 p2)
PURGE_CATEGORY_PROJECT_PATHS_ARRAY=(/fixture/rs /fixture/rs /fixture/web)
PURGE_CATEGORY_FULL_PATHS_ARRAY=(/fixture/rs/target "/fixture/rs/target (trim)" /fixture/web/dist)
PURGE_CATEGORY_SIZE_UNKNOWN_FLAGS_ARRAY=(false false false)
PURGE_CATEGORY_SIZES=1024,256,2048
PURGE_RECENT_CATEGORIES=false,true,true
PURGE_AGE_LABELS=30d,30d,1d
PURGE_COVERED_ROWS=-1,0,-1
if select_purge_categories "${categories[@]}"; then echo "TEST_ACCEPTED $PURGE_SELECTION_RESULT"; else echo TEST_CANCELLED; fi
'''
ansi = re.compile(rb'\x1b\[[0-?]*[ -/]*[@-~]')


def plain(frame: bytes) -> str:
    return ansi.sub(b'', frame).decode('utf-8').replace('\r', '')


master, slave = pty.openpty()
fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack('HHHH', 30, 120, 0, 0))


def own_terminal() -> None:
    os.setsid()
    fcntl.ioctl(0, termios.TIOCSCTTY, 0)


p = subprocess.Popen(['/bin/bash', '--noprofile', '--norc', '-c', script],
                     stdin=slave, stdout=slave, stderr=slave, env=env, preexec_fn=own_terminal)
os.close(slave)
pending = b''


def receive(marker: bytes = b'\x1b[J') -> bytes:
    global pending
    deadline = time.monotonic() + 10
    while marker not in pending:
        assert time.monotonic() < deadline, ('timeout', pending[-1000:])
        if select.select([master], [], [], .05)[0]:
            chunk = os.read(master, 65536)
            assert chunk, ('EOF', pending[-1000:])
            pending += chunk
    end = pending.index(marker) + len(marker)
    frame, pending = pending[:end], pending[end:]
    return frame


def subtitle(frame: bytes) -> str:
    for line in plain(frame).splitlines():
        if ' selected' in line and 'Project:' not in line:
            return line.strip()
    raise AssertionError(plain(frame))


def press(keys: bytes) -> str:
    os.write(master, keys)
    return subtitle(receive())


try:
    first = receive()
    assert 'trim' in plain(first), plain(first)
    # Only the old whole target starts ticked; the trim never does.
    assert subtitle(first) == '1.0MB, 1 selected', subtitle(first)
    # Ticking the trim under a ticked whole target adds nothing.
    assert press(b'j') == '1.0MB, 1 selected'
    assert press(b' ') == '1.0MB, 1 selected'
    # Unticking the whole target leaves the trim's own size.
    assert press(b'k') == '1.0MB, 1 selected'
    assert press(b' ') == '262KB, 1 selected'
    # Ticking the whole target again takes the trim back out of the count.
    assert press(b' ') == '1.0MB, 1 selected'
    # Select all: whole + trim + dist, the trim adding nothing under its whole.
    assert press(b'a') == '3.1MB, 2 selected'
    os.write(master, b'\n')
    result = b''
    deadline = time.monotonic() + 10
    while b'TEST_' not in result or not result.rstrip().endswith((b'0,1,2', b'CANCELLED')):
        assert time.monotonic() < deadline, ('no result', result[-500:])
        if select.select([master], [], [], .05)[0]:
            try:
                chunk = os.read(master, 65536)
            except OSError:
                break
            if not chunk:
                break
            result += chunk
    assert b'TEST_ACCEPTED 0,1,2' in result, result[-500:]
finally:
    try:
        p.kill()
    except ProcessLookupError:
        pass
    p.wait()
    os.close(master)
