#!/usr/bin/env bash
# Runs the integration test files in parallel, each shard in its own copy of the project.
#
#   tools/integration_shards.sh                 half as many shards as cores, every file except explore_test
#   tools/integration_shards.sh -n 4            4 shards
#   tools/integration_shards.sh sources uploader   only these files (name without _test.dart)
#
# Per-file logs and coverage land in coverage/shards/. Exit status is non-zero if any file failed.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
root="$PWD"

cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
shards=$(( cores / 2 > 1 ? cores / 2 : 1 ))
files=()
while [ $# -gt 0 ]; do
  case "$1" in
    -n) shards="$2"; shift 2 ;;
    *) files+=("integration_test/${1%_test.dart}_test.dart"); shift ;;
  esac
done
if [ ${#files[@]} -eq 0 ]; then
  for f in integration_test/*_test.dart; do
    [ "$f" = integration_test/explore_test.dart ] || files+=("$f")
  done
fi
[ "$shards" -gt "${#files[@]}" ] && shards=${#files[@]}

case "$(uname -s)" in Darwin) device=macos ;; Linux) device=linux ;; *) device=windows ;; esac

work="${TMPDIR:-/tmp}/diapason-shards"
out="$root/coverage/shards"
mkdir -p "$work" "$out"
rm -f "$out"/*.lcov "$out"/*.log "$out"/*.status

sync_shard() {
  local dir="$work/s$1"
  mkdir -p "$dir"
  rsync -a --delete \
    --exclude '.git' --exclude 'build' --exclude '.dart_tool/flutter_build' --exclude 'coverage' --exclude 'integration_test/testing' \
    --exclude 'macos/build' --exclude 'ios/build' --exclude 'android/build' \
    "$root/" "$dir/" >/dev/null
}

refresh_shard() {
  (
    cd "$work/s$1" || exit 1
    if ! flutter pub get --offline >/dev/null 2>&1; then flutter pub get >/dev/null 2>&1; fi
  )
}

run_shard() {
  local i="$1"
  shift
  local dir="$work/s$i"
  for f in "$@"; do
    local name code
    name="$(basename "$f" _test.dart)"
    for attempt in 1 2; do
      (cd "$dir" || exit 1; flutter test "$f" -d "$device" --coverage --coverage-path="$out/$name.lcov") \
        >"$out/$name.log" 2>&1
      code=$?
      if [ "$code" != 0 ] && [ "$attempt" = 1 ] && grep -q "BUILD FAILED" "$out/$name.log"; then
        rm -rf "$dir/build" "$dir/macos/Pods/build"
        continue
      fi
      break
    done
    echo "$code" >"$out/$name.status"
  done
}

echo "== syncing $shards shard copies"
for i in $(seq 1 "$shards"); do sync_shard "$i" & done
wait
for i in $(seq 1 "$shards"); do refresh_shard "$i"; done

for i in $(seq 1 "$shards"); do assigned[i]=""; done
n=0
for f in "${files[@]}"; do
  i=$(( n % shards + 1 ))
  assigned[i]="${assigned[$i]} $f"
  n=$(( n + 1 ))
done

echo "== running ${#files[@]} files on $shards shards"
for i in $(seq 1 "$shards"); do
  run_shard "$i" ${assigned[$i]} &
done
wait

failed=0
for f in "${files[@]}"; do
  name="$(basename "$f" _test.dart)"
  status="$(cat "$out/$name.status" 2>/dev/null || echo '?')"
  last="$(grep -E '^[0-9]{2}:[0-9]{2} \+[0-9]+' "$out/$name.log" | tail -1 | cut -c1-90)"
  printf '%-12s exit %-2s %s\n' "$name" "$status" "$last"
  [ "$status" = 0 ] || failed=1
done
echo "logs and coverage: coverage/shards/"
exit $failed
