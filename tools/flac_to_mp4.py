#!/usr/bin/env python3
"""Remux FLAC files into MP4 so iOS can seek them.

AVFoundation mis-seeks raw FLAC: it starts decoding tens of seconds away from
the position it was asked for, while reporting the requested position. The same
audio in an MP4 seeks correctly, because MP4 carries a sample table instead of
making the decoder guess. This is a remux, not a transcode -- the FLAC bitstream
is copied verbatim, so the audio is bit-identical (verified against the source
file's own STREAMINFO MD5).

ffmpeg alone is not enough: its mp4 muxer silently drops the embedded cover, and
its `use_metadata_tags` flag writes tags as freeform atoms that taglib (and so
Navidrome) cannot read. So tags and cover are rewritten afterwards with mutagen.

Usage:
    python3 flac_to_mp4.py /path/to/library --dry-run
    python3 flac_to_mp4.py /path/to/library
    python3 flac_to_mp4.py /path/to/library --replace   # delete the .flac after
"""

import argparse
import subprocess
import sys
from pathlib import Path

from mutagen.flac import FLAC
from mutagen.mp4 import MP4, MP4Cover, MP4FreeForm

# Vorbis comment -> iTunes freeform atom. These are the tags ffmpeg does not map
# to a standard MP4 atom but that Navidrome still reads, under the names below.
FREEFORM = {
    "musicbrainz_trackid": "MusicBrainz Release Track Id",
    "musicbrainz_releasetrackid": "MusicBrainz Release Track Id",
    "musicbrainz_albumid": "MusicBrainz Album Id",
    "musicbrainz_artistid": "MusicBrainz Artist Id",
    "musicbrainz_albumartistid": "MusicBrainz Album Artist Id",
    "musicbrainz_releasegroupid": "MusicBrainz Release Group Id",
    "acoustid_id": "Acoustid Id",
    "replaygain_track_gain": "replaygain_track_gain",
    "replaygain_track_peak": "replaygain_track_peak",
    "replaygain_album_gain": "replaygain_album_gain",
    "replaygain_album_peak": "replaygain_album_peak",
    "label": "LABEL",
    "isrc": "ISRC",
    "barcode": "BARCODE",
    "catalognumber": "CATALOGNUMBER",
}

IMAGE_ATOM = {"image/png": MP4Cover.FORMAT_PNG}


def audio_md5(path: Path) -> str:
    """MD5 of the decoded audio -- the check that the remux lost nothing."""
    out = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", str(path), "-map", "0:a", "-f", "md5", "-"],
        capture_output=True, text=True, check=True,
    )
    return out.stdout.strip().removeprefix("MD5=")


def first_int(value: str) -> int:
    """'13' or '13/15' or '2001;2001-09-11' -> leading integer, else 0."""
    digits = ""
    for ch in value.strip():
        if ch.isdigit():
            digits += ch
        else:
            break
    return int(digits) if digits else 0


def remux(src: Path, dst: Path) -> None:
    subprocess.run(
        [
            "ffmpeg", "-v", "error", "-i", str(src),
            "-map", "0:a", "-c", "copy",
            # faststart puts the sample table at the front, so a streaming
            # player has the index before it has the audio.
            "-movflags", "+faststart",
            # .m4a would select ffmpeg's `ipod` muxer, which rejects FLAC.
            "-f", "mp4", "-y", str(dst),
        ],
        check=True, capture_output=True,
    )


def retag(src: Path, dst: Path) -> None:
    """Restore what ffmpeg's mp4 muxer drops: cover, totals, freeform tags."""
    flac = FLAC(src)
    mp4 = MP4(dst)

    def one(name: str) -> str | None:
        values = flac.get(name)
        return values[0] if values else None

    # ffmpeg writes trkn/disk with a zero total; fill the totals back in.
    track = first_int(one("tracknumber") or "0")
    total_tracks = first_int(one("totaltracks") or one("tracktotal") or "0")
    if track:
        mp4["trkn"] = [(track, total_tracks)]
    disc = first_int(one("discnumber") or "0")
    total_discs = first_int(one("totaldiscs") or one("disctotal") or "0")
    if disc:
        mp4["disk"] = [(disc, total_discs)]

    for vorbis_key, atom_name in FREEFORM.items():
        value = one(vorbis_key)
        if value:
            mp4[f"----:com.apple.iTunes:{atom_name}"] = [
                MP4FreeForm(value.encode("utf-8"))
            ]

    if flac.pictures:
        picture = flac.pictures[0]
        mp4["covr"] = [
            MP4Cover(
                picture.data,
                imageformat=IMAGE_ATOM.get(picture.mime, MP4Cover.FORMAT_JPEG),
            )
        ]

    mp4.save()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("library", type=Path, help="directory to walk for .flac files")
    parser.add_argument("--dry-run", action="store_true", help="list what would be done")
    parser.add_argument("--replace", action="store_true", help="delete each .flac once its .m4a verifies")
    args = parser.parse_args()

    sources = sorted(args.library.rglob("*.flac"))
    if not sources:
        print(f"No .flac files under {args.library}")
        return 1

    print(f"{len(sources)} FLAC file(s) under {args.library}")
    converted = failed = skipped = 0

    for src in sources:
        dst = src.with_suffix(".m4a")
        if dst.exists():
            print(f"skip   {src.name} (.m4a already there)")
            skipped += 1
            continue
        if args.dry_run:
            print(f"would  {src.name} -> {dst.name}")
            continue

        try:
            remux(src, dst)
            retag(src, dst)
            # Bit-exactness is the whole promise of a remux. Prove it per file,
            # and never delete a source we could not prove was copied intact.
            if audio_md5(src) != audio_md5(dst):
                raise RuntimeError("audio differs from the source after remux")
        except Exception as error:  # noqa: BLE001 - report and keep going
            print(f"FAIL   {src.name}: {error}")
            dst.unlink(missing_ok=True)
            failed += 1
            continue

        if args.replace:
            src.unlink()
        converted += 1
        print(f"ok     {dst.name}")

    print(f"\nconverted {converted}, failed {failed}, skipped {skipped}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
