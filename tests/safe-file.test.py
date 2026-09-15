#!/usr/bin/python3 -I
import importlib.util
import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("safe_file", ROOT / "bin" / "safe-file.py")
sf = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(sf)


class SafeFileTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name)
        self.anchor = os.open(self.home, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)

    def tearDown(self):
        os.close(self.anchor)
        self.tmp.cleanup()

    def _dir(self, parts, create=True):
        return sf.open_dir_chain(parts, anchor_fd=self.anchor, create_missing=create)

    def test_atomic_write_and_bounded_read(self):
        dirfd = self._dir([".local", "state", "omarchy"])
        try:
            sf.write_atomic(dirfd, "dock-workspaces-laptop-ids", b"3\n1\n", 4096, 0o600)
            data = sf.read_bounded(dirfd, "dock-workspaces-laptop-ids", 4096)
            self.assertEqual(data, b"3\n1\n")
            st = os.stat(self.home / ".local/state/omarchy/dock-workspaces-laptop-ids")
            self.assertEqual(stat.S_IMODE(st.st_mode), 0o600)
        finally:
            os.close(dirfd)

    def test_read_refuses_symlink(self):
        dirfd = self._dir([".local", "state", "omarchy"])
        try:
            victim = self.home / "victim"
            victim.write_bytes(b"must survive")
            os.symlink(victim, self.home / ".local/state/omarchy/dock-workspaces-laptop-ids")
            with self.assertRaises(PermissionError):
                sf.read_bounded(dirfd, "dock-workspaces-laptop-ids", 4096)
            self.assertEqual(victim.read_bytes(), b"must survive")
        finally:
            os.close(dirfd)

    def test_write_replaces_symlink_without_following(self):
        dirfd = self._dir([".local", "state", "omarchy"])
        try:
            victim = self.home / "victim"
            victim.write_bytes(b"must survive")
            os.symlink(victim, self.home / ".local/state/omarchy/dock-workspaces-laptop-ids")
            sf.write_atomic(dirfd, "dock-workspaces-laptop-ids", b"2\n", 4096, 0o600)
            self.assertEqual(victim.read_bytes(), b"must survive")
            path = self.home / ".local/state/omarchy/dock-workspaces-laptop-ids"
            self.assertFalse(path.is_symlink())
            self.assertEqual(path.read_bytes(), b"2\n")
        finally:
            os.close(dirfd)

    def test_read_refuses_fifo(self):
        dirfd = self._dir([".local", "state", "omarchy"])
        try:
            os.mkfifo(self.home / ".local/state/omarchy/dock-workspaces-laptop-ids")
            with self.assertRaises(PermissionError):
                sf.read_bounded(dirfd, "dock-workspaces-laptop-ids", 4096)
        finally:
            os.close(dirfd)

    def test_read_refuses_oversized(self):
        dirfd = self._dir([".config", "hypr"])
        try:
            payload = b"x" * 65
            sf.write_atomic(dirfd, "hyprland.lua", payload, 1024, 0o644)
            with self.assertRaises(PermissionError):
                sf.read_bounded(dirfd, "hyprland.lua", 64)
        finally:
            os.close(dirfd)

    def test_parent_symlink_is_refused(self):
        elsewhere = self.home / "elsewhere"
        elsewhere.mkdir()
        os.symlink(elsewhere, self.home / ".config")
        with self.assertRaises(OSError):
            self._dir([".config", "hypr"], create=False)

    def test_validate_state_and_config(self):
        self.assertEqual(sf.validate_state("5\n1\n1\n"), "1\n5\n")
        with self.assertRaises(ValueError):
            sf.validate_state("nope")
        with self.assertRaises(ValueError):
            sf.validate_state("\n".join(str(i) for i in range(1, 70)))
        dumped = sf.validate_config('{"enabled": false, "laptop": "eDP-1", "primary": ""}')
        self.assertIn('"enabled": false', dumped)
        with self.assertRaises(ValueError):
            sf.validate_hyprland(
                "-- seanpk.dock-workspaces start\n-- seanpk.dock-workspaces start\n"
            )

    def test_loader_matches_model_and_is_reversible(self):
        js = subprocess.check_output(
            ["node", "-e", "const M=require('./Model.js'); process.stdout.write(M.loaderBlock())"],
            cwd=ROOT,
        ).decode("utf-8")
        self.assertEqual(sf.loader_block(), js)
        original = 'require("hypr.monitors")\n'
        once = sf.with_loader(original)
        self.assertEqual(sf.loader_state(once), "present")
        self.assertEqual(sf.with_loader(once), once)
        self.assertEqual(sf.without_loader(once).find("seanpk.dock-workspaces"), -1)
        duplicate = once + "\n" + sf.loader_block() + "\n"
        self.assertEqual(sf.loader_state(duplicate), "malformed")
        self.assertEqual(sf.without_loader(duplicate), duplicate)


if __name__ == "__main__":
    unittest.main()
