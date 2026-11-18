#!/usr/bin/env bash
# Self-test for the WAL archive dispatcher and the mixed-format restore helper.
# Runs entirely against temp directories (no Postgres, no Docker needed):
#   - gzip archival: verified publish, real byte savings
#   - plain (legacy) archival stays readable
#   - simulated mid-compression interruption: only a *.partial-* remains and
#     no formal archive exists; a retry completes the segment
#   - same-name retry never overwrites a completed segment
#   - corrupt gzip archive is rejected on retry, not overwritten/accepted
#   - restore helper picks plain vs gzip per segment, fails explicitly on
#     missing segments and corrupt/truncated gzip streams
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DISPATCHER="$HERE/../db/archive/archive-dispatcher.sh"
RESTORE="$HERE/../api/app/restore-wal.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ARCH="$WORK/wal_archive"
SRC="$WORK/pg_wal"
OUT="$WORK/restored"
mkdir -p "$ARCH" "$SRC" "$OUT"
export WAL_ARCHIVE_DIR="$ARCH"

pass=0; fail=0
check() { # <desc> <condition-result 0/1>
  if [ "$2" -eq 0 ]; then printf '  ok - %s\n' "$1"; pass=$((pass+1));
  else printf '  FAIL - %s\n' "$1" >&2; fail=$((fail+1)); fi
}

# A realistic 16 MiB WAL-ish payload (compressible so gzip clearly saves space).
SEG1=000000010000000000000001
SEG2=000000010000000000000002
SEG3=000000010000000000000003
make_seg() { head -c 16777216 /dev/zero | tr '\0' 'A' > "$SRC/$1"; }
make_seg "$SEG1"; make_seg "$SEG2"; make_seg "$SEG3"

echo "== gzip mode: complete write + verify before publishing =="
printf gzip > "$ARCH/.archive_mode"
"$DISPATCHER" "$SRC/$SEG1" "$SEG1"
[ -f "$ARCH/$SEG1.gz" ]; check "formal .gz archive published" $?
[ ! -e "$ARCH/$SEG1" ]; check "no raw file alongside the gzip archive" $?
gzip -t "$ARCH/$SEG1.gz"; check "gzip integrity check passes" $?
gzip -dc "$ARCH/$SEG1.gz" | cmp -s - "$SRC/$SEG1"; check "decompressed bytes match source" $?
raw=$(stat -c %s "$SRC/$SEG1"); gz=$(stat -c %s "$ARCH/$SEG1.gz")
[ "$gz" -lt "$raw" ]; check "gzip actually smaller ($gz < $raw bytes)" $?
ls "$ARCH" | grep -q 'partial-' && check "no partial leftovers after success" 1 || check "no partial leftovers after success" 0

echo "== same-name retry: completed segment is verified, never overwritten =="
inode_before=$(stat -c %i "$ARCH/$SEG1.gz")
"$DISPATCHER" "$SRC/$SEG1" "$SEG1"
inode_after=$(stat -c %i "$ARCH/$SEG1.gz")
[ "$inode_before" = "$inode_after" ]; check "retry keeps the existing completed file (same inode)" $?
count=$(ls "$ARCH" | grep -c "^$SEG1\.gz$")
[ "$count" -eq 1 ]; check "exactly one formal file after retry" $?

echo "== same-name retry with a tampered source: mismatch rejected =="
cp "$SRC/$SEG2" "$SRC/$SEG2.tmp"
"$DISPATCHER" "$SRC/$SEG2" "$SEG2"
printf 'X' | dd of="$SRC/$SEG2" bs=1 seek=100 count=1 conv=notrunc status=none
if "$DISPATCHER" "$SRC/$SEG2" "$SEG2" >/dev/null 2>&1; then
  check "mismatched retry is rejected (non-zero exit)" 1
else
  check "mismatched retry is rejected (non-zero exit)" 0
fi
[ -f "$ARCH/$SEG2.gz" ]; check "original good archive left untouched" $?

echo "== interrupted compression: no formal file, only a partial temp =="
# Replace gzip with a shim that writes half the output then dies like SIGKILL
# (exit 137, no cleanup of the output temp the shell redirected into).
SBIN="$WORK/shim"; mkdir -p "$SBIN"
cat > "$SBIN/gzip" <<'EOF'
#!/usr/bin/env bash
# emulate 'gzip -c -- SRC' being killed mid-stream: the dispatcher passes the
# WAL path as the last argument and redirects stdout into the partial temp.
src=""
for a in "$@"; do case "$a" in -*) ;; *) src="$a";; esac; done
head -c 8388608 "$src"
exit 137
EOF
chmod +x "$SBIN/gzip"
if PATH="$SBIN:$PATH" "$DISPATCHER" "$SRC/$SEG3" "$SEG3" >/dev/null 2>&1; then
  check "interrupted compression returns non-zero" 1
