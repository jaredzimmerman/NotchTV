#!/bin/bash
# Builds build/python: a relocatable CPython (python-build-standalone, via uv) with the
# helper's pinned dependencies, trimmed to what the helper needs. build.sh copies it into
# NotchTV.app/Contents/Resources/python, so the app runs with no Python on the user's Mac.
#
# Rebuilt only when helper/requirements.txt or this script changes.
set -euo pipefail
cd "$(dirname "$0")/.."

PY_VERSION=3.13
OUT=build/python
STAMP="$OUT/.bundle-stamp"
WANT="$(cat helper/requirements.txt scripts/bundle-python.sh | shasum -a 256 | cut -d' ' -f1)"

if [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$WANT" ]; then
  echo "bundled python up to date"
  exit 0
fi

uv python install "$PY_VERSION" >/dev/null
SRC="$(uv python find --managed-python "$PY_VERSION")"
PREFIX="$("$SRC" -c 'import sys; print(sys.prefix)')"
STDLIB="lib/python$PY_VERSION"

rm -rf "$OUT"
mkdir -p "$OUT"
rsync -a \
  --exclude 'BUILD' --exclude 'include' --exclude 'share' \
  --exclude 'lib/pkgconfig' --exclude 'lib/tcl*' --exclude 'lib/tk*' --exclude 'lib/itcl*' \
  --exclude 'lib/thread*' --exclude 'lib/libtcl*' --exclude 'lib/libtk*' \
  --exclude "$STDLIB/test" --exclude "$STDLIB/idlelib" --exclude "$STDLIB/tkinter" \
  --exclude "$STDLIB/turtledemo" --exclude "$STDLIB/turtle.py" --exclude "$STDLIB/ensurepip" \
  --exclude "$STDLIB/lib2to3" --exclude "$STDLIB/pydoc_data" --exclude "$STDLIB/config-*" \
  --exclude "$STDLIB/lib-dynload/_tkinter*" --exclude "$STDLIB/site-packages/*" \
  --exclude '__pycache__' \
  "$PREFIX/" "$OUT/"

rm -f "$OUT/$STDLIB/EXTERNALLY-MANAGED"
uv pip install --quiet --python "$OUT/bin/python$PY_VERSION" --break-system-packages \
  --no-deps -r helper/requirements.txt

# Only the interpreter is needed in bin/ (console scripts carry this machine's paths).
find "$OUT/bin" -mindepth 1 ! -name "python$PY_VERSION" -delete
ln -s "python$PY_VERSION" "$OUT/bin/python3"

SITE="$OUT/$STDLIB/site-packages"
# Tests, caches and type stubs are dead weight in a signed bundle.
find "$SITE" -type d \( -name tests -o -name test -o -name __pycache__ \) -prune -exec rm -rf {} +
find "$SITE" -name '*.pyi' -delete

# Licenses of everything bundled, for the app's Resources and the release.
{
  echo "NotchTV bundles the following third-party software."
  echo
  echo "================================================================"
  echo "Python $("$OUT/bin/python3" -c 'import platform; print(platform.python_version())') (python-build-standalone)"
  echo "================================================================"
  cat "$OUT/$STDLIB/LICENSE.txt" 2>/dev/null || true
  for dist in "$SITE"/*.dist-info; do
    name="$(basename "$dist" .dist-info)"
    echo
    echo "================================================================"
    echo "$name"
    echo "================================================================"
    find "$dist" \( -iname 'LICEN[CS]E*' -o -iname 'COPYING*' -o -iname 'NOTICE*' \) -type f \
      -exec cat {} \; 2>/dev/null
    grep -E '^License(-Expression)?:' "$dist/METADATA" 2>/dev/null || true
  done
} > build/ThirdPartyLicenses.txt

# Precompile with unchecked hashes: valid whatever the files' mtimes become after copying,
# and the helper runs with -B so it never writes into the signed bundle.
"$OUT/bin/python3" -m compileall -q -j 0 --invalidation-mode unchecked-hash "$OUT/lib" >/dev/null || true

# Smoke test: everything the helper imports.
"$OUT/bin/python3" -I -B -c 'import pyatv, pyatv.storage.file_storage, srptools, cryptography; print("bundled python ok, pyatv", pyatv.const.__version__)'

echo "$WANT" > "$STAMP"
du -sh "$OUT"
