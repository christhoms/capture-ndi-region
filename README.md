<p align="center">
  <img src="Assets/logo_1024.png" width="180" alt="Capture NDI Region logo">
</p>

# Capture NDI Region

NDI source with definable regions of interest.
- Target individual application windows as sources
- Crop / Scale regions within windows
- Limit FPS to reduce network/processing load

**Capture NDI Region.app** 
MacOS native SwiftUI App

**ndi-region**
CLI for scripting. 

Universal builds: [Releases](https://github.com/christhoms/capture-ndi-region/releases).
An NDI runtime is required; see [NDI runtime](#ndi-runtime).

## Build

```sh
swift build -c release          # CLI at .build/release/ndi-region
Scripts/make-app.sh             # ad-hoc-signed app at "dist/Capture NDI Region.app"
Scripts/make-release.sh 1.2.3   # signed + notarized release zips
```

## CLI

```sh
ndi-region --list
ndi-region --app ShowKontrol --bottom 220 --max-width 1920 --name "SK Decks Only"
ndi-region --window-id 1431 --bottom 400
```

| Flag | Default | Meaning |
|---|---|---|
| `--app <name>` | - | Match window by app name (case-insensitive substring) |
| `--title <substr>` | - | Additionally match by window title |
| `--window-id <id>` | - | Capture an exact window id from `--list` |
| `--bottom <pt>` | 400 | Height of the bottom strip, in window points |
| `--rect <x,y,w,h>` | - | Crop rect in window points, origin top-left (overrides `--bottom`) |
| `--max-width <px>` | 1920 | Output width cap; height follows aspect ratio |
| `--fps <n>` | 30 | Frame rate cap |
| `--name <s>` | `Region - <app>` | NDI source name |
| `--cursor` | off | Include the mouse cursor |
| `--dump-frame <path>` | - | Write the first captured frame to a PNG |

## Notes

- Config and presets: `~/Library/Application Support/CaptureNDIRegion/`.
- Auto and `--app`/`--title` matching: case-insensitive substring or `*`/`?`
  glob.
- `CNR_START_COLLAPSED=1` starts the app collapsed.
- Crop is captured at native pixel density, scaled output dimensions are rounded to even numbers.
- Frames are sent only when window content changes.
- Screen Recording permission is required and will be requested on first launch.

## NDI runtime

Not bundled (NDI license). Searched at launch, in order:

1. `$NDI_RUNTIME_DIR_V6` / `$NDI_RUNTIME_DIR_V5`
2. `/usr/local/lib/libndi.dylib`, where the
   [NDI runtime installer](https://ndi.link/NDIRedistV6Apple) puts it
3. `/Library/NDI SDK for Apple`
4. Runtimes inside common NDI apps

For the CLI, install the runtime or set `NDI_RUNTIME_DIR_V5`.

---

<p align="center">
  <img src="Assets/DAWG.png" width="90" alt="the studio dawg"><br>
  <sub>Quality assurance by the studio dawg.</sub>
</p>
