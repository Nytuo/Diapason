#!/usr/bin/env python3
"""Build the file set for the Flathub repo for a Diapason release.

Repoints the release tarball URLs (both architectures) and the LICENSE/icon
URLs of the manifest at the given tag and commit, recomputing the checksum of
every URL that changed. The desktop entry and metainfo are copied alongside,
and the release is added to the metainfo if it is not listed yet.

    flathub_sync.py --tag v0.12.0 --version 0.12.0 --commit <sha> --out flathub-out
"""
import argparse
import datetime
import hashlib
import pathlib
import re
import shutil
import urllib.request

HERE = pathlib.Path(__file__).resolve().parent
APP_ID = "fr.nytuo.diapason"
REPO = "Nytuo/Diapason"


def sha256_of(url):
    digest = hashlib.sha256()
    with urllib.request.urlopen(url) as response:
        for chunk in iter(lambda: response.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--tag", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--date", default=datetime.date.today().isoformat())
    parser.add_argument("--out", required=True, type=pathlib.Path)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)

    def repoint(match):
        url, indent, sha = match.groups()
        new_url = re.sub(
            r"/releases/download/[^/]+/diapason-[^/_]+_linux_",
            f"/releases/download/{args.tag}/diapason-{args.version}_linux_",
            url,
        )
        new_url = re.sub(
            rf"raw\.githubusercontent\.com/{REPO}/[0-9a-f]{{40}}/",
            f"raw.githubusercontent.com/{REPO}/{args.commit}/",
            new_url,
        )
        if new_url != url:
            sha = sha256_of(new_url)
        return f"url: {new_url}\n{indent}sha256: {sha}"

    manifest = (HERE / f"{APP_ID}.yml").read_text()
    manifest = re.sub(r"url: (\S+)\n([ \t]+)sha256: ([0-9a-f]{64})", repoint, manifest)
    (args.out / f"{APP_ID}.yml").write_text(manifest)

    shutil.copy2(HERE / f"{APP_ID}.desktop", args.out / f"{APP_ID}.desktop")

    metainfo = (HERE / f"{APP_ID}.metainfo.xml").read_text()
    if f'<release version="{args.version}"' not in metainfo:
        metainfo = re.sub(
            r"^([ \t]*)<releases>\n",
            lambda m: f'{m.group(0)}{m.group(1)}  <release version="{args.version}" date="{args.date}"/>\n',
            metainfo,
            count=1,
            flags=re.M,
        )
    (args.out / f"{APP_ID}.metainfo.xml").write_text(metainfo)


if __name__ == "__main__":
    main()
