<h1 align="center">
  <img src="images/diapason.png" alt="Diapason" width="auto" height="160">
</h1>

<div align="center">
<h2>Diapason Flutter</h2>
Diapason Android and iOS music player - Jellyfin, Plex, Subsonic/Navidrome and local files, in one library
<br />
<br />
<a href="https://github.com/Nytuo/diapason-flutter/issues/new?labels=bug&title=bug%3A+">Report a Bug</a>
·
<a href="https://github.com/Nytuo/diapason-flutter/issues/new?labels=enhancement&title=feat%3A+">Request a Feature</a>
</div>

---

## About

Diapason Flutter is a music player for Android, iOS, Android TV and WearOS (Android Watch).

It is a fork of [Finamp](https://github.com/finamp-app/finamp), an open-source Jellyfin music
client, extended with the rest of the Diapason ecosystem's feature set.

## Features

**Library**
- Jellyfin, Plex and Subsonic / Navidrome servers - several of each, aggregated into one library
- Local file library
- Albums, artists, genres, playlists, search
- Offline downloads with transcoding profiles

**Playback**
- Gapless playback, replay gain / volume normalisation, transcoding
- Android Auto, CarPlay, MPRIS (Linux), SMTC (Windows)
- Queue management and playback history

**Lyrics**
- Synced lyrics, with LRCLIB used to fill in (or upgrade) whatever the server can't provide

**Discovery & scrobbling**
- Last.fm and ListenBrainz scrobbling
- Discovery and playlist import from Last.fm / ListenBrainz, matched against your library,
  with a YouTube fallback for tracks you don't own

**Diapason Connect**
- mDNS discovery of other Diapason instances on the LAN
- Remote-control another device, or act as a playback receiver

## Building

```bash
git clone https://github.com/Nytuo/diapason-flutter.git
cd diapason-flutter
flutter pub get
dart run build_runner build --delete-conflicting-outputs
flutter run
```

## Credits

Diapason is a fork of [Finamp](https://github.com/finamp-app/finamp) by `jmshrv` and the Finamp
contributors, used under the Mozilla Public License 2.0. The groundwork — the player, queue engine,
download subsystem, Android Auto and CarPlay integrations — is theirs. I just add my little touch over it.

## License

Diapason is licensed under the **Mozilla Public License 2.0**, the same licence as the upstream
Finamp project. See [LICENSE](LICENSE).

## More from the Diapason familly
[Diapason](https://github.com/Nytuo/Diapason) is a desktop application before the mobile application, make using Tauri (React + Rust) and support Windows / Linux / MacOS.

[Diapason Uploader](https://github.com/Nytuo/diapason-uploader) is a sidecar for your server for uploading music to your servers. This is what is used by the uploader functionality to feed your music server with the music you retrieve (like from YouTube).