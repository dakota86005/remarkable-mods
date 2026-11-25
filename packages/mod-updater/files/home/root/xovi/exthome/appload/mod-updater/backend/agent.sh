#!/bin/sh
# Mods app helper. backend/entry runs it for the app; it also works by hand:
#   sh agent.sh snapshot | refresh | job add nave@dakota | jobpoll
# BusyBox only. Changes (install, upgrade, remove) run as their own systemd unit,
# so they finish even if the reMarkable UI restarts in the middle.

VROOT=${MU_VELLUM_ROOT:-/home/root/.vellum}
DATA=${MU_DATA:-/home/root/.local/share/mod-updater}
VELLUM=${MU_VELLUM:-$VROOT/bin/vellum}
RESTART_FLAG=${MU_RESTART_FLAG:-/tmp/.dakota-mods-restart}
JOB=$DATA/job
IDX=$DATA/index
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
TAB=$(printf '\t')
export HOME=${HOME:-/home/root}
export PATH="${MU_PATH:-$VROOT/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH}"
mkdir -p "$JOB" "$IDX"

arch() {
	case "${MU_ARCH:-$(uname -m)}" in
		aarch64|arm64) echo aarch64 ;;
		armv7*) echo armv7 ;;
		*) uname -m ;;
	esac
}

# "tag url" per configured repository ("-" when it has no @tag)
repos() {
	[ -f "$VROOT/etc/apk/repositories" ] || return 0
	# the file may lack a final newline, which `read` would drop
	{ cat "$VROOT/etc/apk/repositories"; echo; } | while read -r a b _; do
		case "$a" in
			""|\#*) ;;
			@*) [ -n "$b" ] && echo "${a#@} $b" ;;
			*) echo "- $a" ;;
		esac
	done
}

key_of() { printf '%s' "$1" | md5sum | cut -c1-12; }

# apk's own cached copy of a repo index, if it kept one
apk_cache() {
	h=$(printf '%s' "$1" | sha1sum | cut -c1-8)
	for d in "$VROOT/etc/apk/cache" "$VROOT/var/cache/apk"; do
		[ -s "$d/APKINDEX.$h.tar.gz" ] && { echo "$d/APKINDEX.$h.tar.gz"; return 0; }
	done
	return 1
}

# P/V/T/U/D blocks of an APKINDEX or installed db -> one tab line each
blocks() {
	awk -v T="$TAB" -v PRE="$1" '
		function flush() { if (p != "") print PRE T p T v T t T d T u; p = v = t = d = u = "" }
		/^$/ { flush(); next }
		{ k = substr($0, 1, 2); x = substr($0, 3); gsub(/\t/, " ", x)
		  if (k == "P:") p = x; else if (k == "V:") v = x; else if (k == "T:") t = x
		  else if (k == "D:") d = x; else if (k == "U:") u = x }
		END { flush() }' "$2"
}

snapshot() {
	if [ -x "$VELLUM" ]; then echo "HAVE${TAB}vellum"; else echo "HAVE${TAB}none"; fi
	echo "ARCH${TAB}$(arch)"
	repos | while read -r tag url; do
		k=$(key_of "$url")
		printf 'REPO\t%s\t%s\t%s\n' "$tag" "$url" "$(head -c 200 "$IDX/$k.desc" 2>/dev/null | tr '\t\n' '  ')"
		[ -s "$IDX/$k.idx" ] && blocks "A$TAB$url" "$IDX/$k.idx"
	done
	[ -f "$VROOT/lib/apk/db/installed" ] && blocks I "$VROOT/lib/apk/db/installed"
	[ -f "$VROOT/etc/apk/world" ] && awk -v T="$TAB" 'NF { print "W" T $1 }' "$VROOT/etc/apk/world"
	[ -f "$IDX/stamp" ] && echo "CHECKED${TAB}$(cat "$IDX/stamp")"
	echo "NOW${TAB}$(date +%s)"
	jobstate
}

refresh() {
	[ -x "$VELLUM" ] || { echo "Vellum is not installed on this tablet."; return 3; }
	echo "Fetching package lists"
	"$VELLUM" update </dev/null 2>&1
	urc=$?
	ar=$(arch)
	fails=0
	for line in $(repos | tr ' ' '|'); do
		url=${line#*|}
		case "$url" in http://*|https://*) ;; *) continue ;; esac
		k=$(key_of "$url")
		tmp="$IDX/$k.tmp"
		rm -f "$tmp"
		src=$(apk_cache "$url") && cp "$src" "$tmp"
		[ -s "$tmp" ] || wget -q -T 25 -O "$tmp" "$url/$ar/APKINDEX.tar.gz" 2>/dev/null
		if [ -s "$tmp" ] && tar -xzOf "$tmp" APKINDEX > "$IDX/$k.new" 2>/dev/null && [ -s "$IDX/$k.new" ]; then
			mv "$IDX/$k.new" "$IDX/$k.idx"
			tar -xzOf "$tmp" DESCRIPTION > "$IDX/$k.desc" 2>/dev/null || rm -f "$IDX/$k.desc"
			echo "$url" > "$IDX/$k.url"
		else
			rm -f "$IDX/$k.new"
			echo "Couldn't read the list from $url"
			fails=$((fails + 1))
		fi
		rm -f "$tmp"
	done
	date +%s > "$IDX/stamp"
	[ "$urc" = 0 ] || return 4
	[ "$fails" = 0 ] || return 5
	return 0
}

valid() {
	case "$1" in
		""|-*|*[!A-Za-z0-9._+@-]*) return 1 ;;
	esac
	return 0
}

