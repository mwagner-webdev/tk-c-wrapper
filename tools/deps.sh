#!/bin/sh
# Fetch, verify and build a pinned Tcl/Tk release into deps/<version>/.
#
# Usage: tools/deps.sh [VERSION]        (default: 9.1.0)
#
# This is the only non-Tcl build helper: it has to run before any tclsh
# exists.  It downloads the release tarballs from SourceForge (the official
# Tcl/Tk download location), checks their SHA-256 against the pins below,
# and builds shared libraries into deps/<version>/install.
#
# Build configuration (recorded in docs/DESIGN.md):
#   Tcl: --enable-shared
#   Tk:  --enable-shared --disable-xft --disable-bidi
#        (Xft/HarfBuzz development headers are not required; core X fonts
#         are used.  This does not change any widget option table.)
set -eu

VERSION="${1:-9.1.0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DL="$ROOT/deps/dl"
BASE="$ROOT/deps/$VERSION"

case "$VERSION" in
  9.1.0)
    TCL_SHA256=ba11ae7035ec4b0caf2c489b20d5aa2abb1cf001a7e65b0fa2fbac86908c643b
    TK_SHA256=772ce7a97c07c2db4c957c93af7ab4dff4bd3037772836b6afbcd0974023b3d6 ;;
  9.0.4)
    TCL_SHA256=5d265f3499b588681825d8093177830707b7035ad866b17189a3a6ab6dade0ff
    TK_SHA256=d7a146d2917eb8b5cc95276dbf0e3d03c7464d2b19c1675357857c989301dbb4 ;;
  *) echo "deps.sh: no pinned checksums for version $VERSION" >&2; exit 2 ;;
esac

TCL_TGZ="tcl-core$VERSION-src.tar.gz"
TK_TGZ="tk$VERSION-src.tar.gz"
URL="https://downloads.sourceforge.net/project/tcl/Tcl/$VERSION"

mkdir -p "$DL"
fetch() {
  if [ ! -f "$DL/$1" ]; then
    echo "deps.sh: downloading $1"
    curl -fsSL --retry 4 -o "$DL/$1.part" "$URL/$1"
    mv "$DL/$1.part" "$DL/$1"
  fi
  echo "$2  $DL/$1" | sha256sum -c - >/dev/null || {
    echo "deps.sh: checksum mismatch for $1" >&2; exit 1; }
}
fetch "$TCL_TGZ" "$TCL_SHA256"
fetch "$TK_TGZ" "$TK_SHA256"

if [ -x "$BASE/install/bin/tclsh${VERSION%.*}" ] && [ -f "$BASE/install/lib/tkConfig.sh" ]; then
  echo "deps.sh: Tcl/Tk $VERSION already installed in $BASE/install"
  exit 0
fi

rm -rf "$BASE/src" "$BASE/build"
mkdir -p "$BASE/src" "$BASE/build/tcl" "$BASE/build/tk"
tar -C "$BASE/src" -xzf "$DL/$TCL_TGZ"
tar -C "$BASE/src" -xzf "$DL/$TK_TGZ"

JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)"
( cd "$BASE/build/tcl" &&
  "$BASE/src/tcl$VERSION/unix/configure" --prefix="$BASE/install" --enable-shared >configure.log 2>&1 &&
  make -j"$JOBS" >make.log 2>&1 && make install >install.log 2>&1 ) || {
  echo "deps.sh: Tcl build failed, see $BASE/build/tcl/*.log" >&2; exit 1; }
( cd "$BASE/build/tk" &&
  "$BASE/src/tk$VERSION/unix/configure" --prefix="$BASE/install" \
     --with-tcl="$BASE/build/tcl" --enable-shared --disable-xft --disable-bidi >configure.log 2>&1 &&
  make -j"$JOBS" >make.log 2>&1 && make install >install.log 2>&1 ) || {
  echo "deps.sh: Tk build failed, see $BASE/build/tk/*.log" >&2; exit 1; }
echo "deps.sh: Tcl/Tk $VERSION installed in $BASE/install"
