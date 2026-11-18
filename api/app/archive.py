"""WAL archive format handling.

The archive volume holds two coexisting segment formats:

* legacy uncompressed segments, named ``000000010000000000000003``
* new gzip segments, named ``000000010000000000000004.gz``

Only fully written, verified files under those two exact naming patterns are
considered formal archives. Interrupted compressions leave
``*.partial-<pid>`` temp files, which are never valid archives and are counted
separately for visibility. A named restore point is "ready" only when every
required segment exists in either format, and recovery picks the format per
segment (see app/restore-wal.sh).
"""

from __future__ import annotations

import os
import re
import tempfile

from . import config

# A WAL segment name: 8-hex timeline + 8-hex log + 8-hex segment, upper case.
_WAL_NAME_RE = re.compile(r"^[0-9A-F]{24}$")
# Timeline history files (small, also archived): 00000001.history[.gz]
_HISTORY_RE = re.compile(r"^[0-9A-F]{8}\.history$")
_PARTIAL_RE = re.compile(r"\.partial-\d+$")

GZIP_SUFFIX = ".gz"


def is_wal_name(name: str) -> bool:
    return bool(_WAL_NAME_RE.match(name))


def is_history_name(name: str) -> bool:
    base = name[: -len(GZIP_SUFFIX)] if name.endswith(GZIP_SUFFIX) else name
    return bool(_HISTORY_RE.match(base))


def is_partial(name: str) -> bool:
    return bool(_PARTIAL_RE.search(name))


def archive_path(segment: str) -> str | None:
    """Return the formal archive path for a segment, whichever format exists.

    Plain (legacy) segments take precedence so an old segment that exists in
    both forms is always read as originally archived. Returns None when no
    complete archive exists (a leftover partial file does not count).
    """
    plain = os.path.join(config.WAL_ARCHIVE_DIR, segment)
    gz = plain + GZIP_SUFFIX
    if os.path.isfile(plain):
        return plain
    if os.path.isfile(gz):
        return gz
    return None


def segment_exists(segment: str) -> bool:
    return archive_path(segment) is not None


def segment_format(segment: str) -> str | None:
    """``plain`` / ``gzip`` / None for a bare WAL segment name."""
    path = archive_path(segment)
    if path is None:
        return None
    return "gzip" if path.endswith(GZIP_SUFFIX) else "plain"


def _disk_bytes(path: str) -> tuple[int, int]:
    """Return (logical size, actually allocated bytes) for one file."""
    st = os.stat(path)
    # st_blocks is in 512-byte units; sparse files allocate fewer than st_size.
    allocated = getattr(st, "st_blocks", None)
    if allocated is not None:
        return st.st_size, allocated * 512
    return st.st_size, st.st_size


def _gzip_uncompressed_size(path: str, fallback: int) -> int:
    """Uncompressed payload size from the gzip ISIZE trailer (mod 2^32).

    WAL segments are 16 MiB so the trailer value is exact here; fall back to
    the on-disk size if the trailer cannot be read.
    """
    try:
        with open(path, "rb") as fh:
            fh.seek(-4, os.SEEK_END)
            return int.from_bytes(fh.read(4), "little")
    except OSError:
        return fallback


def usage() -> dict:
    """Counts and real disk occupancy of the archive volume.

    ``plain`` and ``gzip`` count formal WAL segments of each format and sum
    their *actually allocated* bytes (the figure that reflects space saved by
    compression). Partial/temp files and other entries are listed separately
    so interrupted compressions are visible without polluting the counts.
    """
    counts = {"plain": 0, "gzip": 0}
    logical = {"plain": 0, "gzip": 0}
    allocated = {"plain": 0, "gzip": 0}
    partial_files = []
    other_files = []

    if not os.path.isdir(config.WAL_ARCHIVE_DIR):
        return _pack(counts, logical, allocated, partial_files, other_files, "gzip")

    for entry in sorted(os.listdir(config.WAL_ARCHIVE_DIR)):
        full = os.path.join(config.WAL_ARCHIVE_DIR, entry)
        if not os.path.isfile(full) or os.path.islink(full):
            other_files.append(entry)
            continue
        if is_partial(entry):
            try:
                _, alloc = _disk_bytes(full)
            except OSError:
                alloc = 0
            partial_files.append({"name": entry, "allocated_bytes": alloc})
            continue
        if is_wal_name(entry):
            fmt = "plain"
        elif entry.endswith(GZIP_SUFFIX) and is_wal_name(entry[: -len(GZIP_SUFFIX)]):
            fmt = "gzip"
        else:
            other_files.append(entry)
            continue
        try:
            size, alloc = _disk_bytes(full)
        except OSError:
            continue
        counts[fmt] += 1
        allocated[fmt] += alloc
        if fmt == "gzip":
            # logical size = uncompressed WAL payload (what the segment would
            # occupy raw); read it from the gzip ISIZE trailer without
            # decompressing up to 16 MiB per file.
            logical_size = _gzip_uncompressed_size(full, size)
        else:
            logical_size = size
        logical[fmt] += logical_size

    return _pack(
        counts, logical, allocated, partial_files, other_files, current_mode()
    )


def _pack(counts, logical, allocated, partial_files, other_files, mode):
    total_files = counts["plain"] + counts["gzip"]
    total_logical = logical["plain"] + logical["gzip"]
    total_allocated = allocated["plain"] + allocated["gzip"]
    partial_bytes = sum(p["allocated_bytes"] for p in partial_files)
    return {
        "archive_dir": config.WAL_ARCHIVE_DIR,
        "archive_mode": mode,
        "formats": {
            "plain": {
                "files": counts["plain"],
                "logical_bytes": logical["plain"],
                "allocated_bytes": allocated["plain"],
            },
            "gzip": {
                "files": counts["gzip"],
                "logical_bytes": logical["gzip"],
                "allocated_bytes": allocated["gzip"],
            },
        },
        "total_files": total_files,
        "total_logical_bytes": total_logical,
        "total_allocated_bytes": total_allocated,
        "space_saved_vs_uncompressed_bytes": max(
            0, total_logical - total_allocated
        ),
        "partial_files": partial_files,
        "partial_allocated_bytes": partial_bytes,
        "other_entries": other_files,
    }


# --------------------------------------------------------------------------
# archive mode control (read by db/archive/archive-dispatcher.sh)
# --------------------------------------------------------------------------

MODE_PLAIN = "plain"
MODE_GZIP = "gzip"
_VALID_MODES = (MODE_PLAIN, MODE_GZIP)


def mode_file_path() -> str:
    return os.path.join(config.WAL_ARCHIVE_DIR, ".archive_mode")


def current_mode() -> str:
    """The dispatcher defaults to gzip when no control file exists."""
    try:
        with open(mode_file_path(), "r", encoding="ascii") as fh:
            value = fh.read().strip()
        if value in _VALID_MODES:
            return value
    except OSError:
        pass
    return MODE_GZIP


def set_mode(mode: str) -> str:
    if mode not in _VALID_MODES:
        raise ValueError(f"invalid archive mode {mode!r}; expected one of {_VALID_MODES}")
    os.makedirs(config.WAL_ARCHIVE_DIR, exist_ok=True)
    # atomic replace so the dispatcher never reads a half-written control file
    fd, tmp = tempfile.mkstemp(
        prefix=".archive_mode.tmp-", dir=config.WAL_ARCHIVE_DIR
    )
    try:
        with os.fdopen(fd, "w", encoding="ascii") as fh:
            fh.write(mode + "\n")
        os.replace(tmp, mode_file_path())
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    return mode
