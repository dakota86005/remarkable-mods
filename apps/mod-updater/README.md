# Mods (AppLoad app)

On-tablet front end for Vellum: browse, install, update and remove mods from every repository Vellum knows
(this repo as `@dakota`, and the official one).

| Path | What it is |
|---|---|
| `ui/main.qml`, `ui/logic.js` | The app. `logic.js` holds the snapshot parser, apk version rules, OS/device compatibility and the package model |
| `backend/bridge.c` | `backend/entry`: speaks AppLoad's socket protocol and runs `agent.sh <verb> <args>` (no shell parsing), streaming output back |
| `backend/agent.sh` | BusyBox script: `snapshot`, `refresh` (`vellum update` + reads each repo's APKINDEX), `job add/del/purge/upgrade`, `jobpoll`, `ack` |
| `harness/` | Offscreen test: fake tablet (`mkenv.py`, mock `vellum`, real index of this repo), the ARM backend under qemu, scenario scripts that tap and screenshot |
| `build.sh` | Builds `resources.rcc` and the static aarch64 backend into `packages/mod-updater/files/...` |

Messages: frontend sends type 1 `"<id>\n<verb>\n<arg>..."`; backend answers type 2 `"<id>\n<output>"` chunks and type 3 `"<id>\n<exit code>"`.

Jobs (`agent.sh job ...`) are started with `systemd-run --collect -p KillMode=process`, so they live outside xochitl's cgroup.
State is in `/home/root/.local/share/mod-updater/job/` (`state`, `log`, `pid`, `seen`), which is how the app shows the result of a
change that finished while it was closed (for example because a mod restarted the UI).

Test: `python3 harness/run.py harness/scenario_tour.py /tmp/out [path/to/vellum/packages]` (needs PySide6, busybox,
qemu-user-static and gcc-aarch64-linux-gnu for the full ARM run).
