# Flatpak packaging

`fr.nytuo.diapason.yml` packages Diapason as a Flatpak.

## How it builds

Flutter has no Flatpak SDK extension, and `flutter pub get` needs network access
that flatpak-builder denies inside the sandbox. So the manifest does **not**
compile Flutter: CI runs

```sh
flutter build linux --release
```

first, stages the resulting bundle plus the desktop entry, icon and metainfo into
`flatpak/staging/`, and the `diapason` module simply installs that tree. See the
`build-flatpak` job in `.github/workflows/build.yml`.

## The mpv problem

`media_kit` does not bundle libmpv — `media_kit_libs_linux` declares no bundled
libraries and the player `dlopen()`s `libmpv.so` at runtime. The freedesktop
runtime doesn't ship it either, so the manifest builds mpv (plus libass and
uchardet) as modules, with `org.freedesktop.Platform.ffmpeg-full` supplying the
codecs.

**Status: this module chain is unverified.** mpv 0.38 additionally requires
`libplacebo >= 6.338`, which the 24.08 runtime may not provide. If the build
fails resolving libplacebo, add it as a module ahead of mpv:

```yaml
  - name: libplacebo
    buildsystem: meson
    config-opts: [-Ddemos=false]
    sources:
      - type: git
        url: https://code.videolan.org/videolan/libplacebo.git
        tag: v7.349.0
```

Pin a real commit/tag and let flatpak-builder report the expected checksum rather
than guessing one.

## Building locally

```sh
flutter build linux --release
mkdir -p flatpak/staging && cp -r build/linux/x64/release/bundle flatpak/staging/
sed -e '/^dnl/d' -e 's|__INSTALL_PATH__|/app/bin|g' \
  assets/diapason.desktop.m4 > flatpak/staging/fr.nytuo.diapason.desktop
cp assets/fr.nytuo.diapason.metainfo.xml flatpak/staging/
cp assets/icon/linux/256x256/apps/diapason.png flatpak/staging/

flatpak install -y flathub org.freedesktop.Platform//24.08 org.freedesktop.Sdk//24.08
flatpak-builder --force-clean --user --install build-dir flatpak/fr.nytuo.diapason.yml
flatpak run fr.nytuo.diapason
```

## Flathub

Publishing to Flathub is a **manual, separate process** and is not automated by
this repo's CI: you submit this manifest as a pull request to
[flathub/flathub](https://github.com/flathub/flathub), it gets reviewed, and
Flathub's own buildbot builds and hosts it from a repo they create. The CI job
here only produces a local `.flatpak` bundle artifact for testing.

Before submitting, Flathub requires:

- the app id to match the manifest filename and the `<id>` in the metainfo,
- `appstream-util validate` to pass on the metainfo,
- a stable `<releases>` entry matching the released version,
- no network access at build time (already the case here).
