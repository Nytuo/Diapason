# Tests

There is **no CI for tests on purpose** — run them here, before you push or release:

```bash
tools/test.sh              # fast: unit + widget + the uploader contract tests (~1 min)
tools/test.sh integration  # drives the whole app on this machine against a local fake server (~3 min)
tools/test.sh live         # needs internet: real yt-dlp, public Jellyfin demo server
tools/test.sh all
tools/test.sh coverage     # fast tests + lcov summary
```

Pass anything after the mode to `flutter test`, e.g. `tools/test.sh unit --plain-name "search"`.

## The layers

| Layer | Where | What it proves | Needs |
|---|---|---|---|
| **Unit / widget** | `test/*_test.dart` | Logic and screens in isolation. | nothing |
| **Contract** | `test/uploader_contract_test.dart` | The app's `UploaderClient` against the *real* Go uploader server, built from source and run on loopback, with a fake yt-dlp behind it. Catches the two repos drifting apart (renamed endpoint, changed error code…). | Go + the `diapason-uploader` source next to this repo (or `DIAPASON_UPLOADER_DIR`); skipped otherwise |
| **Integration** | `integration_test/subsonic_flow_test.dart` | The real app, launched, signing in to a Navidrome look-alike, browsing, playing (and the server seeing "Now Playing"), YouTube appearing and disappearing, the settings screens. No internet. | a desktop OS to run on |
| **Live** | `YTDLP_INTEGRATION=1` in `test/ytdlp_test.dart`, `integration_test/test_cases.dart` | Things only the real world can tell you: yt-dlp still parses YouTube, the installer's downloads still verify, the demo server still logs in. | internet |

## The fakes (`test/support/`)

Everything outside the code under test is replaced by something deterministic that runs offline:

- **`fake_ytdlp.dart`** — a shell script that behaves like yt-dlp: JSON for searches, URLs for `--print`, files for downloads, and failure modes (`bot`, `unavailable`, `network`, `slow`, `garbage`) steered with `setMode`. It records every call, so tests can assert the exact command line. POSIX only.
- **`mock_subsonic.dart`** — an in-memory Subsonic/Navidrome: checks the salted-token login like the real thing, serves a small library and audio, records every request (so tests can check what the app reported, e.g. scrobbles). Works as an `http.Client` for unit tests or as a real loopback HTTP server.
- **`uploader_process.dart`** — builds and starts the real uploader.
- **`stub_youtube.dart`** — a `YouTubeService` whose answers the test decides.
- **`test_env.dart`** — a throwaway directory, fake `path_provider`, and the app's Hive boxes opened in it, so anything that reads settings works.

## Writing a test

- Test behaviour a person would notice ("a skip is not a play"), not private details.
- Put the *reason* in the test name or an `expect(..., reason:)`: the next person to break it should learn why it matters.
- When something is fixed because it broke, add the test that would have caught it.
- Never hit the real internet from the default suites. If you must, put it under `live`.
- Tests that start processes or servers clean up in `tearDown`; leave nothing running.

## Troubleshooting

- *"HiveError: Box not found"* — the code reads settings; call `TestEnv.create()` then `openHive()` in `setUp`.
- *Everything returns HTTP 400 in a test* — Flutter's test binding fakes HTTP. `TestEnv.create()` switches the real client back on for local servers.
- *Timers don't fire in a widget test* — a timer created during a frame only fires on the **next** `pump(Duration)`.
- *The contract tests are skipped* — the message says whether Go or the uploader source is missing.

## Coverage

`tools/test.sh coverage` runs the unit tests and the integration suite and merges them with
`tools/coverage_report.py`, which counts files no test loads as 0% (lcov alone leaves them out, which makes
the number look better than it is). Generated code is excluded. It fails below `COVERAGE_MIN` (default 58, the current level; raise it as coverage grows).

## Running integration tests

Each file in `integration_test/` is independent: it launches the app, signs in to the mock server by itself and
can be run alone.

```bash
tools/test.sh it sources            # one whole file (sources, uploader, features, play_queue, ...)
tools/test.sh it "the play queue"   # one group or test, found by name in whichever file holds it
tools/test.sh integration           # every file, one after the other
tools/test.sh shards -n 3           # every file in parallel, one project copy per shard
tools/test.sh shards sources uploader
tools/test.sh explore               # press-everything-at-random tests (opt in, can leave the app broken)
```

`shards` copies the project into `$TMPDIR/diapason-shards/s1..sN` (their own `build/` and app data folders), so
parallel runs do not trample each other. The first run of a shard builds the app; later runs are incremental.
