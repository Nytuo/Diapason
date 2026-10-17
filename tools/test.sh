#!/usr/bin/env bash
# Local test runner for Diapason. There is no CI for tests on purpose: run this
# before you push or release.
#
#   tools/test.sh              fast tests: unit + widget + the uploader contract tests
#   tools/test.sh unit         everything under test/ except the uploader contract tests
#   tools/test.sh contract     the app against the real uploader server (needs Go + the uploader source)
#   tools/test.sh integration  drive the whole app on this machine (macOS/Linux/Windows desktop)
#   tools/test.sh live         tests that use the real internet / real yt-dlp (YTDLP_INTEGRATION=1)
#   tools/test.sh all          all of the above
#   tools/test.sh it "name"     one integration test or group by name, or a whole file: it sources
#   tools/test.sh shards      integration files in parallel, one project copy per shard (-n 4 for 4 shards)
#   tools/test.sh explore     press-everything-at-random tests (opt in; not part of the other modes)
#   tools/test.sh coverage    unit + integration merged, honest total (fails below COVERAGE_MIN, default 58)
#
# Extra arguments are passed to `flutter test`, e.g.  tools/test.sh unit --plain-name "settings"
set -euo pipefail
cd "$(dirname "$0")/.."

mode="${1:-fast}"
[ $# -gt 0 ] && shift

device() {
  case "$(uname -s)" in
    Darwin) echo macos ;;
    Linux) echo linux ;;
    *) echo windows ;;
  esac
}

unit() {
  echo "== unit and widget tests"
  files=()
  for f in test/*_test.dart; do
    [ "$f" = test/uploader_contract_test.dart ] || files+=("$f")
  done
  flutter test "${files[@]}" "$@"
}

contract() {
  echo "== contract tests (app <-> real uploader server)"
  flutter test test/uploader_contract_test.dart "$@"
}

integration() {
  echo "== integration tests on $(device)"
  for f in integration_test/*_test.dart; do
    case "$f" in
      *test_cases.dart) continue ;;
      *explore_test.dart) continue ;;
    esac
    echo "-- $f"
    flutter test "$f" -d "$(device)" "$@"
  done
}

live() {
  echo "== live tests (internet, real yt-dlp, public demo server)"
  YTDLP_INTEGRATION=1 flutter test test/ytdlp_test.dart "$@"
  flutter test integration_test/test_cases.dart -d "$(device)" "$@"
}

# One integration test (or group) by part of its name, without running the rest. Each test signs in by
# itself when the app starts signed out, so this works from a cold start:
#   tools/test.sh it "a Plex server can be added"
#   tools/test.sh it "the play queue"
one_integration() {
  [ $# -ge 1 ] || { echo 'usage: tools/test.sh it "part of the test name" | tools/test.sh it <file>'; exit 2; }
  name="$1"
  shift
  if [ -f "integration_test/${name%_test.dart}_test.dart" ]; then
    flutter test "integration_test/${name%_test.dart}_test.dart" -d "$(device)" "$@"
    return
  fi
  file="$(grep -lF -- "$name" integration_test/*_test.dart | head -1 || true)"
  [ -n "$file" ] || { echo "no integration test mentions: $name"; exit 2; }
  flutter test "$file" -d "$(device)" --plain-name "$name" "$@"
}

case "$mode" in
  it) one_integration "$@" ;;
  explore) flutter test integration_test/explore_test.dart -d "$(device)" --dart-define=EXPLORE=true "$@" ;;
  shards) tools/integration_shards.sh "$@" ;;
  fast) unit "$@"; contract ;;
  unit) unit "$@" ;;
  contract) contract "$@" ;;
  integration) integration "$@" ;;
  live) live "$@" ;;
  all) unit; contract; integration; live ;;
  coverage)
    mkdir -p coverage
    flutter test --coverage --coverage-path=coverage/unit.lcov --concurrency="$(getconf _NPROCESSORS_ONLN)" "$@" \
      > coverage/unit.log 2>&1 &
    unit_pid=$!
    if [ -n "${SHARDS:-}" ]; then tools/integration_shards.sh -n "$SHARDS" || true; else tools/integration_shards.sh || true; fi
    wait "$unit_pid" || { tail -30 coverage/unit.log; exit 1; }
    tail -2 coverage/unit.log
    python3 tools/coverage_report.py --min "${COVERAGE_MIN:-58}" coverage/unit.lcov coverage/shards/*.lcov
    ;;
  *) sed -n '2,15p' "$0"; exit 2 ;;
esac
