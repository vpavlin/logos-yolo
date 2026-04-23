# Yolo

A censorship-resistant bulletin board that runs inside [Logos Basecamp](https://github.com/logos-co/logos-basecamp). Messages are inscribed on the Logos blockchain through a zone sequencer, image attachments live in Logos Storage (Codex), and per-message "troll-box" side-panel threads are ephemeral chats delivered over Waku via `logos-delivery-module`.

The repo is a monorepo with two Logos Core packages:

| Path      | Kind              | What it is                                                           |
|-----------|-------------------|----------------------------------------------------------------------|
| `module/` | `core` module     | `yolo_board_module` — backend: polling, cache, storage uploads, threads |
| `ui/`     | `ui_qml` plugin   | `yolo_board` — thin QML client that talks to the module over QRO IPC    |

Both are packaged as `.lgx` via nix, loaded into Basecamp via `lgpm`, and meant to be driven end-to-end with [`logos-scaffold basecamp`](https://github.com/logos-co/logos-scaffold).

## Architecture

```
┌────────────────────────────── Basecamp ──────────────────────────────┐
│                                                                      │
│   ui/yolo_board (QML)  ◀── QRO IPC ──▶  module/yolo_board_module (C++) │
│                                                      │               │
│                                       ┌──── QRO ────┼──── QRO ────┐  │
│                                       ▼             ▼             ▼  │
│                                 zone-sequencer   storage      delivery│
│                                 (on-chain)       (Codex)      (Waku)  │
└──────────────────────────────────────────────────────────────────────┘
```

See [`docs/architecture.md`](docs/architecture.md) for the code walkthrough, [`docs/inter-module-comm.md`](docs/inter-module-comm.md) for the QRO IPC gotchas collected while building the module, and [`docs/threads-howto.md`](docs/threads-howto.md) for the per-message-thread recipe.

## Quickstart

You need [Nix](https://nixos.org/) with flakes enabled and [`logos-scaffold`](https://github.com/logos-co/logos-scaffold) on `$PATH` (PR #75 or later — earlier versions lack `basecamp modules` and `doctor`).

```bash
git clone https://github.com/vpavlin/logos-yolo && cd logos-yolo

# First-time only: builds pinned basecamp + lgpm, seeds alice/bob profiles.
logos-scaffold basecamp setup

# Add [basecamp.dependencies] entries for deps scaffold can't resolve
# automatically (storage_module, zone-sequencer) — see scaffold.toml.example.
cat scaffold.toml.example >> scaffold.toml

# Auto-discover project sources (module/#lgx + ui/#lgx) and dependencies.
logos-scaffold basecamp modules

# Sanity-check captured set and manifest variants.
logos-scaffold basecamp doctor

# Build + install into both profiles, then launch alice.
logos-scaffold basecamp install
logos-scaffold basecamp launch alice
```

To run two instances side-by-side (useful for testing thread chat peer-to-peer):

```bash
logos-scaffold basecamp launch alice --no-clean &
logos-scaffold basecamp launch bob   --no-clean &
```

## What works today

- Publish text + image messages to your own zone channel
- Subscribe to other channels; paginated backfill of history
- Media attachments uploaded to Codex storage, cached locally, rendered inline
- Per-message ephemeral threads over Waku with delivered `✓` indicators
- Thread message persistence: close + reopen the panel (or restart the app) and history is preserved
- "My Threads" list of threads you've participated in

## CI status

Build workflows live in `.github/workflows/{build,release}.yml`. On push to `master` they matrix-build `module/#lgx` and `ui/#lgx` via `nix build`; on tag push matching `v*` they additionally attach both artifacts to a GitHub release.

The `module/` build currently **fails on clean CI runners** because `logos-storage-module`'s transitive dep `logos-storage-nim` has a NAR hash mismatch on a submodule-bearing git input — upstream issue, not reproducible from our flake.lock alone. Local builds succeed because the nix store already contains a cached derivation. Unblock when upstream fixes the lockfile or publishes a binary cache. The `ui/` build runs green.

## Known sharp edges

- `set_node_url` on zone-sequencer takes ~20 s cold-start even after our init reorder (zone-sequencer-side QRO source registration — file upstream).
- `storage_module.init()` also takes ~80 s cold-start; parallel with delivery so no wall-clock impact.
- Thread-reply payload carries `nick` in cleartext with no signature (spoofable); Ed25519 signing is planned.
- No AppImage build yet — requires `#lgx-portable` flake outputs on both packages.

## Development

```bash
# Rebuild one package, install, relaunch alice:
( cd module && nix build .#lgx ) && logos-scaffold basecamp install \
  && logos-scaffold basecamp launch alice

# Per-step diag log of the running module is at /tmp/yolo_board_module.diag.
tail -f /tmp/yolo_board_module.diag
```

## Related repos

- [`logos-co/logos-basecamp`](https://github.com/logos-co/logos-basecamp) — host application (QML shell + `logos_host` child processes)
- [`logos-co/logos-scaffold`](https://github.com/logos-co/logos-scaffold) — `basecamp` dev-loop tooling; PR #75 reshape
- [`logos-co/logos-delivery-module`](https://github.com/logos-co/logos-delivery-module) — Waku pub/sub used for threads
- [`logos-co/logos-storage-module`](https://github.com/logos-co/logos-storage-module) — Codex storage used for attachments
- [`jimmy-claw/logos-zone-sequencer-module`](https://github.com/jimmy-claw/logos-zone-sequencer-module) — on-chain inscription sequencer
