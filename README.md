<p align="center">
  <img src="Assets/logo_1024.png" width="180" alt="Capture NDI Region — a region of a window, cropped and sent as NDI">
</p>

# Capture NDI Region

Send a cropped, scaled **region of a macOS window** as an NDI source. NDI Scan
Converter only offers full screens or whole windows; this captures any rectangle
of one window.

Uses ScreenCaptureKit (crop and scale on the GPU) and loads the NDI runtime via
`dlopen`, so building needs Swift/Xcode but not the NDI SDK.

Two front ends over the same core:

- **Capture NDI Region.app** — SwiftUI app managing multiple feeds (different
  windows or different regions of the same window), each its own NDI source.
  Feeds persist across launches; feeds marked Auto-start begin streaming on
  open.
- **ndi-region** — CLI for scripting/launchd.

## Download

Signed, notarized universal (Apple Silicon + Intel) builds are on
[Releases](https://github.com/christhoms/capture-ndi-region/releases):

- `Capture-NDI-Region-<version>.zip` — the app; unzip and drop in /Applications
- `ndi-region-cli-<version>.zip` — the CLI binary

You'll also need an NDI runtime — see [NDI runtime](#ndi-runtime) below.

## Build from source

```sh
swift build -c release          # CLI at .build/release/ndi-region
Scripts/make-app.sh             # ad-hoc-signed app at "dist/Capture NDI Region.app"
Scripts/make-release.sh 1.2.3   # signed + notarized release zips (needs a
                                # Developer ID cert and notarytool credentials)
```

## App

Each feed row sets:

- **NDI name.**
- **Window** — pick an exact window, or leave it on **Auto** and type app/title
  match text: case-insensitive substring, or a `*`/`?` glob like `Show*`.
  Offscreen phantom windows that never deliver frames are hidden.
- **Crop** — **Bottom strip** (height in points, default 220) or **Custom rect**
  (x/y/w/h in window points, origin top-left).
- **Max output width** (default 1920), **FPS**, and **Auto-start**.

Add rows with **+** for multiple simultaneous NDI feeds.

**Presets:** the Presets toolbar menu loads a preset as a new feed row, saves
the current feed as a preset (named after its NDI name; same name overwrites),
and deletes saved ones. "ShowKontrol Decks" ships built in; your own are
stored in `presets.json` alongside the config. A fresh install starts with no
feeds and offers the presets as starting points; feeds persist, so loading a
preset once sets it up for every launch.

Config lives at `~/Library/Application Support/CaptureNDIRegion/feeds.json`.

**Source loss & recovery:** if the captured window goes away (source app quit,
window closed), the NDI source stays on air showing a "Window went away" slate
(the studio dawg on a dark card), so receivers keep the source. The app then
watches for a window matching the feed's app/title text and reattaches
automatically, typically within ~2s of the source app coming back. Starting a
feed whose window doesn't exist yet behaves the same way. Options →
**Choose Slate Image…** puts any image on the slate instead (copied into the
config folder, so the original can move); **Use Built-in Dawg** switches back.

**Show mode:** the close button doesn't quit — it collapses the window to a
slim titlebar strip (live-feed count, an expand chevron, a quit button). The
window also auto-collapses after launch when auto-start feeds come up cleanly.
Pressing close again while collapsed, or Cmd-W / Cmd-Q any time, quits.
Fullscreen is disabled. Launch with `CNR_START_COLLAPSED=1` to start collapsed,
e.g. from launchd.

First launch prompts for Screen Recording permission. If it's missing or was
denied, the app shows a recovery banner: **Request Again** resets the app's TCC
entry (`tccutil reset ScreenCapture <bundle-id>`) so the system prompt
reappears (macOS never re-prompts on its own after a denial), and **Open System
Settings** jumps to the Screen Recording pane. Once granted, the banner offers
one-click relaunch (grants only take effect at launch). Rebuilding re-signs the
app ad hoc, so macOS may ask again after a rebuild.

## CLI

```sh
# See what's capturable
ndi-region --list

# Bottom 220pt of the ShowKontrol window, scaled to max 1920px wide
ndi-region --app ShowKontrol --bottom 220 --max-width 1920 --name "SK Decks Only"

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
moved, occluded, or resized (the crop follows a resize within ~2s).

## NDI runtime

The NDI library is **not bundled** (NDI's license doesn't allow casual
redistribution) — it's discovered at launch from, in order:

1. `$NDI_RUNTIME_DIR_V6` / `$NDI_RUNTIME_DIR_V5`
2. `/usr/local/lib/libndi.dylib` (the official [NDI runtime installer](https://ndi.link/NDIRedistV6Apple) and NDI Tools put it here)
3. The NDI SDK install (`/Library/NDI SDK for Apple`)
4. Runtimes bundled inside common NDI apps (Resolume, NDI Video Monitor)

If none is found, the app shows a banner with a download link and a **Re-check**
button — installing the runtime does not require relaunching the app. For the
CLI, install the runtime or set `NDI_RUNTIME_DIR_V5` to a folder containing
`libndi.dylib`. Both print which runtime they loaded.

## Notes

- **Retina:** the crop is captured at native pixel density, then scaled down:
  a 1710pt-wide window yields a 3420px-wide crop, scaled to 1920px. Output
  dimensions are rounded to even numbers for encoder compatibility.
- **Permission:** the terminal running the CLI needs Screen Recording permission
  (System Settings → Privacy & Security → Screen Recording). The app has its own
  permission identity.
- Frames are only delivered when the window content changes (ScreenCaptureKit
  behaviour); NDI receivers hold the last frame, so static content is fine.
- The app icon is generated from the source assets by `swift Scripts/make-icon.swift`
  (then repackaged into `Assets/AppIcon.icns`).

---

<p align="center">
  <img src="Assets/DAWG.png" width="90" alt="the studio dawg"><br>
  <sub>Quality assurance by the studio dawg.</sub>
</p>
