#!/usr/bin/env python3
"""Self-test for app/archive.py and the recovery preflight logic.

Runs with the stdlib only (no FastAPI/psycopg needed): config/db/state are
stubbed on sys.modules before import so archive.py and recovery.py can be
exercised in isolation. Covers format classification, mixed-format existence
lookup, usage accounting (counts + real allocated bytes + partial files),
mode control atomicity, and the explicit missing/corrupt failure paths of
the recovery preflight.
"""

import gzip
import importlib
import os
import sys
import tempfile
import types
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
APP_DIR = os.path.abspath(os.path.join(HERE, "..", "api"))
APP_PKG = os.path.join(APP_DIR, "app")


def _bootstrap(tmpdir):
    """Create an `app` package with stubbed heavy dependencies."""
    for name in list(sys.modules):
        if name == "app" or name.startswith("app."):
            del sys.modules[name]
    sys.path.insert(0, APP_DIR)
    pkg = types.ModuleType("app")
    pkg.__path__ = [APP_PKG]
    sys.modules["app"] = pkg

    config = types.ModuleType("app.config")
    config.WAL_ARCHIVE_DIR = os.path.join(tmpdir, "wal_archive")
    os.makedirs(config.WAL_ARCHIVE_DIR, exist_ok=True)
    config.RESTORE_SCRIPT = os.path.join(APP_PKG, "restore-wal.sh")
    config.RECOVERY_TIMEOUT_SEC = 1
    config.TRAFFIC_TABLE = "traffic_minute_counts"
    sys.modules["app.config"] = config

    db = types.ModuleType("app.db")
    sys.modules["app.db"] = db

    # real in-memory sqlite-backed state, same schema as the production module
    state = types.ModuleType("app.state")
    import sqlite3
    conn = sqlite3.connect(":memory:")
    conn.row_factory = sqlite3.Row
    conn.executescript(
        """
        CREATE TABLE kv (key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE restore_points (id INTEGER PRIMARY KEY, name TEXT, lsn TEXT,
            wal_file TEXT, status TEXT DEFAULT 'pending', created_at TEXT);
        CREATE TABLE recoveries (id INTEGER PRIMARY KEY, restore_point TEXT,
            target_lsn TEXT, status TEXT DEFAULT 'running', error TEXT,
            work_dir TEXT, replay_lsn TEXT, started_at TEXT, finished_at TEXT);
        """
    )
    kv_rows = {}

    def kv_get(key, default=None):
        return kv_rows.get(key, default)

    def kv_set(key, value):
        kv_rows[key] = None if value is None else str(value)

    state.kv_get = kv_get
    state.kv_set = kv_set
    state._kv_rows = kv_rows
    sys.modules["app.state"] = state

    archive = importlib.import_module("app.archive")
    lsn_mod = importlib.import_module("app.lsn")
    recovery = importlib.import_module("app.recovery")
    return archive, config, state, lsn_mod, recovery


class ArchiveTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.archive, self.config, self.state, _, _ = _bootstrap(self.tmp)
        self.dir = self.config.WAL_ARCHIVE_DIR
        self.segs = [
            "000000010000000000000001",
            "000000010000000000000002",
            "000000010000000000000003",
        ]

    def _plain(self, seg, payload=b"raw-wal-16m"):
        with open(os.path.join(self.dir, seg), "wb") as fh:
            fh.write(payload)

    def _gzip(self, seg, payload=b"compressed-wal"):
        with gzip.open(os.path.join(self.dir, seg + ".gz"), "wb") as fh:
            fh.write(payload)

    def test_name_classification(self):
        a = self.archive
        self.assertTrue(a.is_wal_name("000000010000000000000001"))
        self.assertFalse(a.is_wal_name("00000001000000000000001.gz"))
        self.assertFalse(a.is_wal_name("something-else"))
        self.assertTrue(a.is_history_name("00000002.history"))
        self.assertTrue(a.is_history_name("00000002.history.gz"))
        self.assertTrue(a.is_partial("000000010000000000000003.gz.partial-4821"))
        self.assertFalse(a.is_partial("000000010000000000000003.gz"))

    def test_lookup_mixed_formats_and_precedence(self):
        a = self.archive
        self.assertFalse(a.segment_exists(self.segs[0]))
        self.assertIsNone(a.segment_format(self.segs[0]))
        self._plain(self.segs[0])
        self._gzip(self.segs[1])
        self.assertEqual(a.segment_format(self.segs[0]), "plain")
        self.assertEqual(a.segment_format(self.segs[1]), "gzip")
        # a partial file must never satisfy an existence lookup
        with open(os.path.join(self.dir, self.segs[2] + ".gz.partial-9"), "wb") as fh:
            fh.write(b"half")
        self.assertFalse(a.segment_exists(self.segs[2]))
        # plain takes precedence when both forms exist
        self._plain(self.segs[1])
        self.assertEqual(a.segment_format(self.segs[1]), "plain")

    def test_usage_counts_and_bytes(self):
        payload_plain = b"P" * 4096
        payload_gz = b"G" * 4096
        self._plain(self.segs[0], payload_plain)
        self._plain(self.segs[1], payload_plain)
        self._gzip(self.segs[2], payload_gz)
        # interrupted compression leftovers + history file must be separated
        with open(os.path.join(self.dir, self.segs[2] + ".gz.partial-7"), "wb") as fh:
            fh.write(b"x" * 123)
        with open(os.path.join(self.dir, "00000001.history"), "wb") as fh:
            fh.write(b"history")
        u = self.archive.usage()
        self.assertEqual(u["formats"]["plain"]["files"], 2)
        self.assertEqual(u["formats"]["gzip"]["files"], 1)
        self.assertEqual(u["total_files"], 3)
        self.assertEqual(u["formats"]["plain"]["logical_bytes"], 8192)
        self.assertGreaterEqual(
            u["formats"]["plain"]["allocated_bytes"],
            u["formats"]["plain"]["logical_bytes"],
        )
        # gzip logical bytes = uncompressed payload (from ISIZE trailer),
        # allocated bytes = actual on-disk compressed file
        self.assertEqual(u["formats"]["gzip"]["logical_bytes"], 4096)
        gz_disk = os.stat(
            os.path.join(self.dir, self.segs[2] + ".gz")
        ).st_blocks * 512
        self.assertEqual(u["formats"]["gzip"]["allocated_bytes"], gz_disk)
        self.assertGreaterEqual(u["space_saved_vs_uncompressed_bytes"], 0)
        self.assertEqual(len(u["partial_files"]), 1)
        self.assertGreater(u["partial_files"][0]["allocated_bytes"], 0)
        self.assertIn("00000001.history", u["other_entries"])
        self.assertEqual(
            u["total_allocated_bytes"],
            u["formats"]["plain"]["allocated_bytes"]
            + u["formats"]["gzip"]["allocated_bytes"],
        )

    def test_usage_missing_dir(self):
        self.config.WAL_ARCHIVE_DIR = os.path.join(self.tmp, "gone")
        u = self.archive.usage()
        self.assertEqual(u["total_files"], 0)
        self.assertEqual(u["total_allocated_bytes"], 0)
        self.assertEqual(u["archive_mode"], "gzip")  # documented default

    def test_mode_control(self):
        a = self.archive
        self.assertEqual(a.current_mode(), a.MODE_GZIP)
        a.set_mode("plain")
        self.assertEqual(a.current_mode(), "plain")
        with open(a.mode_file_path(), encoding="ascii") as fh:
            self.assertEqual(fh.read().strip(), "plain")
        a.set_mode("gzip")
        self.assertEqual(a.current_mode(), "gzip")
        with self.assertRaises(ValueError):
            a.set_mode("bzip2")
        leftovers = [n for n in os.listdir(self.dir) if "archive_mode.tmp" in n]
        self.assertEqual(leftovers, [])