alive() {
	[ -s "$JOB/pid" ] && kill -0 "$(cat "$JOB/pid")" 2>/dev/null
}

busy() {
	alive && return 0
	# a job handed to systemd a moment ago may not have written its pid yet
	if [ -f "$JOB/state" ]; then
		IFS="$TAB" read -r st id _ < "$JOB/state"
		[ "$st" = queued ] && [ $(( $(date +%s) - id )) -lt 20 ] && return 0
	fi
	return 1
}

job() {
	action=$1
	[ $# -gt 0 ] && shift
	case "$action" in
		add|del|purge) [ $# -gt 0 ] || { echo "Nothing to do."; return 2; } ;;
		upgrade) ;;
		*) echo "Unknown action: $action"; return 2 ;;
	esac
	for p in "$@"; do valid "$p" || { echo "Not a package name: $p"; return 2; }; done
	busy && { echo "Another change is still running."; return 75; }
	id=$(date +%s)
	printf '%s\n' "$action" "$@" > "$JOB/cmd"
	: > "$JOB/log"
	rm -f "$JOB/pid" "$JOB/seen"
	printf 'queued\t%s\t%s\t%s\n' "$id" "$action" "$*" > "$JOB/state"
	if command -v systemd-run >/dev/null 2>&1 && [ -z "$MU_NO_SYSTEMD" ] &&
	   systemd-run --quiet --collect --unit="mod-updater-$id" -p KillMode=process \
	       --setenv=HOME=/home/root /bin/sh "$SELF" run-job "$id" >> "$JOB/log" 2>&1; then
		:
	elif command -v setsid >/dev/null 2>&1; then
		setsid /bin/sh "$SELF" run-job "$id" </dev/null >/dev/null 2>&1 &
	else
		nohup /bin/sh "$SELF" run-job "$id" </dev/null >/dev/null 2>&1 &
	fi
	echo "started $id"
}

run_job() {
	id=$1
	echo $$ > "$JOB/pid"
	action=$(head -n 1 "$JOB/cmd")
	pkgs=$(tail -n +2 "$JOB/cmd" | tr '\n' ' ')
	pkgs=${pkgs% }
	start=$(date +%s)
	printf 'running\t%s\t%s\t%s\t%s\n' "$id" "$action" "$pkgs" "$start" > "$JOB/state"
	echo "\$ vellum $action $pkgs" >> "$JOB/log"
	case "$action" in
		upgrade) "$VELLUM" upgrade -y $pkgs ;;
		add) "$VELLUM" add $pkgs ;;
		del) "$VELLUM" del $pkgs ;;
		purge) "$VELLUM" purge $pkgs ;;
	esac </dev/null >> "$JOB/log" 2>&1
	rc=$?
	restart=0
	# set by a mod's install script when the UI is about to restart
	[ -n "$(find "$RESTART_FLAG" -newer "$JOB/cmd" 2>/dev/null)" ] && restart=1
	printf 'done\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$action" "$pkgs" "$rc" "$(date +%s)" "$restart" > "$JOB/state.new"
	mv "$JOB/state.new" "$JOB/state"
	rm -f "$JOB/pid"
	# let a mod's pending UI restart run before this unit goes away
	[ "$restart" = 1 ] && sleep 8
	return 0
}

jobstate() {
	[ -f "$JOB/state" ] || return 0
	printf 'JOB\t%s\n' "$(head -n 1 "$JOB/state")"
	if alive; then echo "ALIVE${TAB}1"; else echo "ALIVE${TAB}0"; fi
	[ -f "$JOB/seen" ] && echo "SEEN${TAB}1"
	return 0
}

jobpoll() {
	echo "NOW${TAB}$(date +%s)"
	jobstate
	echo "@@LOG"
	[ -f "$JOB/log" ] && tail -c 12000 "$JOB/log"
}

cmd=$1
[ $# -gt 0 ] && shift
case "$cmd" in
	snapshot) snapshot ;;
	refresh) refresh ;;
	job) job "$@" ;;
	run-job) run_job "$@" ;;
	jobpoll) jobpoll ;;
	ack) touch "$JOB/seen" ;;
	ping) echo pong ;;
	*) echo "usage: agent.sh snapshot|refresh|job <add|del|purge|upgrade> [pkg...]|jobpoll|ack"; exit 2 ;;
esac
