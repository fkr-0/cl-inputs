#!/usr/bin/env python3
"""Kernel-backed cl-inputs PTY end-to-end qualification (Linux, SBCL, CLPM).

Creates a real POSIX PTY; the child opens its slave with the public :tty
backend. The parent injects fragmentary input, checks termios and observes
actual terminal output, then proves termios restoration and clean process exit.

Usage (from repo root): python3 tests/pty-e2e.py
"""
from __future__ import annotations

import errno
import os
from pathlib import Path
import pty
import select
import shutil
import subprocess
import sys
import termios
import time


ROOT = Path(__file__).resolve().parents[1]
TIME_LIMIT = 35.0


def require(condition: bool, explanation: str) -> None:
    if not condition:
        raise AssertionError(explanation)


def run() -> None:
    require(sys.platform.startswith("linux"), "PTY E2E requires Linux")
    require(shutil.which("clpm") is not None, "CLPM executable not found")
    master, slave = pty.openpty()
    child: subprocess.Popen[bytes] | None = None
    try:
        original = termios.tcgetattr(slave)
        env = os.environ.copy()
        env["CL_INPUTS_PTY_SLAVE"] = os.ttyname(slave)
        env.setdefault("TERM", "xterm-256color")
        env.setdefault("CLPM_HOME", ".cache/clpm")
        child = subprocess.Popen(
            [
                "clpm", "bundle", "exec", "--with-client", "sbcl", "--",
                "--noinform", "--non-interactive", "--load",
                "tests/pty-scenario.lisp",
            ],
            cwd=ROOT,
            env=env,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            bufsize=0,
        )
        assert child.stdout is not None
        output_fd = child.stdout.fileno()
        pending = b""
        transcript = bytearray()
        terminal_output = bytearray()
        stages: list[str] = []
        start = time.monotonic()
        fds = [output_fd, master]

        while fds and time.monotonic() - start < TIME_LIMIT:
            ready, _, _ = select.select(fds, [], [], 0.15)
            for fd in ready:
                try:
                    data = os.read(fd, 16384)
                except OSError as error:
                    if fd == master and error.errno in (errno.EIO, errno.EBADF):
                        fds.remove(fd)
                        continue
                    raise
                if not data:
                    fds.remove(fd)
                    continue
                if fd == master:
                    terminal_output.extend(data)
                    continue
                transcript.extend(data)
                pending += data
                while b"\n" in pending:
                    line, pending = pending.split(b"\n", 1)
                    if b"@@PTY:" not in line:
                        continue
                    stage = line.split(b"@@PTY:", 1)[1].strip().decode("ascii")
                    stages.append(stage)
                    if stage == "READY input":
                        flags = termios.tcgetattr(slave)
                        require(not flags[3] & termios.ICANON, "ICANON still enabled")
                        require(not flags[3] & termios.ECHO, "ECHO still enabled")
                        require(bool(flags[3] & termios.ISIG), "ISIG not preserved")
                        require(
                            flags[1] & termios.OPOST == original[1] & termios.OPOST,
                            "OPOST unexpectedly changed",
                        )
                        # Split both UTF-8 and the CSI arrow sequence.
                        os.write(master, b"a\xc3")
                        time.sleep(0.02)
                        os.write(master, b"\xa9\x1b[")
                        time.sleep(0.02)
                        os.write(master, b"A\x1b[I\x1b[<0;3;4M\x1b[200~hello \xce")
                        time.sleep(0.02)
                        os.write(master, b"\xbb\x1b[201~")
                    elif stage == "READY reply":
                        os.write(master, b"k\x1b[6;13R")
                    elif stage == "READY malformed":
                        os.write(master, b"\x1b[12;Rq")
                    elif stage == "READY close":
                        pass
                    elif stage == "RESTORED source":
                        stage_flags = termios.tcgetattr(slave)
                        require(stage_flags == original,
                                f"owned source failed to restore original termios: before={original!r}, after={stage_flags!r}, child={bytes(transcript)[-2000:]!r}")
                        assert child.stdin is not None
                        child.stdin.write(b"resume\n")
                        child.stdin.flush()
                    elif stage == "DONE":
                        break
            if "DONE" in stages and child.poll() is not None:
                # Continue draining the PTY so no terminal writes are missed.
                break

        try:
            status = child.wait(timeout=2)
        except subprocess.TimeoutExpired:
            raise AssertionError("Child did not terminate after PTY scenario")
        # Drain remaining output even when the child has already exited.
        for _ in range(5):
            readable, _, _ = select.select([master], [], [], 0.05)
            if not readable:
                break
            try:
                data = os.read(master, 16384)
            except OSError as error:
                if error.errno == errno.EIO:
                    break
                raise
            if not data:
                break
            terminal_output.extend(data)
        tail = bytes(transcript).decode("utf-8", errors="replace")[-6000:]
        require(status == 0, f"Child exited {status}:\n{tail}")
        require(stages == ["READY input", "READY reply", "READY malformed", "READY close", "RESTORED source", "DONE"],
                f"PTY handshake incomplete or out of order: {stages}\n{tail}")
        observed = bytes(terminal_output)
        for expected in (
            b"\x1b[6n",                       # read-only cursor query
            b"\x1b[?1006h\x1b[?1003h",       # SGR mouse mode
            b"\x1b[?1004h",                  # focus
            b"\x1b[?2004h",                  # paste
            b"OK",                           # drawing
            b"\x1b[?25l",                   # hide cursor
            b"\x1b[?25h",                   # show cursor
        ):
            require(expected in observed,
                    f"TTY output missing {expected!r}; got {observed!r}")
        restored = termios.tcgetattr(slave)
        require(restored == original,
                f"termios not restored: original={original!r}, actual={restored!r}\\n{tail}")
        require(b"a\xc3\xa9" not in observed,
                "raw input unexpectedly echoed onto PTY master")
        print("PTY-E2E PASS: fragmented UTF-8/CSI, query routing, output controls, "
              "nested raw mode, no echo, owned and exceptional termios restoration")
    except Exception:
        if child is not None and child.poll() is None:
            child.kill()
            child.wait(timeout=2)
        raise
    finally:
        if child is not None and child.stdin is not None:
            child.stdin.close()
        if child is not None and child.stdout is not None:
            child.stdout.close()
        os.close(master)
        os.close(slave)


if __name__ == "__main__":
    try:
        run()
    except Exception as exc:
        print(f"PTY-E2E FAIL: {exc}", file=sys.stderr)
        sys.exit(1)
