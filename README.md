# remarkable-mods

Dakota's personal mods for the reMarkable Paper Pro (firmware 3.29), packaged as
a small [Vellum](https://github.com/vellum-dev/vellum)-compatible apk repository.
They install, update and uninstall through Vellum, so they show up in reManager's
**Installed** and **Updates** lists next to the official mods.

This is a personal repository. It is not part of the official Vellum package index.

| Package | Version | What it does |
|---|---|---|
| `nave` | 3.1.0 | Two-column home screen for My files, with a folder aisle, Continue, progress bars and a random watercolor plate |
| `field-weather` | 4.0.0 | Current weather in the home screen header |
| `note-links` | 2.0.0 | Links and spot tags between notebook pages, with backlinks and a links graph |
| `hide-home-logo` | 2.0.0 | Hides the reMarkable wordmark in the home header |
| `system-info` | 1.0.0 | System panel in the home menu |
| `up-next` | 1.0.0 | Your next calendar event in the home header, from an .ics link, with a saved copy for offline |
| `mod-updater` | 1.0.0 | **Mods**, an AppLoad app to browse, install, update and remove mods on the tablet (this repo and the official Vellum repo) |
| `sudoku` | 1.2.0 | Sudoku app for AppLoad: puzzles made on the tablet, handwriting read on the device |

The home screen and notebook mods depend on `qt-resource-rebuilder` from the official Vellum repo, and are limited to
`remarkable-os>=3.29 <3.30`. After an install, upgrade or removal, the reMarkable UI restarts once by itself.

`sudoku` is different: it is an AppLoad app, not a patch, so it needs AppLoad, is not tied to a firmware version,
and is not part of `setup.sh`. Install it with `vellum add sudoku@dakota`, then open AppLoad and tap **Reload**.
No restart happens on install. `vellum purge sudoku` also deletes the saved puzzle.

## One-time setup on the tablet

1. In reManager, open **Settings › Connection** and turn **Download through reManager** off.
   reManager's download mode only fetches from the official server, so updates to these mods
   would fail with it on. Your tablet then downloads over its own Wi-Fi.
2. Open reManager's terminal (or SSH into the tablet) and run:

   ```sh
   wget -qO- https://dakota86005.github.io/remarkable-mods/setup.sh | sh
   ```

   This adds the repo and its signing key to Vellum, then installs all five mods.
   Mods you had copied in by hand are replaced by the packaged copies in the same place.
   Use `sh setup.sh --repo-only` to add the repo without installing anything.

From then on:
- **Update:** reManager › Updates, like any other mod.
- **Remove:** reManager › Installed › the mod › Uninstall (or `vellum del nave`).
  `vellum purge <mod>` also removes the mod's saved data (weather reading, Nave progress choices,
  System info settings, the noteLinks index). Links stored inside your notebooks are never removed.
- **Add one later:** `vellum add <name>@dakota`.

These mods don't appear on reManager's Discover or Search pages, which show only the official catalog.

The `@dakota` tag pins them to this repo, so an official package with the same name can't replace them.

## Mods app (no terminal needed after this)

Install it once from reManager's terminal, then open AppLoad, tap **Reload** and tap **Mods**:

```sh
vellum add mod-updater@dakota
```

- **Installed** lists everything Vellum installed, with the ones that have updates first. *Update all* runs `vellum upgrade`.
- **Discover** lists every mod in this repo and in the official Vellum repo that isn't installed yet. Mods made for other
  reMarkable versions are hidden (tap *Show … for other versions* at the bottom to see them).
- Tap a mod for details, *Install*, *Update*, *Remove* or *Remove with data* (`vellum purge`).
- *Check now* runs `vellum update` and refreshes both lists. Mods checks by itself when the lists are more than 6 hours old.

Changes run as their own systemd unit, not inside the reMarkable UI, so when a mod restarts the UI after installing
(which closes Mods), the install still finishes. Open Mods again to see how it went. The app's source is in
`apps/mod-updater/` (`build.sh` rebuilds it into `packages/mod-updater/`).

## Up Next (calendar)

`up-next` puts the next event from one or more calendar feeds (.ics or webcal:// links) in the home header, to the
right of Field Weather. Tap it for its menu: the next few events, *Show in the header* (every day or weekdays only),
*Look ahead* (today, 3 days, a week), all-day events on or off, and the list of calendars. Add a link in the menu, or
append links, one per line, to `/home/root/.local/share/upnext/links.txt` (read and emptied the next time the menu
opens). The feed is read in a background thread and the next two months are saved in `cache.json`, so it keeps
showing your events without Wi-Fi. Links stay on the tablet. `vellum purge up-next` also deletes the saved links and copy.

## Undo the setup
```sh
vellum del nave field-weather note-links hide-home-logo system-info
sed -i '/dakota86005.github.io/d' /home/root/.vellum/etc/apk/repositories
rm /home/root/.vellum/etc/apk/keys/dakota-mods.rsa.pub
```

Reinstalling Vellum itself rewrites its repository list. If that happens, run the setup command again.

## Releasing a new version (maintainer)

1. Replace the file under `packages/<name>/files/...` and bump `pkgver` in `packages/<name>/pkg.json`
   (or `pkgrel` for a packaging-only change).
2. `python3 build_repo.py --key /path/to/dakota-mods.rsa` signs the packages and the index into `docs/aarch64/`.
3. `python3 verify_repo.py` checks signatures, checksums and scripts.
4. Commit and push. GitHub Pages serves `docs/`.

The private signing key is never committed (`*.rsa` is in `.gitignore`).
`build_repo.py` needs Python 3 and the `cryptography` package and nothing else.
