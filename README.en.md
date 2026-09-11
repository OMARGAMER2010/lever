<div align="center">

# Lever

**Open Windows `.exe` files, unpack `.rar` archives, install Android `.apk`s, run your Steam and
console games, and turn some of them into native Mac apps.**
No accounts, no server, no telemetry. All local.

[Español](README.md)

</div>

> **The name.** A lever is what you wedge into a stuck drawer to get it open — that's unpacking.
> And figuratively, leverage is the force that opens a door that was closed to you — that's what
> Wine does with an `.exe`. An ordinary word, nothing invented.

---

## What it does

| | |
|---|---|
| **Programs** | Runs Windows `.exe` and `.msi` files through Wine, in its own environment that doesn't touch anything else on your Mac. |
| **Native games** | Some `.exe` files are only a wrapper: in Godot the game lives in the `.pck` next to it, in Ren'Py it's Python scripts, in LÖVE it's glued to the end of the `.exe` itself. Those files work on a Mac too. Lever pairs them with the official macOS runtime and hands you a native `.app` — no Wine, no Rosetta. |
| **Steam games** | A Windows Steam library in its own environment, apart from the rest. You install from Steam like on any PC and your games show up in a list with a play button. Direct3D is translated to Metal with D3DMetal. |
| **Archives** | Extracts `.rar`, `.zip`, `.7z`, `.tar`, `.iso`, `.cab` and friends. Handles passwords and never deletes the original. |
| **Android** | Runs an `.apk` on the Mac itself, inside an emulator Lever sets up and starts for you. A phone over USB works too. And the formats that split an app into pieces — `.xapk`, `.apks`, `.aab` — get taken apart, the right pieces picked for your device, and installed together with their expansion files. |
| **Retro consoles** | Recognises a console game by its header, not its extension, and runs it with the libretro core it needs, downloaded for you. Eleven machines, from the NES to the PSP. Controls are mapped on a diagram shaped like whichever pad you have plugged in. |
| **Hybrid console** | `.nsp`, `.xci`, `.nsz` and `.xcz` packages get opened and read: which game is inside, which updates, which add-ons, with version and size. No libretro core emulates that console, so you bring the emulator; Lever finds it and launches it. Compressed packages are rebuilt before playing. |
| **PlayStation family** | PS2, PS3, PS4 and Vita, each with its own emulator. Lever reads the `PARAM.SFO` inside — which ships unencrypted — to tell you the real title, the version, and whether that thing is the game, a patch or a DLC. It goes into disc images, `.pkg` and `.vpk` files, and accepts the game **folder**, which is how PS3 and PS4 games come. |

Drag a file onto the window — or onto the app's Dock icon — and Lever lands on the right tab by
itself. "Open with" from Finder works too.

Whatever you opened before stays in **Recently opened**, with its icon and size, so you don't have
to go looking for it again. Spanish and English, with the flag picker in the top right.

## Install

One command, and it walks you through:

```bash
curl -fsSL https://raw.githubusercontent.com/OMARGAMER2010/lever/main/scripts/bootstrap.sh | bash
```

Five screens: it checks your Mac can build it, shows what's missing with sizes and how much space
that needs, builds, and leaves `Lever.app` on your Desktop. No screen does anything without you
saying yes, and you can stop at any point.

If you'd rather read what you're about to run before running it — which is the sensible thing —
clone it and run exactly the same by hand:

```bash
git clone https://github.com/OMARGAMER2010/lever.git
cd lever
bash scripts/install.sh
```

Piece by piece, if you'd rather:

```bash
bash scripts/dependencies.sh                   # the list with sizes, then it asks
bash scripts/dependencies.sh --check           # just look, touch nothing
bash scripts/dependencies.sh --all             # everything missing, no questions
bash scripts/dependencies.sh --only wine,zstd  # only those pieces
bash scripts/build-app.sh                      # build and assemble the .app
open dist/Lever.app
```

### What it asks, and why

