#!/bin/bash
# Builds the Mods AppLoad app into ../../packages/mod-updater/files/... (and dist/ for hand installs).
# Needs: aarch64-linux-gnu-gcc (static build of the backend bridge) and Qt's rcc (PySide6 ships one).
set -euo pipefail
cd "$(dirname "$0")"
RCC="${RCC:-$(python3 -c 'import PySide6,os; print(os.path.join(os.path.dirname(PySide6.__file__),"Qt","libexec","rcc"))')}"
CC="${CC:-aarch64-linux-gnu-gcc}"
OUT=dist/mod-updater
rm -rf dist && mkdir -p "$OUT/backend"
{ echo '<RCC><qresource prefix="/">'; find ui -type f | sort | sed 's#.*#<file>&</file>#'; echo '</qresource></RCC>'; } > application.qrc
"$RCC" --binary --no-compress -o "$OUT/resources.rcc" application.qrc
rm application.qrc
"$CC" -O2 -static -s -Wall -Wextra -o "$OUT/backend/entry" backend/bridge.c
cp backend/agent.sh "$OUT/backend/agent.sh"
chmod 755 "$OUT/backend/entry" "$OUT/backend/agent.sh"
cp manifest.json icon.png "$OUT/"
PKG=../../packages/mod-updater/files/home/root/xovi/exthome/appload/mod-updater
rm -rf "$PKG" && mkdir -p "$(dirname "$PKG")" && cp -r "$OUT" "$PKG"
ls -la "$OUT" "$OUT/backend"
