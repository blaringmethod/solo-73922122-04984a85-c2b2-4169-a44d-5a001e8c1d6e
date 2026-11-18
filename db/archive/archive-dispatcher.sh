#!/usr/bin/env bash
# archive-dispatcher.sh <wal_path> <wal_name>
#
# Invoked by the primary's archive_command for every new WAL segment (and
# timeline history file). The desired format is controlled, per invocation, by
# the control file on the shared archive volume:
#
#   /wal_archive/.archive_mode   containing either "gzip" (default when the
#                                file is missing) or "plain".
#
# Hard guarantees (these are the whole point of this script):
#   * a segment becomes a "formal" archive ONLY after it has been fully written
#     AND verified (gzip -t plus a full byte comparison against the source);
#   * an interrupted compression leaves only a *.partial-* temp file, never a
#     valid-looking final file that recovery could misread;
#   * the final file is published atomically (same-filesystem hard link), and
#     an existing completed segment is never overwritten - Postgres retries
#     archive_command with the same name, in which case we re-verify the
#     existing archive against the source and succeed without touching it;
#   * pre-existing uncompressed ("plain") segments keep working unchanged.
#
# Exits non-zero on any failure so Postgres retries the archival later.
set -euo pipefail

ARCHIVE_DIR="${WAL_ARCHIVE_DIR:-/wal_archive}"
MODE_FILE="$ARCHIVE_DIR/.archive_mode"
SRC="$1"
NAME="$2"

mode="gzip"
if [ -r "$MODE_FILE" ]; then
  read -r saved < "$MODE_FILE" || true
  case "$saved" in
    gzip|plain) mode="$saved" ;;
  esac
fi

# Publish $tmp as $dst atomically. If another invocation already published a
# file under $dst, keep that one (never overwrite) and verify it below.
publish() {
  local tmp="$1" dst="$2"
  if [ -e "$dst" ]; then
    rm -f "$tmp"
  else
    # link is atomic on the same filesystem; only then remove the temp name.
    ln "$tmp" "$dst"
    rm -f "$tmp"
  fi
}

verify_plain() { # <archive> <source>
  cmp -s "$1" "$2"
}

verify_gzip() { # <archive> <source>
  # 1) gzip container integrity (CRC32 + ISIZE + trailer),
  # 2) full decompressed content must be byte-identical to the source WAL.
  gzip -t -- "$1" && gzip -dc -- "$1" | cmp -s - "$2"
}

case "$mode" in
  plain)
    dst="$ARCHIVE_DIR/$NAME"
    if [ -e "$dst" ]; then
      # same-name retry: accept only if the completed archive really matches.
      if verify_plain "$dst" "$SRC"; then exit 0; fi
      echo "archive-dispatcher: ERROR existing plain archive $NAME does not match source; refusing to overwrite" >&2
      exit 1
    fi
    tmp="$ARCHIVE_DIR/$NAME.partial-$$"
    rm -f -- "$ARCHIVE_DIR/$NAME.partial-"*
    cp -- "$SRC" "$tmp"
    if verify_plain "$tmp" "$SRC"; then
      publish "$tmp" "$dst"
    else
      rm -f "$tmp"
      echo "archive-dispatcher: ERROR plain copy of $NAME failed verification" >&2
      exit 1
    fi
    ;;
  gzip)
    dst="$ARCHIVE_DIR/$NAME.gz"
    if [ -e "$dst" ]; then
      # same-name retry: never overwrite a completed segment; re-verify it.
      if verify_gzip "$dst" "$SRC"; then exit 0; fi
      echo "archive-dispatcher: ERROR existing gzip archive $NAME.gz is corrupt or mismatched; refusing to overwrite" >&2
      exit 1
    fi
    # A plain (legacy) segment under the same base name always wins: old
    # recovery points may already depend on it, and readiness/recovery code
    # prefers plain files. Verify it instead of creating a duplicate format.
    if [ -e "$ARCHIVE_DIR/$NAME" ]; then
      if verify_plain "$ARCHIVE_DIR/$NAME" "$SRC"; then exit 0; fi
      echo "archive-dispatcher: ERROR existing plain archive $NAME does not match source" >&2
      exit 1
    fi
    tmp="$ARCHIVE_DIR/$NAME.gz.partial-$$"
    # A previous interrupted attempt may have left partials for this same
    # segment; they can never be formal archives, so remove them before the
    # retry instead of letting half-written files accumulate.
    rm -f -- "$ARCHIVE_DIR/$NAME.gz.partial-"*
    # NOTE: no -f, no redirect onto the final name. If compression is killed
    # mid-stream (SIGKILL/power loss) the *.partial-* file is left behind as
    # evidence and visible via GET /archive/usage; it can never be mistaken
    # for a formal archive and Postgres retries the whole segment anyway.
    if ! gzip -c -- "$SRC" > "$tmp"; then
      echo "archive-dispatcher: ERROR compression of $NAME interrupted/failed; leaving $tmp for inspection" >&2
      exit 1
    fi
    if verify_gzip "$tmp" "$SRC"; then
      publish "$tmp" "$dst"
    else
      rm -f "$tmp"
      echo "archive-dispatcher: ERROR gzip archive $NAME failed verification" >&2
      exit 1
    fi
    ;;
esac
