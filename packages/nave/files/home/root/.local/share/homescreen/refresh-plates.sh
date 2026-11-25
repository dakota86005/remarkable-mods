#!/bin/sh
# Rebuilds plates.json from the PNG/JPG files in the Nave plates folder.
# Caption: first line of <name>.txt if present, else the file name
# ("prickly_pear.png" -> "Prickly pear"). BusyBox-safe.
D=/home/root/.local/share/homescreen/plates
[ -n "$1" ] && D="$1"
cd "$D" || { echo "no folder $D"; exit 1; }
out=plates.json.tmp
printf '{"plates":[' > "$out"
first=1
n=0
for f in *.png *.jpg; do
    [ -f "$f" ] || continue
    base=${f%.*}
    if [ -f "$base.txt" ]; then
        cap=$(sed -n '1p' "$base.txt")
    else
        cap=$(echo "$base" | sed 's/[-_]/ /g' | awk '{ print toupper(substr($0,1,1)) substr($0,2) }')
    fi
    cap=$(printf '%s' "$cap" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\r')
    [ $first -eq 1 ] || printf ',' >> "$out"
    printf '{"file":"%s","caption":"%s"}' "$f" "$cap" >> "$out"
    first=0
    n=$((n + 1))
done
printf ']}\n' >> "$out"
mv "$out" plates.json
echo "plates.json: $n plates"
