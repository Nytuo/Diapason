#!/bin/sh
# Packages each example plugin as dist/<folder>.zip and writes catalog.json with their checksums.
# A catalog is just this JSON file next to its zips, served over https (e.g. raw.githubusercontent.com).
set -eu
cd "$(dirname "$0")"
mkdir -p dist
entries=""
for dir in examples/*/; do
  name=$(basename "$dir")
  rm -f "dist/$name.zip"
  # Only what the app reads: the manifest and the entry (sources and build scripts stay out).
  (cd "$dir" && zip -q -X -j "../../dist/$name.zip" manifest.json $(ls handlers.json plugin.wasm 2>/dev/null))
  sha=$(shasum -a 256 "dist/$name.zip" | cut -d' ' -f1)
  entry=$(python3 -c '
import json, sys
m = json.load(open(sys.argv[1]))
print(json.dumps({
  "id": m["id"], "name": m["name"], "version": m["version"], "author": m["author"],
  "description": m.get("description", ""), "minAppVersion": m["minAppVersion"],
  "extensions": sorted({e["point"] for e in m["extensions"]}),
  "package": "dist/" + sys.argv[2] + ".zip", "sha256": sys.argv[3],
}, ensure_ascii=False, indent=4))' "$dir/manifest.json" "$name" "$sha")
  entries="${entries:+$entries,
}$entry"
done
printf '{\n  "version": 1,\n  "name": "Diapason examples",\n  "plugins": [\n%s\n  ]\n}\n' "$entries" > catalog.json
echo "wrote $(pwd)/catalog.json"
