# Vendored packages

Third-party packages that Diapason patches. They live here (as `path:`
dependencies in the root `pubspec.yaml`) instead of in forks on GitHub, so a
change to them is a normal commit in this repository.

Small patches inside upstream files are marked with a `Diapason:` comment;
larger additions (SpectrumTap, the tvOS build) live in their own files.

## just_audio, just_audio_platform_interface

Upstream: [ryanheise/just_audio](https://github.com/ryanheise/just_audio),
`minor` branch at `6dfdd07` (just_audio 0.10.6, platform interface 4.6.0).
Imported from the former `Nytuo/just_audio_fork` repository.

Diapason changes, all on Apple platforms (`just_audio/darwin`):

- `SpectrumTap`: an `MTAudioProcessingTap` with a vDSP FFT that feeds the
  player-screen visualizer, plus the in-app 10-band equalizer (vDSP biquads).
  The platform interface gains the matching equalizer request/response.
- tvOS build (`just_audio/tvos`, its `Classes` is a symlink to the Darwin
  sources).
- `UriAudioSource.m`: `AVURLAssetPreferPreciseDurationAndTimingKey` defaults
  to YES. Without it AVFoundation seeks FLAC by a bitrate estimate and keeps
  playing far past the end of the track.
- `LockCachingAudioSource` is no longer marked `@experimental`.

`just_audio_platform_interface` is also pinned through `dependency_overrides`,
because `just_audio_media_kit` depends on the pub.dev release.

To pull a newer upstream release: diff upstream's `just_audio/` and
`just_audio_platform_interface/` against the `minor@6dfdd07` baseline, apply that
diff here, and keep the `Diapason:` changes.

## isar_community_generator

Upstream: [isar-community](https://github.com/isar-community/isar-community)
`isar_community_generator` 3.4.1 (dev dependency only).

Diapason change (`lib/src/helper.dart`): `@Name`, `@Enumerated` and
`@Backlink` are read from the annotated getter/setter (`nonSynthetic`), not
only from the synthetic field. Upstream drops them for getter/setter pairs,
which would rename `FinampUser.currentViewId` in the database schema and lose
that column on upgrade. Worth reporting upstream; drop the copy once fixed.
