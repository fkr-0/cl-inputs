#!/usr/bin/env python3
"""Black-box cl-inputs application E2E via a private tmux PTY.

Adapted from ElmTUI's scripts/test-terminal-apps.py:
- isolated tmux socket, fresh CLPM/SBCL per case
- screen assertions from capture-pane, never matched against compiler logs
- raw terminal capture and error transcript as separate artifacts
- stty snapshot comparison, visible cursor and shell-resume sentinel
- normal and exceptional lifecycle qualifications

Run: python3 tests/tmux-terminal-apps.py [--output DIR] [--timeout 20]
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
OPTIONS = None


class TerminalApp:
    def __init__(self, name: str, *, scenario: str = "") -> None:
        assert OPTIONS is not None
        self.directory = OPTIONS.output / name
        self.directory.mkdir(parents=True, exist_ok=True)
        self.socket = str(self.directory / "tmux.sock")
        self.frames: list[dict[str, str]] = []
        self.scenario = scenario

    def tmux(self, *args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["tmux", "-S", self.socket, *args],
            cwd=ROOT, check=check, capture_output=True, text=True, timeout=10,
        )

    def start(self):
        command = [
            "clpm", "bundle", "exec", "--with-client", "sbcl", "--",
            "--noinform", "--non-interactive", "--no-sysinit", "--no-userinit",
            "--load", "tests/tmux-terminal-app.lisp",
        ]
        script = self.directory / "launch.sh"
        script.write_text(
            "#!/bin/sh\n"
            + "cd " + shlex.quote(str(ROOT)) + "\n"
            + "export CL_INPUTS_TMUX_CASE=" + shlex.quote(self.scenario) + "\n"
            + "stty -g > " + shlex.quote(str(self.directory / "before.stty")) + "\n"
            + shlex.join(command) + " 2>" + shlex.quote(str(self.directory / "stderr.txt")) + "\n"
            + "status=$?\n"
            + "stty -g > " + shlex.quote(str(self.directory / "after.stty")) + "\n"
            + "printf '%s\\n' \"$status\" > "
            + shlex.quote(str(self.directory / "exit-code")) + "\n"
            + "printf 'CL_INPUTS_SHELL_RESTORED\\n'\n"
            + "sleep 30\n"
        )
        self.tmux(
            "-f", "/dev/null", "new-session", "-d", "-s", "app",
            "-x", "80", "-y", "24", "sh " + shlex.quote(str(script)),
        )
        self.tmux("set-option", "-g", "status", "off")
        self.tmux(
            "pipe-pane", "-t", "app:0.0",
            "cat > " + shlex.quote(str(self.directory / "terminal.raw")),
        )
        return self

    def screen(self) -> str:
        return self.tmux("capture-pane", "-p", "-t", "app:0.0").stdout

    def wait(self, predicate, description: str) -> str:
        deadline = time.monotonic() + OPTIONS.timeout
        while time.monotonic() < deadline:
            screen = self.screen()
            if predicate(screen):
                self.frames.append({"description": description, "screen": screen})
                return screen
            if (self.directory / "exit-code").exists():
                raise AssertionError(
                    f"App exited before {description}: {self.screen()}\n"
                    + (self.directory / "stderr.txt").read_text(errors="replace")[-2000:]
                )
            time.sleep(0.07)
        raise AssertionError(f"Timed out waiting for {description}: {self.screen()}")

    def expect(self, text: str) -> str:
        return self.wait(lambda screen: text in screen, repr(text))

    def key(self, key: str, *, literal: bool = False) -> None:
        self.tmux("send-keys", "-t", "app:0.0", *(["-l"] if literal else []), key)

    def finish(self, *, key: str | None, expected_status: int = 0) -> None:
        if key is not None:
            self.key(key, literal=key in ("a", "x", "q"))
        deadline = time.monotonic() + OPTIONS.timeout
        while not (self.directory / "exit-code").exists():
            if time.monotonic() > deadline:
                raise AssertionError("App did not exit through input path")
            time.sleep(0.07)
        actual = int((self.directory / "exit-code").read_text().strip())
        wrong_status = actual != 0 if expected_status == 0 else actual == 0
        if wrong_status:
            raise AssertionError(
                f"Wrong status {actual}; expected {'0' if expected_status == 0 else 'nonzero'}"
            )
        before = (self.directory / "before.stty").read_text()
        after = (self.directory / "after.stty").read_text()
        if before != after:
            raise AssertionError(
                f"termios not restored: before={before!r} after={after!r}"
            )
        self.expect("CL_INPUTS_SHELL_RESTORED")
        flag = self.tmux(
            "display-message", "-p", "-t", "app:0.0", "#{cursor_flag}",
        ).stdout.strip()
        if flag != "1":
            raise AssertionError(f"cursor left hidden: {flag!r}")

    def close(self) -> None:
        try:
            (self.directory / "last-screen.txt").write_text(self.screen())
        except (OSError, subprocess.SubprocessError):
            pass
        (self.directory / "frames.json").write_text(
            json.dumps(self.frames, indent=2) + "\n"
        )
        self.tmux("kill-server", check=False)


class TerminalApps(unittest.TestCase):
    def app(self, name: str, *, scenario: str = "") -> TerminalApp:
        instance = TerminalApp(name, scenario=scenario)
        self.addCleanup(instance.close)
        return instance.start()

    def test_plain_keys_arrows_and_normal_shutdown(self):
        app = self.app("interactive")
        app.expect("CL_INPUTS_READY")
        app.key("a", literal=True)
        app.expect("CL_INPUTS_KEY:a")
        app.key("Up")
        app.expect("CL_INPUTS_UP")
        app.finish(key="q")
        raw = (app.directory / "terminal.raw").read_bytes()
        self.assertIn(b"CL_INPUTS_READY", raw)
        self.assertNotIn(b"Opening TTY device", raw,
                         "device initialization must not leak INFO logs into screen")
        self.assertNotIn(b"compiling file", raw,
                         "ASDF startup output must not corrupt the screen")
        self.assertIn(b"CL_INPUTS_UP", raw)
        self.assertNotRegex(
            raw, rb"\x1b\[(?:2|3)J|\x1b\[\?1049[hl]",
            "input app should not clear whole screen or replace alternate buffer",
        )

    def test_bracketed_paste_and_quit(self):
        app = self.app("paste")
        app.expect("CL_INPUTS_READY")
        app.tmux("set-buffer", "-b", "paste-e2e", "pasted word")
        app.tmux("paste-buffer", "-p", "-b", "paste-e2e", "-t", "app:0.0")
        app.expect("CL_INPUTS_PASTE:pasted word")
        app.finish(key="q")
        self.assertIn(bytes((27,)) + b"[?2004h",
                      (app.directory / "terminal.raw").read_bytes())

    def test_window_resize_does_not_break_input(self):
        app = self.app("resize")
        app.expect("CL_INPUTS_READY")
        app.tmux("resize-window", "-t", "app:0", "-x", "100", "-y", "35")
        app.key("a", literal=True)
        app.expect("CL_INPUTS_KEY:a")
        app.finish(key="q")
        self.assertEqual(app.tmux("display-message", "-p", "-t", "app:0", "#{window_width}").stdout.strip(), "100")

    def test_unwind_on_real_tty_exception(self):
        app = self.app("exception", scenario="exception")
        app.expect("CL_INPUTS_READY")
        app.finish(key="x", expected_status=1)
        errors = (app.directory / "stderr.txt").read_text(errors="replace")
        self.assertIn("CL_INPUTS_INTENTIONAL_E2E_EXCEPTION", errors)
        self.assertIn("CL_INPUTS_SHELL_RESTORED", app.screen())


def main() -> int:
    global OPTIONS
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--timeout", type=float, default=20)
    OPTIONS = parser.parse_args()
    missing = [name for name in ("tmux", "clpm", "sbcl", "stty") if not shutil.which(name)]
    if missing:
        parser.error("Required executables missing: " + ", ".join(missing))
    if OPTIONS.timeout <= 0:
        parser.error("--timeout must be positive")
    OPTIONS.output = (
        OPTIONS.output or Path(tempfile.mkdtemp(prefix="cl-inputs-tmux-e2e-"))
    ).resolve()
    OPTIONS.output.mkdir(parents=True, exist_ok=True)
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(TerminalApps)
    started = time.monotonic()
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    (OPTIONS.output / "result.json").write_text(
        json.dumps(
            {
                "tests": result.testsRun,
                "failures": len(result.failures),
                "errors": len(result.errors),
                "successful": result.wasSuccessful(),
                "seconds": time.monotonic() - started,
            },
            indent=2,
        ) + "\n"
    )
    print("Artifacts:", OPTIONS.output)
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(main())
