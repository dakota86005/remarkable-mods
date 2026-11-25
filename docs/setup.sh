#!/bin/sh
# Adds Dakota's mod repo to Vellum on this reMarkable and installs the mods.
# Run on the tablet (reManager terminal or SSH):
#   wget -qO- https://dakota86005.github.io/remarkable-mods/setup.sh | sh
# Options:  sh setup.sh --repo-only   (add the repo, install nothing)
# Safe to run again. BusyBox-only.
set -e
REPO=https://dakota86005.github.io/remarkable-mods
TAG=@dakota
MODS="nave field-weather note-links hide-home-logo system-info"
V=/home/root/.vellum
VELLUM=$V/bin/vellum
[ -x "$VELLUM" ] || { echo "Vellum is not installed. Install it from reManager first."; exit 1; }

# Pinned signing key (only packages signed with it are accepted from this repo).
cat > "$V/etc/apk/keys/dakota-mods.rsa.pub" <<'KEY'
-----BEGIN PUBLIC KEY-----
MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAt+L9YzwI2raAoK1DtEZ6
wtBdxdqOzlqQvVlsST02KWUybwG2YhXMYP2F6/g80/vD11eEZTV/nJ39Mkvdn/aN
vig44DyVS9wYuRIrVgBtuT72tvhfZ7BrDHQXCQ/3fF1C+mnmvldIXiZIkk/gbZRC
yv3jr9hSAmo84CGY3XVNSkVg4DiVimgTnfW5/ugodpJ/42R642vWyqteE58NdS+Z
+enrbn1xTGEXiQtI5cZhBi2xen14yaEGPYfPG4k2mlp7fJ/DowE19Ss9piZhX1xc
d+xbcTD/VwiMKpqzSsR+p63aNqoVrzrPGFoxU3nTsi8hTJn+HSeIZyJ5WLskYcTK
6bJPsm7VHHRDU8+4LLfT1ENHN6xKv6RfiNY9CkMhSIp+Jcl6oFVBVx8nqiWKTUBJ
cYmDsAFfqX8aLqgIFN6f2jN4z+i7eyD8tpZY7sfjaIqG+Ko/gyVga35/0jVLte5r
LiYIwEIHdmbc8GmNP6/HTu7I97XEJ7es2WBJf0pq7/lW/5awM87EWLVKlbVJgbWP
igcVr3T3UB1bhYoyCY7jxZzquwSMq5rXMR6h1kHNGIYTYWEzp2+rPH1C68kYzI5p
WHCEG9paavVoiFkxD+uqPMtsYfmqFWgBEsh6zm/QdJFOrsF/MDfJYQ0YKt74ftbp
pEgPJzRBXgnqQ+4B3a1EpUkCAwEAAQ==
-----END PUBLIC KEY-----
KEY

RF=$V/etc/apk/repositories
if ! grep -q "$REPO" "$RF"; then
	# vellum may leave the file without a final newline
	[ -s "$RF" ] && [ -n "$(tail -c1 "$RF")" ] && echo >> "$RF"
	echo "$TAG $REPO" >> "$RF"
	echo "Added $REPO to $RF"
fi

"$VELLUM" update
[ "$1" = "--repo-only" ] && { echo "Repo added. Install with: vellum add nave$TAG ..."; exit 0; }

ARGS=""
for m in $MODS; do ARGS="$ARGS $m$TAG"; done
"$VELLUM" add $ARGS
echo "Done. The reMarkable UI restarts in a few seconds."
