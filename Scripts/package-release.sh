#!/bin/bash
set -euo pipefail
# Package an already-built, already-signed binary. No implicit signing or network.
products=${1:?Usage: package-release.sh PRODUCTS ARCH OUTPUT_DIRECTORY}
architecture=${2:?Expected arm64 or x86_64}
output=${3:?Expected output directory}
case "$architecture" in
  arm64) triple=aarch64-apple-darwin ;;
  x86_64) triple=x86_64-apple-darwin ;;
  *) echo "Unsupported architecture: $architecture" >&2; exit 1 ;;
esac
version=$(python3 Scripts/version.py)
test -x "$products/tatara"
lipo "$products/tatara" -verify_arch "$architecture"
if otool -arch "$architecture" -L "$products/tatara" | tail -n +2 | rg -v '^\s*(/usr/lib/|/System/Library/)' ; then
  echo 'Unexpected non-system dynamic dependency in tatara.' >&2
  exit 1
fi
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/bin" "$stage/share/tatara" "$output"
case "$(lipo -archs "$products/tatara")" in
  *' '*) lipo "$products/tatara" -thin "$architecture" -output "$stage/bin/tatara" ;;
  *) cp "$products/tatara" "$stage/bin/tatara" ;;
esac
cp LICENSE THIRD_PARTY_NOTICES.md "$stage/share/tatara/"
cp -R LICENSES "$stage/share/tatara/"
printf 'https://github.com/PangMo5/Tatara/tree/v%s\n' "$version" > "$stage/share/tatara/SOURCE.txt"
cp README.md CONTRIBUTING.md LICENSE THIRD_PARTY_NOTICES.md "$stage/"
cp -R docs "$stage/docs"
tar -C "$stage" -czf "$output/tatara-$version-$triple.tar.gz" .
