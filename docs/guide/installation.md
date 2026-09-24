# Installation & Quickstart

OpenReliant is an open-source game engine recreation. It does not include copyrighted game data, so you must provide the game assets from a legally owned copy of StarLancer (CD-ROMs or disc images).

---

## Prerequisites

- **StarLancer game media**:
  - Retail CD-ROMs (Disc 1 and Disc 2), **or**
  - Disc image files (`.bin` or `.iso`), **or**
  - Extracted disc directory folders.
- **OpenReliant binary**:
  - Download the latest pre-built release for your operating system from the [Releases page](../../../releases/latest), **or**
  - [Build from source](#building-from-source) using Zig 0.16.

---

## Quickstart

### 1. Extract OpenReliant
Download and extract the archive for your operating system (Linux, macOS, or Windows). Open a terminal in the extracted folder:
- **Windows**: Right-click inside the folder and select **Open in Terminal**.
- **macOS**: Right-click the folder in Finder and select **Services > New Terminal at Folder**.
- **Linux**: Right-click inside your file manager and select **Open in Terminal**.

*(On Windows, use `.\openreliant.exe` instead of `./openreliant` in the commands below.)*

### 2. macOS Security Setup (macOS only)
Because release builds are not yet signed with an Apple developer certificate, remove the quarantine attribute before running:

```bash
xattr -d com.apple.quarantine openreliant
```

### 3. Install Game Assets

#### Option A: From Physical CD-ROMs
Insert StarLancer Disc 1 into your optical drive and run:

```bash
./openreliant install StarLancer
```

The installer detects your CD-ROM drive, extracts `LANCER.CAB` and copies required game data (approximately 1.2 GB) into a folder named `StarLancer`. When prompted, insert Disc 2 and press Enter to finish copying the remaining cinematics and missions.

*Tip: If you do not have Disc 2 immediately available, type `skip` when prompted. You can re-run the installer with Disc 2 later to install the missing files.*

#### Option B: From Disc Images (`.bin` / `.iso`)
If you have raw disc images or mounted folders, specify both images using `--from`:

```bash
./openreliant install --from "StarLancer Disc 1.bin" --from "StarLancer Disc 2.bin" StarLancer
```

#### International Releases
The installer verifies the file size of `LANCER.CAB` against known release signatures (the North American release is 226,746,308 bytes). If your disc comes from a regional release with a different file size, add `--force` to proceed anyway:

```bash
./openreliant install --force StarLancer
```

### 4. Launch the Game

Run the executable pointing to your installed game directory:

```bash
./openreliant StarLancer
```

The game opens to the in-game options menu:
- Select **CONTINUE** (or press **Escape**) to launch flight in the sandbox.
- Press **Escape** during flight to bring back the options menu.
- Press **F2** / **F3** to cycle through available player ships.
- Press **F4** to spawn an enemy wing.
- Number keys **1 through 8** switch camera perspectives (Cockpit, Chase, Target, External, Flyby, etc.).

---

## Building from Source

To compile OpenReliant yourself, install [Zig 0.16](https://ziglang.org). Dependencies (SDL3, OpenAL Soft, libarchive) build automatically from source.

```bash
# Build an optimized executable
zig build -Doptimize=ReleaseFast

# Run the installer
zig-out/bin/openreliant install StarLancer

# Launch the game
zig-out/bin/openreliant StarLancer
```

---

## Next Steps

- [**Controllers & Input**](controllers.md): Set up gamepads, flight sticks, HOTAS devices, and custom button mappings.
- [**Configuration & Options**](configuration.md): Explore command-line flags for rendering quality, audio modes, and display resolutions.
