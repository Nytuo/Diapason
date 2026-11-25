# Plugins

Diapason plugins add lyrics, cover art, menu actions and more without changing the app. They are installed from
**Settings → Plugins** (also reachable from the desktop header's settings button): from a catalog URL or from a
`.zip` file. Each plugin declares what it needs; nothing runs until the user approves it, and the host enforces it.

The design follows Chilpa's plugin system (manifest + catalog + per-plugin permissions + sandbox), adapted to what a
Flutter app can ship on every platform it runs on, including iOS and tvOS.

## Why WebAssembly, interpreted in Dart

Chilpa runs plugin *processes* inside bubblewrap/Seatbelt. That is not possible on iOS, tvOS or Android: an app may
not download and run native code, and there are no process sandboxes to use. So Diapason plugins are either:

- **declarative**: no code at all, a JSON file of HTTP request templates and JSON paths that the host interprets; or
- **WebAssembly**, run by [WASD](https://pub.dev/packages/wasd), a WebAssembly interpreter written in pure Dart.

Reasons for WASD over the alternatives:

| Option | Why not |
| --- | --- |
| Native code (dylib/so/dll) | Forbidden on iOS/tvOS, unsandboxable everywhere. |
| JavaScript via `flutter_js` / QuickJS / JavaScriptCore | Ships a native engine per platform (no tvOS, WearOS builds to maintain), and JS engines expose far more surface than needed. |
| `wasmtime`/`wasmer` bindings | Native JIT/AOT runtimes: JIT is forbidden on iOS, and they need per-platform binaries. |
| Dart `dart_eval` | Dart-only plugins, a large interpreter, weaker isolation story. |
| **WASD (chosen)** | Pure Dart: works wherever Dart runs (iOS, tvOS, Android, desktop, WearOS) with no native binary. A module can only call the imports the host gives it; there is no WASI, no file system, no sockets. Any language that compiles to `wasm32` (C, Rust, Zig, AssemblyScript, TinyGo) can be used. |

Interpretation is slow compared to a JIT, which is fine for what plugins do (build a request, parse an answer); the
heavy work (HTTP, JSON decoding of large answers when the plugin wants it, image loading) is done by the host.

## Sandbox

| Concern | How |
| --- | --- |
| Code | WASM is interpreted in a **separate isolate** per plugin. Imports are limited to `diapason.host_call` and `diapason.host_result`; a module importing anything else is refused at install. |
| Network | Only through the host's fetch, **https only**, to the hosts declared in the manifest and approved (`*.example.com` covers subdomains, never a bare `*`). Redirects are followed by the host and every hop is checked. `Cookie`/`Host` headers are dropped, `Set-Cookie` is not returned. Responses are capped at 2 MiB, requests time out after 10 s. Offline mode (and the "no network" switch) block everything. |
| URLs handed to the app | Cover art and source images must be on an approved host (others are dropped and logged). Commands may only open http(s) pages. Radio streams may be any http(s) URL (played, never fetched by the plugin). |
| Storage | A JSON key-value store of its own (1 MiB), only with the `storage` permission. No other file is reachable. Cleared on uninstall, or from the plugin's page. |
| App features | Playback control, now playing and library search each need their own permission. |
| Time | Each call has a 20 s budget. Past it the isolate is killed (this stops endless loops too) and restarted on the next call. A trap discards the instance. After 5 failures in a row the plugin is suspended until it is re-enabled. |
| Memory | A plugin using more than 64 MiB of linear memory fails the call. |
| Packages | Max 20 MiB zipped, 50 MiB unpacked, 500 files; no absolute paths, `..`, backslashes or symlinks. Catalog installs must match the catalog's SHA-256. |
| Failures | A failing plugin never breaks a lookup: the adapter logs and returns nothing. Menu actions report their error in a snackbar. |
| Permissions | Unknown permission types make the manifest invalid (fail closed). Updates that declare more need approval of the *new* permissions; until then the plugin does not run. |

Each plugin has its own log (last 500 lines), shown on its page in Settings → Plugins and forwarded to the app log
under `Plugin:<id>`.

## Package

A plugin is a zip with `manifest.json` at its root and its entry file:

```json
{
  "manifestVersion": 1,
  "id": "org.example.my-plugin",
  "name": "My plugin",
  "version": "1.0.0",
  "author": "Me",
  "description": "What it does.",
  "homepage": "https://example.org",
  "minAppVersion": "0.11.0",
  "runtime": "wasm",
  "entry": "plugin.wasm",
  "permissions": [
    { "type": "network", "hosts": ["api.example.org", "*.images.example.org"] },
    { "type": "storage" }
  ],
  "extensions": [
    { "point": "lyrics", "title": "Example lyrics" },
    { "point": "command", "id": "open", "title": "Open on Example", "targets": ["track", "album", "artist"] }
  ]
}
```

- `id`: lowercase reverse domain. `version`, `minAppVersion`: semver.
- `runtime`: `declarative` (entry is a `.json`) or `wasm` (entry is a `.wasm`).
- Permissions: `network` (with `hosts`), `storage`, `playback_control`, `now_playing`, `library_read`.
- Extension points: `lyrics`, `cover_art`, `metadata`, `radio_directory`, `scrobbler`, `source`, `command`. Each may
  appear once, except `command` (one per menu action, each with a unique `id`, a `title` and `targets`).

## Catalog

A catalog is a JSON file served over http(s), with packages next to it or anywhere else:

```json
{
  "version": 1,
  "name": "My catalog",
  "plugins": [
    {
      "id": "org.example.my-plugin",
      "name": "My plugin",
      "version": "1.0.0",
      "author": "Me",
      "description": "What it does.",
      "minAppVersion": "0.11.0",
      "extensions": ["lyrics", "command"],
      "package": "dist/my-plugin.zip",
      "sha256": "<sha-256 of the zip, hex>"
    }
  ]
}
```

Relative `package` URLs resolve against the catalog URL. A plugin installed from a catalog is updated only from that
catalog. `plugins/package_examples.sh` builds `plugins/dist/*.zip` and `plugins/catalog.json` from the examples; once
the repository is public that catalog can be added as
`https://raw.githubusercontent.com/Nytuo/Diapason/main/plugins/catalog.json`.

## Extension points

Every call is a method name and JSON params; the answer is JSON. The host validates every answer (types, lengths,
URLs) before the app sees it. Returning `null` means "nothing".

| Point | Method | Params | Result |
| --- | --- | --- | --- |
| `lyrics` | `lyrics.get` | `title, artist, album, durationMs, durationSeconds` | `{ "synced": "[00:12.00] LRC…", "plain": "…" }` |
| `cover_art` | `coverArt.find` | `kind` (`album`/`track`/`artist`), `artist, album, title` | `{ "urls": ["https://…"] }` best first |
| `metadata` | `metadata.track` | as `lyrics.get` | `{ "genres": [], "year": 1997, "bio": "…", "extra": {} }` |
| `radio_directory` | `radio.search` | `query, limit` | `{ "stations": [{ "name", "streamUrl", "homepage", "imageUrl", "tags": [], "country" }] }` |
| `scrobbler` | `scrobbler.nowPlaying`, `scrobbler.scrobble` | `title, artist, album, durationMs` (+ `playedAt`, Unix s) | `null` |
| `source` | `source.search` / `source.browse` / `source.streamUrl` | `query` / `parentId` / `id` | `{ "items": [{ "id", "type", "title", "artist", "album", "durationMs", "imageUrl" }] }` / `{ "url" }` |
| `command` | `command.run` | `command` (the extension `id`), `item: { type, id, name, title, artist, album }` | `{ "message": "…", "openUrl": "https://…" }` |

What is wired into the app today:

- **Lyrics**: `LyricsSources` asks plugins after the library, LRCLIB and the word-synced databases; a plugin's
  lyrics are used when the built-in sources found nothing synced. Plugins also show as a source in the lyrics source
  picker, labelled with the plugin's name.
- **Cover art**: items without art in the library get a plugin's cover (album, track or artist), looked up once per
  session.
- **Menu actions**: track, album and artist menus list the commands enabled plugins contribute.
- **Scrobbling**: `ScrobbleService` sends now playing and qualifying plays to scrobbler plugins too, even when
  Last.fm and ListenBrainz are off (no retry queue for plugins).
- **Radio directory, metadata, source**: typed interfaces in `lib/services/plugins/extension_points.dart`,
  registered in `ExtensionRegistry` (`radioDirectories`, `metadataProviders`, `sources`). Features consume them from
  the registry; nothing in the app calls them yet.

Built-in Dart code can register implementations in the same registry, so a feature does not need to care whether an
entry comes from a plugin.

## Declarative plugins

`handlers.json` has one entry per extension point (`lyrics`, `cover_art`, `radio_directory` only):

```json
{
  "lyrics": {
    "request": { "url": "https://api.lyrics.ovh/v1/{artist}/{title}" },
    "response": { "plain": "$.lyrics" }
  },
  "cover_art": {
    "request": { "url": "https://api.deezer.com/search/album?limit=3&q={artist}%20{album}" },
    "response": { "urls": "$.data[*].cover_xl" }
  }
}
```

- `request`: `url` (https; `{param}` is replaced by the URL-encoded call parameter), optional `method` (`GET`,
  `POST`), `headers`, `body` (`{param}` replaced as is). If a parameter the template uses is empty, the call returns
  nothing without a request.
- `response`: JSON paths (`$`, `.key`, `[n]`, `[*]`). Lyrics: `plain`, `synced`. Cover art: `urls`. Radio: `items`
  (the list) and, relative to each item, `name`, `streamUrl`, `homepage`, `imageUrl`, `tags` (comma separated or
  first value), `country`.
- A 404 or 204 means "nothing"; other non-2xx statuses are logged as failures.

## WebAssembly plugins

### ABI

The module exports:

- `memory`
- `diapason_alloc(size: i32) -> i32`: memory for the host to write a request into.
- `diapason_handle(ptr: i32, len: i32) -> i32`: handles the UTF-8 JSON request `{"method": "...", "params": {...}}` and
  returns a pointer to `[u32 little-endian length][UTF-8 JSON]`, the JSON being `{"result": ...}` or `{"error": "..."}`.
- optional `diapason_reset()`: called before each request (e.g. to reset a bump allocator).

and may import only, from module `diapason`:

- `host_call(ptr: i32, len: i32) -> i32`: sends a JSON host request, returns the length of the JSON answer.
- `host_result(dst: i32)`: copies that answer to `dst` (allocate `length` bytes first).

Calls into a plugin are serialized (one at a time per plugin).

### Host requests

Every answer is a JSON object; failures are `{"error": "...", "denied": true|false}` (`denied` when a permission is
missing).

| `op` | Fields | Answer | Needs |
| --- | --- | --- | --- |
| `log` | `level` (`debug`/`info`/`warning`/`error`), `message` | `{}` | — |
| `http.fetch` | `url`, `method`?, `headers`?, `body`? | `{ "status", "url", "headers", "body" }` | `network` |
| `storage.get` / `storage.set` / `storage.delete` / `storage.keys` | `key`, `value` (string) | `{ "value" }` / `{}` / `{}` / `{ "keys" }` | `storage` |
| `player.control` | `action`: `play`, `pause`, `toggle`, `next`, `previous` | `{}` | `playback_control` |
| `player.nowPlaying` | — | `{ "track": { "title", "artist", "album", "durationMs" } \| null }` | `now_playing` |
| `library.search` | `query`, `limit`? (≤ 100) | `{ "items": [{ "type", "id", "name", "artist", "album" }] }` | `library_read` |

### C SDK and example

`plugins/sdk/c/diapason_plugin.h` is a header-only, libc-free helper (bump allocator, string builder, minimal JSON
reading, host calls). `plugins/examples/musicbrainz-wasm` uses it: two menu actions, one opening a MusicBrainz search
(and counting its uses in storage), one fetching the number of matches from the MusicBrainz API.

Build it with any clang that has the WebAssembly target and a `wasm-ld`:

```sh
plugins/examples/musicbrainz-wasm/build.sh
# Apple's clang + Rust's linker work too:
WASM_LD="$(rustc --print sysroot)/lib/rustlib/$(rustc -vV | sed -n 's/host: //p')/bin/rust-lld -flavor wasm" \
  plugins/examples/musicbrainz-wasm/build.sh
```

Rust works the same way (`cargo build --target wasm32-unknown-unknown`, `#[no_mangle] extern "C"` exports and
`#[link(wasm_import_module = "diapason")]` imports).

### Example plugins

| Folder | Runtime | Provides |
| --- | --- | --- |
| `plugins/examples/lyrics-ovh-deezer` | declarative | Plain lyrics from lyrics.ovh, cover art from Deezer |
| `plugins/examples/musicbrainz-wasm` | WASM (C) | Menu actions: open in MusicBrainz, count matches (uses network and storage) |

## Code map

| File | Role |
| --- | --- |
| `lib/services/plugins/plugin_manifest.dart` | Manifest, permissions, extension declarations, validation |
| `lib/services/plugins/plugin_package.dart` | Zip reading and checks |
| `lib/services/plugins/plugin_catalog.dart` | Catalog format |
| `lib/services/plugins/plugin_host.dart` | Host bridge (permission checks, fetch, storage), per-plugin logs |
| `lib/services/plugins/plugin_runtime.dart` | Runtime interface, method names, declarative runtime, JSON paths |
| `lib/services/plugins/wasm_runtime.dart` | WASM runtime: worker isolate, ABI, timeouts, suspension |
| `lib/services/plugins/extension_points.dart` | Typed extension interfaces and `ExtensionRegistry` |
| `lib/services/plugins/plugin_extensions.dart` | Adapters from a plugin to typed extensions (answer validation) |
| `lib/services/plugins/plugin_manager.dart` | Install/update/enable/disable/uninstall, `Plugins` Hive box (JSON strings, no type adapters) |
| `lib/services/plugins/plugins.dart` | App setup and helpers used by lyrics, cover art and menus |
| `lib/screens/plugins_settings_screen.dart` | Settings → Plugins, plugin page, approval dialog |

Plugin state lives in its own Hive box `Plugins` (string values: one JSON record per plugin plus the catalog list);
packages are unpacked under `<app support>/plugins/packages/<id>/` and plugin storage under
`<app support>/plugins/data/<id>/`. No `FinampSettings` field or Hive type id is used.

## Limits and next steps

- No signature check beyond the catalog checksum; catalogs are trusted by the user who adds them.
- The worker isolate cannot cap CPU other than by the call timeout.
- Radio directory, metadata and source extensions are not consumed by app features yet.
- Plugin-provided settings UI is not supported; plugins can only keep their own storage.
