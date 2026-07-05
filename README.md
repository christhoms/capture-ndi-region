# ndi-region

Send a cropped, scaled **region of a macOS window** as an NDI source — the thing
NDI Scan Converter can't do (it only offers full screens or whole windows).

Built with ScreenCaptureKit (GPU crop + scale, no CPU pixel pushing) and the NDI
runtime loaded via `dlopen` — no NDI SDK needed to build, just Swift/Xcode.

Two front ends over the same core:

- **NDI Region.app** — SwiftUI app managing multiple feeds (different windows or
  different regions of the same window), each its own NDI source. Feeds persist
  across launches; mark them Auto-start and the app is show-ready on open.
- **ndi-region** — CLI for scripting/launchd.

## Build

```sh
swift build -c release          # CLI at .build/release/ndi-region
Scripts/make-app.sh             # app at dist/NDI Region.app
```

## App

Each feed row: NDI name, window picker (defaults to auto-matching "ShowKontrol";
phantom offscreen windows are marked `[offscreen]` and deprioritized), crop as
**Bottom strip** (height in points, default 220) or **Custom rect** (x/y/w/h in
window points, origin top-left), max output width (default 1920), FPS, and
Auto-start. Add rows with **+** for multiple simultaneous NDI feeds.

Config lives at `~/Library/Application Support/NDIRegion/feeds.json`.

First launch prompts for Screen Recording permission. If it's missing (or you
hit Deny by accident), the app shows a recovery banner: **Request Again** resets
the app's TCC entry (`tccutil reset ScreenCapture <bundle-id>`) so the system
prompt genuinely reappears — macOS never re-prompts on its own after a denial —
and **Open System Settings** jumps straight to the Screen Recording pane. Once
the grant lands, the banner offers one-click relaunch (grants only take effect
at launch). Rebuilding re-signs the app ad hoc, so macOS may occasionally ask
again after a rebuild.

## Usage

```sh
# See what's capturable
ndi-region --list

# Bottom 400pt of the biggest grandMA3 onPC window, scaled to max 1920px wide
ndi-region --app app_gma3 --bottom 400 --max-width 1920 --name "MA3 Letterbox"

# Pin an exact window (ids from --list)
ndi-region --window-id 1431 --bottom 400
```

| Flag | Default | Meaning |
|---|---|---|
| `--app <name>` | — | Match window by app name (case-insensitive substring) |
| `--title <substr>` | — | Additionally match by window title |
| `--window-id <id>` | — | Capture an exact window id from `--list` |
| `--bottom <pt>` | 400 | Height of the bottom strip, in window points |
| `--rect <x,y,w,h>` | — | Arbitrary crop rect in window points, origin top-left (overrides `--bottom`) |
| `--max-width <px>` | 1920 | Output width cap; height follows aspect ratio |
| `--fps <n>` | 30 | Frame rate cap |
| `--name <s>` | `Region - <app>` | NDI source name |
| `--cursor` | off | Include the mouse cursor |
| `--dump-frame <path>` | — | Also write the first captured frame to a PNG (verify your crop) |

Ctrl-C stops cleanly. The window is tracked by id, so it keeps streaming when
moved, occluded, or resized (the crop re-glues to the bottom edge within ~2s of
a resize).

## Notes

- **Retina:** the crop is captured at native pixel density, then scaled down —
  a 1695pt-wide window yields a 3390px-wide crop, scaled to 1920px. Output
  dimensions are rounded to even numbers for encoder friendliness.
- **Permission:** the terminal running it needs Screen Recording permission
  (System Settings → Privacy & Security → Screen Recording).
- **NDI runtime discovery order:** `$NDI_RUNTIME_DIR_V6` / `$NDI_RUNTIME_DIR_V5`,
  `/usr/local/lib/libndi.dylib`, the NDI SDK install path, Resolume's bundled
  runtime, NDI Video Monitor's bundled runtime. It prints which one it loaded.
- Frames are only delivered when the window content changes (ScreenCaptureKit
  behaviour); NDI receivers hold the last frame, so static content is fine.