else
  check "interrupted compression returns non-zero" 0
fi
[ ! -e "$ARCH/$SEG3.gz" ]; check "no formal archive after interruption" $?
[ ! -e "$ARCH/$SEG3" ]; check "no misleading raw file after interruption" $?
npart=$(ls "$ARCH" | grep -c "\.partial-[0-9]\+$" || true)
[ "$npart" -ge 1 ]; check "partial temp file remains as evidence ($npart)" $?
psize=$(stat -c %s "$ARCH"/$SEG3.gz.partial-* 2>/dev/null | head -1)
[ "$psize" -eq 8388608 ]; check "partial holds only the half-written bytes ($psize)" $?

echo "== retry after interruption completes the segment (partial stays harmless) =="
"$DISPATCHER" "$SRC/$SEG3" "$SEG3"
[ -f "$ARCH/$SEG3.gz" ]; check "retry publishes the formal .gz" $?
gzip -dc "$ARCH/$SEG3.gz" | cmp -s - "$SRC/$SEG3"; check "retried archive content matches source" $?
nformal=$(ls "$ARCH" | grep -c "^$SEG3\.gz$" || true)
[ "$nformal" -eq 1 ]; check "exactly one formal archive for the segment" $?
# the stale partial cannot be picked up by restore (only the formal name is)
if "$RESTORE" "$ARCH" "$SEG3" "$OUT/$SEG3.retry" >/dev/null 2>&1; then
  check "restore ignores the partial and uses the formal archive" 0
else
  check "restore ignores the partial and uses the formal archive" 1
fi
cmp -s "$OUT/$SEG3.retry" "$SRC/$SEG3"; check "restored bytes match the source" $?

echo "== plain mode preserves legacy uncompressed behaviour =="
SEG4=000000010000000000000004
make_seg "$SEG4"
printf plain > "$ARCH/.archive_mode"
"$DISPATCHER" "$SRC/$SEG4" "$SEG4"
[ -f "$ARCH/$SEG4" ] && [ ! -e "$ARCH/$SEG4.gz" ]; check "plain segment archived uncompressed" $?
cmp -s "$ARCH/$SEG4" "$SRC/$SEG4"; check "plain archive byte-identical to source" $?
"$DISPATCHER" "$SRC/$SEG4" "$SEG4"; check "plain same-name retry succeeds idempotently" $?
# switching back to gzip must not duplicate a segment already archived plain
printf gzip > "$ARCH/.archive_mode"
"$DISPATCHER" "$SRC/$SEG4" "$SEG4"
[ ! -e "$ARCH/$SEG4.gz" ]; check "existing plain segment is not re-archived as gzip" $?

echo "== restore helper: per-segment format selection =="
"$RESTORE" "$ARCH" "$SEG1" "$OUT/$SEG1"
cmp -s "$OUT/$SEG1" "$SRC/$SEG1"; check "gzip segment restored via streamed decompression" $?
"$RESTORE" "$ARCH" "$SEG4" "$OUT/$SEG4"
cmp -s "$OUT/$SEG4" "$SRC/$SEG4"; check "plain segment restored via raw copy" $?

echo "== restore helper: explicit failure on missing segment =="
MISSING=000000010000000000000099
if "$RESTORE" "$ARCH" "$MISSING" "$OUT/$MISSING" >/dev/null 2>&1; then
  check "missing segment fails non-zero" 1
else
  check "missing segment fails non-zero" 0
fi
[ ! -e "$OUT/$MISSING" ]; check "no partial destination left on missing segment" $?

echo "== restore helper: corrupt gzip stream fails loudly and leaves nothing =="
SEG5=000000010000000000000005
make_seg "$SEG5"
"$DISPATCHER" "$SRC/$SEG5" "$SEG5"
# truncate the gzip archive to half its length (broken CRC/stream)
good_size=$(stat -c %s "$ARCH/$SEG5.gz")
head -c $((good_size / 2)) "$ARCH/$SEG5.gz" > "$ARCH/$SEG5.gz.broken"
mv "$ARCH/$SEG5.gz.broken" "$ARCH/$SEG5.gz"
if "$RESTORE" "$ARCH" "$SEG5" "$OUT/$SEG5" >/dev/null 2>&1; then
  check "corrupt gzip fails non-zero" 1
else
  check "corrupt gzip fails non-zero" 0
fi
[ ! -e "$OUT/$SEG5" ]; check "no half-decompressed file left behind" $?

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
