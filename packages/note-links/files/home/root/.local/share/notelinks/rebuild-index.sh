#!/bin/sh
# Rebuilds /home/root/.local/share/notelinks/index.json from every notebook's
# notelinks.rm sidecar (for links synced from elsewhere, or a lost index).
# xochitl keeps the index in memory, so this restarts it afterwards.
XO=/home/root/.local/share/remarkable/xochitl
OUT=/home/root/.local/share/notelinks/index.json
TMP="$OUT.tmp"
mkdir -p /home/root/.local/share/notelinks
printf '{"v":1,"docs":{' > "$TMP"
first=1
count=0
for f in "$XO"/*/notelinks.rm; do
    [ -f "$f" ] || continue
    id=$(basename "$(dirname "$f")")
    [ -f "$XO/$id.metadata" ] || continue
    name=$(sed -n 's/.*"visibleName": *"\([^"]*\)".*/\1/p' "$XO/$id.metadata" | sed -n '1p')
    body=$(dd if="$f" bs=51 skip=1 2>/dev/null)
    case "$body" in
        "{"*) ;;
        *) continue ;;
    esac
    [ "$first" = 1 ] || printf ',' >> "$TMP"
    first=0
    printf '"%s":{"name":"%s",%s' "$id" "$name" "${body#\{}" >> "$TMP"
    count=$((count + 1))
done
printf '}}' >> "$TMP"
mv "$TMP" "$OUT"
echo "Indexed $count notebook(s). Restarting xochitl..."
/home/root/xovi/start
