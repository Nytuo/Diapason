<h1 align="center">
  <img src="images/diapason.png" alt="Diapason" width="auto" height="160">
</h1>

<div align="center">
<h2>Diapason</h2>
Pure Sound, Local Heart, Total Control
<br />
<br />
<a href="https://github.com/Nytuo/diapason/issues/new?labels=bug&title=bug%3A+">Report a Bug</a>
·
<a href="https://github.com/Nytuo/diapason/issues/new?labels=enhancement&title=feat%3A+">Request a Feature</a>
·
<a href="https://github.com/Nytuo/Diapason/discussions">Ask a Question</a>
</div>
</div>

<details open="open">
<summary>Table of Contents</summary>

- [About](#about)
  - [Architecture \& Development](#architecture--development)
  - [Project Name](#project-name)
- [What Diapason Can Do And How It Compares To Finamp ?](#what-diapason-can-do-and-how-it-compares-to-finamp-)
- [Building](#building)
- [Credits](#credits)
- [Authors \& contributors](#authors--contributors)
- [License](#license)
- [More from the Diapason familly](#more-from-the-diapason-familly)

</details>

---

## About

Diapason is a cross-platform music client providing unified access to multiple music library backends. The application is open-source, ad-free, and available for Desktop (Windows, Linux, macOS), Android, iOS, Android TV, and WearOS. Supported backends include Jellyfin, Plex, Subsonic/Navidrome, MPD, and local file libraries.

### Architecture & Development

Diapason is a fork of [Finamp](https://github.com/finamp-app/finamp), an open-source Jellyfin client. The project evolved to support multiple platforms and backends through a multi-generation development approach:

- **Generation 1 (Desktop)**: Implemented in Tauri (Rust + React) to provide a native desktop experience.
- **Generation 2 (Mobile)**: Initial prototypes for iOS and Android using native frameworks yielded suboptimal UX consistency. Integration with the Finamp codebase was selected to leverage its established mobile UI/UX layer.
- **Generation 3 (Unified)**: Flutter's cross-platform capabilities enabled consolidation of desktop and mobile codebases into a single framework, replacing the Tauri implementation. WearOS and tvOS platforms remain outside Flutter's current support scope.

This evolution resulted in a unified codebase supporting Desktop, Android, and iOS, with improved feature parity and reduced maintenance overhead.

### Project Name

_Diapason_ derives from the French term for tuning fork, metaphorically representing the project's objective: a canonical reference point for your entire music library, consistently synchronized across all devices.

## What Diapason Can Do And How It Compares To Finamp ?

| **Category** | **Diapason** | **Finamp** | **Notes** |
|---|---|---|---|
| **Library** | Jellyfin, Plex, Subsonic/Navidrome, local files | Jellyfin only | Diapason adds multi-server support |
| **Albums/Artists/Playlists** | ✓ Search, offline downloads with transcoding | ✓ Search, offline downloads with transcoding | Both fully supported |
| **Dynamic Playlists** | Rule-based filtering (genre, BPM, rating, format, etc.) | N/A | Diapason exclusive feature |
| **Playback Features** | Gapless, replay gain, volume normalisation, transcoding | Gapless, replay gain, volume normalisation, transcoding | Feature parity |
| **Remote Control** | Android Auto, CarPlay, MPRIS (Linux), SMTC (Windows) | Android Auto, CarPlay | Diapason adds Linux/Windows support |
| **Queue & History** | Queue management, playback history | Queue management, playback history | Both supported |
| **Lyrics** | Synced + plain lyrics, LRCLIB fallback | Synced lyrics | Diapason auto-fills gaps via LRCLIB |
| **Scrobbling** | Last.fm, ListenBrainz scrobbling | Last.fm only | Diapason adds ListenBrainz |
| **Discovery** | Last.fm/ListenBrainz discovery & playlist import, YouTube fallback | Last.fm discovery | Diapason adds ListenBrainz, playlist import, YouTube fallback |
| **UI Features** | Spectrum visualizer, fullscreen player, animated artwork | Standard UI | Diapason visual enhancements |
| **Updates** | Auto-updater via GitHub Releases | Manual updates | Diapason streamlines updates |
| **Diapason Connect** | mDNS discovery, remote-control on LAN | N/A | Diapason exclusive feature |
| **Platforms** | Desktop (Windows, Linux, macOS), Android, iOS, Android TV, WearOS | Mobile only (Android, iOS) | Diapason adds full desktop support |

## Building

```bash
git clone https://github.com/Nytuo/diapason.git
cd diapason
flutter pub get
dart run build_runner build --delete-conflicting-outputs
flutter run
```

### Building for tvOS

tvOS is outside stock Flutter's supported platforms, so building it requires
[flutter-tvos](https://fluttertv.dev), a Flutter SDK fork/embedder that adds
tvOS as a first-class target, alongside the standard Flutter SDK for
everything else.

```bash
# one-time: install the flutter-tvos toolchain
git clone https://github.com/fluttertv/flutter-tvos.git
export PATH="$PATH:$PWD/flutter-tvos/bin"
flutter-tvos precache
flutter-tvos doctor

# in the diapason repo
flutter-tvos pub get
python3 tvos/scripts/restore_tvos_plugins.py  # re-injects the tvos-only plugins
                                               # into .flutter-plugins-dependencies
                                               # (flutter pub get drops them)
flutter-tvos run -d <tvos-device-or-simulator-id>
```

Run `restore_tvos_plugins.py` before every `pod install` / `flutter-tvos
build`/`run`, since any regular `flutter` command regenerates
`.flutter-plugins-dependencies` without the tvos key. If native files under
`tvos/Runner/Playback` change, re-run `tvos/scripts/wire_tvos_player.rb` to
wire them into `Runner.xcodeproj`.

#### tvOS status

The app boots, logs in, and plays audio. Isar (used elsewhere for downloads,
playback stats, pinned shortcuts, and search history) has no tvOS native
binary, so tvOS stores just the current user and media source configs in
Hive instead (see `FinampUserHelper` and `MediaSourceService`'s tvOS
branches) and those four Isar-only features stay unavailable there.

`just_audio` / `audio_service` also have no tvOS implementation, so actual
playback runs through `AppleTvAudioChannel` (native AVPlayer +
`MPNowPlayingInfoCenter`) instead, driven from `MusicPlayerBackgroundTask`'s
tvOS-specific fields and `_setupTvOSPlayback()`. `_player` (just_audio) is
kept permanently idle there - never actually played - and reused purely as
the existing queue data structure (`sequenceState`, shuffle, repeat) that
`QueueService` already depends on; only real playback (load/play/pause/
seek/position/duration/Now Playing) is re-routed to the native channel. This
covers the core experience but intentionally has no equivalent of the other
platforms' crossfade, gapless preload, equalizer, or replay gain/volume
normalization - those are just_audio-effect-specific and stay unavailable on
tvOS for now. It's been verified end-to-end against the native AVPlayer
bridge itself (a public test file streamed, reported the correct duration,
and advanced position in real time); the full queue integration hasn't been
exercised against a real Jellyfin/Subsonic/Plex server yet, so treat it as
functional-but-freshly-wired if you hit an edge case.

## Credits

Diapason is a fork of [Finamp](https://github.com/finamp-app/finamp) by `jmshrv` and the Finamp contributors, used under the Mozilla Public License 2.0. The groundwork: the player, queue engine,
download subsystem, Android Auto and CarPlay integrations, is theirs. I just add my little touch over it and a full desktop implementation.

## Authors & contributors

Finamp base was created by `jmshrv` and the Finamp contributors.

Diapason in this fork is maintained by
[Arnaud BEUX (Nytuo)](https://github.com/Nytuo).

For a full list of contributors, see the
[contributors page](https://github.com/Nytuo/Diapason/contributors).

## License

Diapason is licensed under the **Mozilla Public License 2.0**, the same licence as the forked Finamp project. See [LICENSE](LICENSE).

## More from the Diapason familly

[Diapason Uploader](https://github.com/Nytuo/diapason-uploader) is a sidecar for your server for uploading music to your servers. This is what is used by the uploader functionality to feed your music server with the music you retrieve (like from YouTube).

[Diapason Apple](https://github.com/Nytuo/diapason_apple) The home of the Apple devices native implementation for Apple TV and Apple Watch.