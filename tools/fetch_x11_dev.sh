#!/bin/sh
# Get what raylib needs to build on X11 without root: the Debian -dev packages'
# headers, unpacked into $1, plus lib/ link names pointing at the runtime
# libraries already installed on the system.
# Not needed if these are installed system-wide:
#   sudo apt install libx11-dev libxrandr-dev libxinerama-dev libxcursor-dev libxi-dev libgl-dev
set -eu
dest=$1
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

(cd "$tmp" && apt-get download \
    libx11-dev x11proto-dev libxrandr-dev libxinerama-dev libxi-dev libxcursor-dev \
    libxrender-dev libxext-dev libxfixes-dev libgl-dev libxcb1-dev libxau-dev libxdmcp-dev)

rm -rf "$dest"
mkdir -p "$dest/lib"
for deb in "$tmp"/*.deb; do dpkg-deb -x "$deb" "$dest/root"; done

multiarch=$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || echo x86_64-linux-gnu)
for lib in X11 Xrandr Xinerama Xi Xcursor GL; do
    runtime=$(ls /usr/lib/"$multiarch"/lib"$lib".so.[0-9]* 2>/dev/null | sort -V | head -1)
    [ -n "$runtime" ] || { echo "missing runtime library lib$lib" >&2; exit 1; }
    ln -sf "$runtime" "$dest/lib/lib$lib.so"
done
echo "X11 development files ready in $dest"