It shows every piece with its size, adds up what it's about to download and compares that against
your free space, leaving 2 GB of headroom — filling a disk completely leaves the Mac unusable, not
just the install. Then you choose: everything, a few, or nothing.

It looks in the same directories the app looks in, not your terminal's `PATH` — which isn't what an
app launched from Finder inherits — so it won't tell you something is ready when the app won't find
it.

Sizes are approximate and rounded up, because Homebrew doesn't say how big something is until it's
already downloading it. And if you run it from a script, with no terminal in front of it, it only
reports: nobody can answer a question nobody reads.

The app opens fine without all of it, and tells you what's missing when it needs it.

## How to use it

Drag the file onto the window and that's it. The rest is in case you want to know what to expect.

**A Windows program.** Drop the `.exe` or `.msi` and hit **Run**. The first time, Wine sets up its
environment and takes a moment; after that it doesn't.

**A game that could run native.** If the `.exe` turns out to be just a wrapper — Godot, Ren'Py,
LÖVE, NW.js, Electron, Java — a button shows up to build a Mac `.app`. You pick where it goes, and
that `.app` needs neither Wine nor Rosetta.

**Steam games.** Under Programs, **Open Windows Steam** opens your library; you install from there
like on any PC. Installed games appear in the list with a **Play** button that opens them through
Steam. If one gets stuck on its own launcher and goes no further, **⋯ → Pick the executable** lets
you say which file actually starts it, and Lever remembers.

**An archive.** Drop it, choose where it goes, hit **Extract**. There's a box for the password if it
asks for one. The original is never touched.

**An `.apk`.** Plug in a phone over USB, or let Lever set up the emulator. Hit **Run** and it does
the whole chain: starts what it needs, waits, installs, opens the app. `.xapk`, `.apks` and `.aab`
come apart on their own and install in pieces.

**A retro console game.** Drop the ROM. Lever recognises the machine from the file's header, not its
extension, downloads the core it needs and opens it. Controls are set on a diagram shaped like
whichever pad you have plugged in.

**The hybrid console and the PlayStation family.** These don't come with an emulator: you bring the
program and Lever finds it and launches it. The keys and firmware are yours too — Lever reads them,
it doesn't hand them out.

## Requirements

macOS 13 or newer. Swift 6 to build it. Everything else is optional and Lever tells you when it
needs something: Homebrew installs most of it, and `scripts/dependencies.sh` walks you through it.

On Apple silicon, Wine needs Rosetta 2. Emulators, firmware and keys are not included — you bring
your own.

## What to expect

**Wine** is not Windows. Programs that need drivers, anti-cheat or advanced graphics will fail.
Installers and simple utilities are what work best. If a program won't start, that's the limit of
the compatibility layer, not a bug in Lever.

**Steam.** Direct3D is translated to Metal with D3DMetal, and how well that goes depends on the game
and on your Mac, so try it before getting your hopes up. Games with online anti-cheat won't work,
and nothing here can fix that.

**Consoles.** libretro cores download themselves. Machines that need BIOS or firmware will say so,
and that file is yours to provide: Lever doesn't ship it and won't go looking for it.

**Android.** The emulator is real Android running on arm64, native on your chip. 2D games and normal
apps are fine; heavy 3D games and anything with anti-cheat will struggle or not start. Installing
outside Google Play skips its checks, so only use files from a source you trust.

## Development

```bash
swift run LeverTests    # full suite, including real extraction tests
swift build
```

The tests are their own executable with hand-written assertions: the Command Line Tools on this
machine don't ship XCTest. Integration tests skip themselves when the extractors aren't installed.

```
Sources/
  LeverCore/    Logic: locating tools, building commands, launching processes
  Lever/        SwiftUI interface
scripts/
  build-app.sh      Builds and assembles the .app
  dependencies.sh   Checks and installs what's missing
  install.sh        The above, plus a copy to the Desktop
```

> ⚠️ In `scripts/build-app.sh`, the build happens **before** asking for the binary's path.
> `swift build --show-bin-path` only prints the path — it doesn't build. Using it as the only step
> put a stale binary in the `.app` and the window came up empty.
