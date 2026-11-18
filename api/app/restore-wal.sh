#!/usr/bin/env bash
# restore-wal.sh <wal_name> <destination>
#
# Used as the replica's restore_command. A recovery range may span two
# archive formats - legacy uncompressed segments and new gzip segments - so
# each requested segment is chosen individually:
#
#   <name>        -> raw copy (legacy plain segment)
#   <name>.gz     -> streamed decompression (gzip -dc) into <destination>
#
# Failure modes are explicit and loud (they land in the replica log and fail
# the recovery job instead of silently serving a broken replica):
#   * neither file exists            -> exit 1 (missing segment)
#   * gzip CRC/trailer failure or an
#     output truncated mid-stream    -> gzip exits non-zero, we remove the
#                                       partial destination and exit 1
#   * plain segment with an
#     unexpected length              -> rejected before copying
set -euo pipefail

ARCHIVE_DIR="${1:-${WAL_ARCHIVE_DIR:-/wal_archive}}"
NAME="${2:?restore-wal.sh: usage: restore-wal.sh [archive_dir] <wal_name> <destination>}"
DEST="${3:?restore-wal.sh: usage: restore-wal.sh [archive_dir] <wal_name> <destination>}"

PLAIN="$ARCHIVE_DIR/$NAME"
GZ="$ARCHIVE_DIR/$NAME.gz"

fail() {
  echo "restore-wal: ERROR $*" >&2
  rm -f -- "$DEST"
  exit 1
}

if [ -f "$PLAIN" ]; then
  # WAL segments are exactly 16 MiB (history/backup-label files are smaller
  # and have non-24-hex-digit names, so the size guard applies only to WAL).
  if [[ "$NAME" =~ ^[0-9A-F]{24}$ ]]; then
    size=$(stat -c '%s' "$PLAIN")
    [ "$size" -eq 16777216 ] || fail "plain WAL $NAME has wrong size ($size bytes)"
  fi
  cp -- "$PLAIN" "$DEST" || fail "could not copy plain segment $NAME"
elif [ -f "$GZ" ]; then
  # Streamed decompression straight to the destination; `set -o pipefail`
  # makes a corrupt/truncated gzip fail the pipeline, and the trap-style
  # cleanup guarantees no half-written file is mistaken for valid WAL.
  if ! gzip -dc -- "$GZ" > "$DEST"; then
    fail "gzip stream for $NAME is corrupt or truncated"
  fi
  if [[ "$NAME" =~ ^[0-9A-F]{24}$ ]]; then
    size=$(stat -c '%s' "$DEST")
    [ "$size" -eq 16777216 ] || fail "decompressed $NAME has wrong size ($size bytes)"
  fi
else
  fail "no archived segment found for $NAME (looked for $NAME and $NAME.gz)"
fi
