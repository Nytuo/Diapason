#!/usr/bin/env bash
#
# Builds Linux distribution packages (deb, rpm, AppImage) from an already-built
# Flutter Linux release bundle. Run `flutter build linux --release` first.
#
# Usage: linux/packaging/build-packages.sh [version]
#
# Note on mpv: media_kit does not bundle libmpv (media_kit_libs_linux declares no
# bundled libraries) — it dlopen()s the system copy at runtime. So the native
# packages declare it as a runtime dependency, and the AppImage has to ship it
# explicitly, since a dlopen'd library is invisible to linuxdeploy's dependency
# scan.
set -euo pipefail

APP_ID="fr.nytuo.diapason"
BINARY="diapason"
MAINTAINER="Nytuo <nne66vse2@mozmail.com>"
HOMEPAGE="https://github.com/Nytuo/diapason"
DESCRIPTION="A multi-source music player for Jellyfin, Plex, Subsonic/Navidrome and local files"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

VERSION="${1:-$(grep '^version:' pubspec.yaml | sed 's/version:[[:space:]]*//' | cut -d+ -f1)}"

# FLUTTER_ARCH: the flutter build output dir. DEB_ARCH/RPM_ARCH: the arch label
# each packager expects. ASSET_ARCH: the token used in our published file names
# (see the appname-version_os_arch.ext scheme).
case "$(uname -m)" in
  x86_64)  FLUTTER_ARCH="x64";   DEB_ARCH="amd64";   RPM_ARCH="x86_64";   ASSET_ARCH="x64" ;;
  aarch64) FLUTTER_ARCH="arm64"; DEB_ARCH="arm64";   RPM_ARCH="aarch64";  ASSET_ARCH="aarch64" ;;
  *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

BUNDLE="build/linux/${FLUTTER_ARCH}/release/bundle"
[ -d "$BUNDLE" ] || { echo "No bundle at $BUNDLE — run 'flutter build linux --release' first." >&2; exit 1; }

OUT="build/linux/packages"
STAGING="build/linux/staging"
rm -rf "$STAGING" "$OUT"
mkdir -p "$OUT"

echo "==> Staging install tree for $BINARY $VERSION ($DEB_ARCH)"

# Standard layout: private libdir for the bundle, symlink on PATH.
install -d "$STAGING/usr/lib/$BINARY"
cp -r "$BUNDLE"/. "$STAGING/usr/lib/$BINARY/"
install -d "$STAGING/usr/bin"
ln -sf "../lib/$BINARY/$BINARY" "$STAGING/usr/bin/$BINARY"

# The desktop entry is a template; strip the m4 comment and point Exec at the
# symlink we just made.
install -d "$STAGING/usr/share/applications"
sed -e '/^dnl/d' -e "s|__INSTALL_PATH__|/usr/bin|g" \
  assets/diapason.desktop.m4 > "$STAGING/usr/share/applications/${APP_ID}.desktop"

# Pre-generated XDG icons.
for icon in assets/icon/linux/*/apps/${BINARY}.png; do
  size="$(basename "$(dirname "$(dirname "$icon")")")"
  install -Dm644 "$icon" "$STAGING/usr/share/icons/hicolor/$size/apps/${BINARY}.png"
done

install -Dm644 "assets/${APP_ID}.metainfo.xml" "$STAGING/usr/share/metainfo/${APP_ID}.metainfo.xml"

common_fpm_args=(
  -s dir
  -C "$STAGING"
  -n "$BINARY"
  -v "$VERSION"
  --license "MPL-2.0"
  --vendor "Nytuo"
  --maintainer "$MAINTAINER"
  --url "$HOMEPAGE"
  --description "$DESCRIPTION"
  --force
)

echo "==> Building .deb"
fpm "${common_fpm_args[@]}" \
  -t deb \
  -a "$DEB_ARCH" \
  -p "$OUT/${BINARY}-${VERSION}_linux_${ASSET_ARCH}.deb" \
  --depends "libmpv2 | libmpv1" \
  --depends "libgtk-3-0" \
  --deb-no-default-config-files \
  usr

echo "==> Building .rpm"
fpm "${common_fpm_args[@]}" \
  -t rpm \
  -a "$RPM_ARCH" \
  -p "$OUT/${BINARY}-${VERSION}_linux_${ASSET_ARCH}.rpm" \
  --depends "mpv-libs" \
  --depends "gtk3" \
  usr

echo "==> Building AppImage"
APPDIR="build/linux/AppDir"
rm -rf "$APPDIR"
# linuxdeploy resolves the desktop file's Exec entry to a real file under
# usr/bin, so the bundle is copied there directly instead of reusing the
# staging tree, where usr/bin/diapason is only a symlink into usr/lib.
install -d "$APPDIR/usr/bin"
cp -r "$BUNDLE"/. "$APPDIR/usr/bin/"
install -d "$APPDIR/usr/share"
cp -r "$STAGING/usr/share/." "$APPDIR/usr/share/"

# AppRun resolves the binary relative to the AppDir, so the Exec entry must be a
# bare name rather than the /usr/bin path the deb/rpm entry uses.
sed -e '/^dnl/d' -e "s|__INSTALL_PATH__/||g" \
  assets/diapason.desktop.m4 > "$APPDIR/usr/share/applications/${APP_ID}.desktop"

# linuxdeploy matches the desktop file's Exec entry against executables it was
# explicitly given with -e, not against whatever happens to sit in the AppDir,
# so the binary has to be named here even though it is already in place.
#
# It also only follows linked libraries, so name dlopen'd libmpv explicitly.
MPV_LIB="$(ldconfig -p | awk '/libmpv\.so/ {print $NF; exit}')"
deploy_args=(--appdir "$APPDIR" -e "$APPDIR/usr/bin/${BINARY}" -d "$APPDIR/usr/share/applications/${APP_ID}.desktop" -i "assets/icon/linux/256x256/apps/${BINARY}.png")
if [ -n "$MPV_LIB" ]; then
  deploy_args+=(-l "$MPV_LIB")
else
  echo "WARNING: libmpv not found; the AppImage will not be able to play audio." >&2
fi

export APPIMAGE_EXTRACT_AND_RUN=1 # CI runners have no FUSE
export VERSION
export OUTPUT="$OUT/${BINARY}-${VERSION}_linux_${ASSET_ARCH}.AppImage"
./linuxdeploy.AppImage "${deploy_args[@]}" --output appimage

echo "==> Done:"
ls -lh "$OUT"
