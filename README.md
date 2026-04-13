# Unforeseen Achievements

Bypasses the achievement guard in Half-Life 2, its episodes, and other Source engine games so that Steam achievements unlock normally during developer commentary playthroughs.

## How it works

Source engine games block achievements during commentary playthroughs. The check that matters is in `server.dll`, which gates the entire achievement pipeline (event processing, criteria evaluation, and award) across three call sites.

This DLL scans the server module at runtime, locates the commentary check helper (anchored on the `"Achievements disabled"` debug string), and stubs it to always return true. No other guards are touched (sv_cheats, multiplayer checks etc. remain intact).

Loads automatically via a `version.dll` proxy in the game's `bin` directory.

## Supported games

Tested on the HL2 20th Anniversary edition. Should work on other Source 1 titles that share the same achievement architecture:

- Half-Life 2, Episode One, Episode Two, Lost Coast (20th Anniversary)
- Portal
- Portal 2
- Left 4 Dead
- Left 4 Dead 2

Currently, only Windows is supported and tested, but Linux support via `LD_PRELOAD` should be straightforward to add.

## Install

```powershell
irm https://raw.githubusercontent.com/MarcedForLife/unforeseen/main/install.ps1 | iex
```

Or manually: copy the DLL as `version.dll` into the game's `bin` directory:

| Game                      | Copy to                          |
| ------------------------- | -------------------------------- |
| Half-Life 2 (20th Anniv.) | `Half-Life 2\bin\version.dll`    |
| Portal                    | `Portal\bin\version.dll`         |
| Portal 2                  | `Portal 2\bin\version.dll`       |
| Left 4 Dead               | `Left 4 Dead\bin\version.dll`    |
| Left 4 Dead 2             | `Left 4 Dead 2\bin\version.dll`  |

To uninstall, delete `version.dll` from that directory.

## Building

Requires the 32-bit MSVC target (`rustup target add i686-pc-windows-msvc`):

```sh
cargo build --release
```

## Pattern maintenance

The scanner locates the patch site at runtime using the `"Achievements disabled"` debug string in `server.dll` as an anchor, then resolves the `E8` call target to find the commentary check function entry point.

If a game update breaks the scan, check `%TEMP%\unforeseen.log` for timestamped errors and patch offsets, then use a disassembler to verify the patterns in `scanner.rs`.