class PreflightTests(unittest.TestCase):
    """The recovery preflight must fail explicitly on missing/corrupt WAL."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.archive, self.config, self.state, self.lsn, self.recovery = \
            _bootstrap(self.tmp)
        self.dir = self.config.WAL_ARCHIVE_DIR
        self.state._kv_rows["backup_end_lsn"] = "0/1000000"
        self.calls = []
        self.corrupt_paths = set()

        class FakeResult:
            def __init__(self, code, stderr=""):
                self.returncode = code
                self.stdout = ""
                self.stderr = stderr

        def fake_run(cmd, **kw):
            self.calls.append(cmd)
            tagged = cmd[-1] in self.corrupt_paths
            return FakeResult(1, "gzip: corrupt (simulated)") if tagged \
                else FakeResult(0)

        self.recovery._run = fake_run

    def _seg(self, index):
        return self.lsn.wal_file(index * self.lsn.SEG_SIZE)

    def test_preflight_ok_mixed_formats(self):
        seg1, seg2, seg3 = self._seg(1), self._seg(2), self._seg(3)
        with open(os.path.join(self.dir, seg1), "wb") as fh:
            fh.write(b"plain")
        with gzip.open(os.path.join(self.dir, seg2 + ".gz"), "wb") as fh:
            fh.write(b"gz-ok")
        with gzip.open(os.path.join(self.dir, seg3 + ".gz"), "wb") as fh:
            fh.write(b"gz-ok-2")
        target = self.lsn.fmt(3 * self.lsn.SEG_SIZE + 123)
        needed = self.recovery._preflight_archive(target)
        self.assertEqual(needed, [seg1, seg2, seg3])
        self.assertEqual(len(self.calls), 2)  # gzip -t only for .gz files

    def test_preflight_missing_segment_fails_explicitly(self):
        with open(os.path.join(self.dir, self._seg(1)), "wb") as fh:
            fh.write(b"plain")
        target = self.lsn.fmt(3 * self.lsn.SEG_SIZE + 1)
        with self.assertRaises(RuntimeError) as ctx:
            self.recovery._preflight_archive(target)
        message = str(ctx.exception)
        self.assertIn("missing archived WAL segment", message)
        self.assertIn(".gz", message)

    def test_preflight_partial_does_not_count(self):
        seg2 = self._seg(2)
        with open(os.path.join(self.dir, seg2 + ".gz.partial-1"), "wb") as fh:
            fh.write(b"half-written")
        target = self.lsn.fmt(2 * self.lsn.SEG_SIZE + 1)
        with self.assertRaises(RuntimeError) as ctx:
            self.recovery._preflight_archive(target)
        self.assertIn("missing archived WAL segment", str(ctx.exception))

    def test_preflight_corrupt_gzip_fails_explicitly(self):
        target = self.lsn.fmt(1 * self.lsn.SEG_SIZE + 1)
        corrupt_path = os.path.join(self.dir, self._seg(1) + ".gz")
        with gzip.open(corrupt_path, "wb") as fh:
            fh.write(b"valid gzip container; failure is injected via the runner")
        self.corrupt_paths.add(corrupt_path)
        with self.assertRaises(RuntimeError) as ctx:
            self.recovery._preflight_archive(target)
        self.assertIn("corrupt compressed WAL archive", str(ctx.exception))


if __name__ == "__main__":
    unittest.main(verbosity=2)
