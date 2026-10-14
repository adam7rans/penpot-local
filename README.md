# penpot-local

Full Penpot (2.18.3) running natively on macOS — **no Docker, no account,
no sign-up or login screens, no email, no cloud**. Everything stays on
your machine (local Postgres + local files), so it works offline after
setup. Plus optional **Figma-style vector modifiers** for the pen/path
tools.

## What you get

- Penpot Desktop connects to a **Local (offline)** instance at
  `http://localhost:9001`.
- A background helper starts the backend only while Penpot is open and
  stops it ~30s after you quit. Only nginx + valkey (a few MB) idle
  in between.
- One built-in local account; nginx signs its requests in with a
  long-lived token, so you never see registration or login.
  Telemetry, SMTP/email verification, and Google Fonts are off.
- All ports listen on localhost only: `9001` web, `6060` backend,
  `6061` exporter, `6390` cache (plus your Postgres on `5432`).

## Figma-style vector editing

Vector-edit modifiers that match Figma (off by default; see
`scripts/rebuild-frontend.sh` to compile them in):

| Gesture | Result |
| ------- | ------ |
| Hover anchor + hold Cmd | Arrow + mirror badge |
| Cmd-click anchor | Toggle sharp corner / smooth curve |
| Cmd-drag from sharp anchor | Handles grow out mirrored, equal rate |
| Cmd-drag on handled anchor | Collapses to center, pulls a fresh mirrored pair |
| Cmd-drag handle | Moves mirrored |
| Hover handle + hold Option | V (break) cursor |
| Option-drag handle | Breaks symmetry, moves independently |
| Shift-drag | 45° constraint (unchanged) |

Without the rebuild you still get the modifier **cursors** (tiny
`js/figma-cursors.js` overlay, no compiled changes) on top of stock
behavior — stock already breaks handles with Option-drag and toggles
corners with Cmd-click in node-edit mode.

Known nuances: undoing a mirror-drag restores the un-pulled curve, not
the sharp corner; single-handle open endpoints pull their lone handle.

## Requirements

- macOS (Apple Silicon paths below; Intel works with adjusted Homebrew paths)
- Homebrew packages: `postgresql@15`, `openjdk` (27), `node`, `valkey`,
  `nginx`. Install with `HOMEBREW_NO_AUTO_UPDATE=1` to avoid surprise
  upgrades breaking other apps.
- Google Chrome (used by the exporter), git, curl, python3.
- Penpot Desktop.

## Install

```sh
git clone https://github.com/<you>/penpot-local.git
cd penpot-local
scripts/setup.sh
```

`setup.sh` downloads `crane` (a static binary, no Homebrew involvement),
pulls the official `penpotapp/*:2.18.3` images, extracts the app files,
patches the exporter to localhost + your Chrome, renders all configs,
creates the database, then walks you through a one-time local signup and
mints the auto-login token. End state mirrors this layout:

- `bin/penpot-local` — `start|stop|restart|status|logs`, plus `watch`
  (run by launchd; see `launchd/`).
- `conf/` — `penpot.env`, nginx/valkey configs, `starting.html`;
  secrets (`secret`, `session-token`, `nginx-auth.conf`, `local-account`)
  are generated locally and **never committed** (see `.gitignore`).
- `patches/` — `figma-pen-modifiers.patch` (compiled behaviors) and
  `figma-cursors.js` (cursor overlay).

Then open Penpot Desktop and pick the Local instance.

## Everyday use

```sh
bin/penpot-local start|stop|restart|status|logs   # manual control
```

Back up `data/assets` plus a database dump:

```sh
pg_dump -h localhost -U penpot penpot > backup.sql
```

## Updating Penpot

Bump `PENPOT_VERSION` at the top of `scripts/setup.sh`, re-fetch the
images, and re-apply the two exporter tweaks (localhost listen +
`channel:"chrome"`) and, if you use it, the Figma patch via
`scripts/rebuild-frontend.sh`.

Gotcha that bit us: the compiled JS embeds a version tag that must
**exactly equal** the `penpotVersionTag` in `index.html`, or the app
force-reloads in a loop and Desktop shows a blank screen. Keep them in
sync; use the `?version=` query strings only for cache-busting.

## License

Mozilla Public License 2.0 (see `LICENSE`). Penpot itself is
© Kaleidos INC Sucursal en España SL; local scripts, configs, and
patches in this repo are released under the same license.
