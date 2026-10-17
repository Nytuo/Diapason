# Flatpak packaging

`fr.nytuo.diapason.yml` is the manifest published on Flathub.

## How it builds

Flutter has no Flatpak SDK extension and `flutter pub get` needs network access
that Flathub builds do not have. Like Finamp on Flathub, the manifest therefore
packages the Linux bundle attached to each GitHub release
(`diapason-<version>_linux_{x64,aarch64}.tar.gz`) instead of compiling Flutter.

`media_kit` does not bundle libmpv — the player `dlopen()`s `libmpv.so` at
runtime — so libmpv is built from source with its required libass and
libplacebo. Optional mpv features (Lua, JavaScript, rubberband, uchardet) are
disabled since Diapason only uses libmpv for audio.

## Building locally

```sh
flatpak install flathub org.freedesktop.Platform//25.08 org.freedesktop.Sdk//25.08
flatpak-builder --force-clean --user --install build-dir flatpak/fr.nytuo.diapason.yml
flatpak run fr.nytuo.diapason
```

This builds the release pinned in the manifest. To test the current code, build
the bundle first and point the manifest at it, as the `build-flatpak` job of
`.github/workflows/release.yml` does (it replaces the `# BUNDLE-BEGIN` /
`# BUNDLE-END` block with `type: dir`, `path: staging/bundle`).

## Publishing to Flathub

`flathub_sync.py` repoints the tarball, LICENSE and icon URLs at a release and
recomputes their checksums.

- **Updates** — `.github/workflows/flathub-publish.yml` runs when a GitHub
  Release is published and opens a pull request on
  [flathub/fr.nytuo.diapason](https://github.com/flathub/fr.nytuo.diapason).
  Flathub test-builds the PR; merge it to publish. Needs the `FLATHUB_TOKEN`
  secret (classic PAT, `public_repo` scope, from a maintainer of that repo).
  The Linux tarballs must be attached to the release before it is published.
- **Initial submission** — until Flathub accepts the app, that repo does not
  exist and the workflow only uploads the `flathub-files` artifact. Those files
  go in a branch of your fork of [flathub/flathub](https://github.com/flathub/flathub)
  based on `new-pr`, submitted as a pull request against `new-pr`.
