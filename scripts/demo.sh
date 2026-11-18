#!/usr/bin/env bash
# End-to-end demo of the PITR recovery flow with a gzip archive rollover:
#   collect (plain archives) -> switch primary to gzip -> restore point ->
#   accidental delete -> keep collecting (gzip archives) -> recover across the
#   format boundary -> verify the replica replays plain + gzip segments and the
#   /archive/usage accounting shows both formats with real byte savings.
# Run against a live stack (default http://localhost:8000; override with BASE).
set -euo pipefail

BASE="${BASE:-http://localhost:8000}"
POINT="${POINT:-before_delete}"

say()  { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
fail() { printf '\033[31mFAIL: %s\033[0m\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || fail "missing dependency: $1"; }
need curl; need jq

wait_usage() { # <jq filter> <expected> <label>
  local filter="$1" expected="$2" label="$3" got=""
  for _ in $(seq 1 60); do
    got=$(curl -fsS "$BASE/archive/usage" | jq -r "$filter")
    [ "$got" = "$expected" ] && return 0
    sleep 2
  done
  fail "$label: expected $expected, last: ${got:-unknown}"
}

say "0. wait for the API and the startup physical base backup"
status=""
for _ in $(seq 1 90); do
  status=$(curl -fsS "$BASE/backup" 2>/dev/null | jq -r '.status // empty' || true)
  [ "$status" = "ready" ] && break
  sleep 2
done
[ "$status" = "ready" ] || fail "base backup never became ready (last: ${status:-unknown})"
curl -fsS "$BASE/backup" | jq .

say "1. simulate first collection wave while the primary still archives PLAIN wal"
curl -fsS -X PUT "$BASE/archive/mode" -H 'Content-Type: application/json' \
  -d '{"mode":"plain"}' | jq .
curl -fsS -X POST "$BASE/demo/generate?intersections=3&minutes=20&prefix=IX" | jq .
# archive_timeout is 10s; wait until at least one formal plain segment exists.
wait_usage '.formats.plain.files > 0' "true" "no plain WAL segment archived"
curl -fsS "$BASE/archive/usage" | jq .

say "2. roll the primary over to gzip for all new segments"
curl -fsS -X PUT "$BASE/archive/mode" -H 'Content-Type: application/json' \
  -d '{"mode":"gzip"}' | jq .

say "3. create named restore point '$POINT' (its range spans plain + gzip WAL)"
curl -fsS -X POST "$BASE/restore-points?name=$POINT" | jq .

rp=""
for _ in $(seq 1 60); do
  rp=$(curl -fsS "$BASE/restore-points" | jq -r --arg p "$POINT" \
       '.items[] | select(.name==$p) | .status')
  [ "$rp" = "ready" ] && break
  sleep 2
done
[ "$rp" = "ready" ] || fail "restore point never became ready"
# both formats must now be represented in the archive
usage=$(curl -fsS "$BASE/archive/usage")
echo "$usage" | jq .
echo "$usage" | jq -e '.formats.plain.files > 0 and .formats.gzip.files > 0' >/dev/null \
  || fail "restore point ready but archive does not contain both formats"
echo "$usage" | jq -e '.partial_files | length == 0' >/dev/null \
  || fail "partial temp files leaked into the formal archive"

say "4. operator accident: delete the latest 10 minutes on the primary"
curl -fsS -X POST "$BASE/demo/delete?minutes=10" | jq .

say "5. primary keeps collecting (new IXB intersections) - still gzip, not blocked"
curl -fsS -X POST "$BASE/demo/generate?intersections=2&minutes=3&prefix=IXB" | jq .
wait_usage '.archive_mode' "gzip" "archive mode did not stay gzip"

say "6. start PITR recovery to '$POINT' across the format boundary"
rec=$(curl -fsS -X POST "$BASE/recoveries" -H 'Content-Type: application/json' \
      -d "{\"restore_point\":\"$POINT\"}")
echo "$rec" | jq .
rid=$(echo "$rec" | jq -r .id)

st=""
for _ in $(seq 1 90); do
  st=$(curl -fsS "$BASE/recoveries/$rid" | jq -r .status)
  [ "$st" = "success" ] && break
  if [ "$st" = "failed" ]; then
    curl -fsS "$BASE/recoveries/$rid" | jq .
    fail "recovery failed"
  fi
  sleep 2
done
[ "$st" = "success" ] || fail "recovery did not succeed (last status: $st)"
curl -fsS "$BASE/recoveries/$rid" | jq .

say "7. query the recovered read-only replica"
replica=$(curl -fsS "$BASE/replica/traffic?limit=1000")
echo "$replica" | jq '{recovery: .recovery, total_rows: .total_rows, sample: .rows[0:3]}'

say "8. compare with the primary (which kept collecting)"
primary=$(curl -fsS "$BASE/primary/traffic?limit=1000")
echo "$primary" | jq '{total_rows: .total_rows, sample: .rows[0:3]}'

replica_total=$(echo "$replica" | jq .total_rows)
replica_ixb=$(echo "$replica" | jq '[.rows[] | select(.intersection_id | startswith("IXB"))] | length')
primary_total=$(echo "$primary" | jq .total_rows)
primary_ixb=$(echo "$primary" | jq '[.rows[] | select(.intersection_id | startswith("IXB"))] | length')

say "9. assertions"
[ "$replica_total" = "60" ] || fail "replica should hold 60 rows (pre-delete state), got $replica_total"
[ "$replica_ixb"  = "0"  ] || fail "replica must not contain post-restore-point commits (IXB), got $replica_ixb"
[ "$primary_total" = "36" ] || fail "primary should hold 36 rows (30 left + 6 new), got $primary_total"
[ "$primary_ixb"  = "6"  ] || fail "primary should hold 6 IXB rows, got $primary_ixb"

say "10. archive accounting: gzip really occupies fewer bytes than the same WAL raw"
final_usage=$(curl -fsS "$BASE/archive/usage")
echo "$final_usage" | jq .
echo "$final_usage" | jq -e '.formats.gzip.files > 0' >/dev/null \
  || fail "no gzip segments accounted for"
echo "$final_usage" | jq -e '.formats.gzip.allocated_bytes < .formats.gzip.logical_bytes' >/dev/null \
  || fail "gzip segments show no space saving"
echo "$final_usage" | jq -e '.total_allocated_bytes == (.formats.plain.allocated_bytes + .formats.gzip.allocated_bytes)' >/dev/null \
  || fail "total allocated bytes inconsistent with per-format breakdown"

printf '\n\033[32mDEMO OK: mixed plain/gzip WAL archived, recovered across the format boundary, space accounting reconciled; the primary kept collecting.\033[0m\n'
