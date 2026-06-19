<div align="center">

<img src="assets/lumos_icon.png" alt="Lumos app icon" width="128" height="128">

# Lumos

### Adaptive screen brightness for macOS that follows your content — and learns from you.

Lumos watches what's on your screen and keeps its **perceived** brightness steady: it dims
for bright pages and brightens for dark editors, so your eyes aren't constantly readjusting.
Set the brightness yourself once and it **remembers what you wanted** — across your built-in
display *and* every external monitor.

**Apple Silicon · macOS 14+ · lives in the menu bar**

[![GitHub downloads](https://img.shields.io/github/downloads/lenbrocki/lumos/total?label=downloads&color=blue)](../../releases)

<br>

<img src="assets/lumos_readme.gif" alt="Lumos adapting screen brightness to on-screen content" width="720">

</div>

---

## ✨ Features

- **🌗 Content-aware** — bright, white-heavy windows dim the backlight; dark IDEs and terminals
  brighten it. The goal is constant *perceived* brightness and less eye strain.
- **🧠 Learns your preference** — whenever you adjust brightness yourself, Lumos records what
  you wanted for that kind of content and adapts its curve. The more you use it, the more it
  feels like yours.
- **⏸️ Pause for any app** — mark apps (a video player, a photo editor, a game) to hold a fixed
  brightness instead of adapting. Lumos remembers the level you picked for each one, per display.
- **🖥️ Built-in *and* external monitors** — controls your MacBook panel and external displays
  over DDC/CI, each adapted to its own content and with its own learned memory. Plug or unplug a
  monitor and it adjusts automatically.
- **🔒 Private** — everything happens locally on your Mac; nothing is sent anywhere.

## Install

### Homebrew

```sh
brew install --cask lenbrocki/tap/lumos
```

Then launch Lumos — a sun icon appears in your menu bar. Update later with
`brew upgrade --cask lumos`.

### Manual

1. Download **`Lumos.dmg`** from the [latest release](../../releases/latest).
2. Open it and drag **Lumos** into **Applications**.
3. Launch Lumos — a sun icon appears in your menu bar.

> Releases are signed with a Developer ID and notarized by Apple, so they open without security
> warnings.

## Getting started

1. Click the menu-bar icon and turn on **Auto-brightness**.
2. Grant **Screen Recording** when macOS asks (System Settings → Privacy & Security → Screen
   Recording → enable **Lumos**), then relaunch the app. *Lumos reads your screen only to
   measure how bright the content is — never its contents.*
3. In **System Settings → Displays**, turn **off “Automatically adjust brightness”** so Lumos
   is the only thing controlling your backlight.

That's it — switch between a dark editor and a bright browser and watch the brightness follow.

## Teaching it your preference

Each display has a brightness **slider** in the menu. Whenever the brightness isn't quite right:

- **Built-in display:** just use your keyboard's brightness keys as usual.
- **External display:** drag its slider in the menu.

Lumos treats that as *“for this kind of content, I want this brightness”* and reshapes that
display's curve so similar content lands where you like it next time. Corrections are **local** —
tuning bright pages doesn't affect how dark ones behave. Each display remembers separately, and
its memory survives reconnects. A per-display reset button restores the default curve.

## Pausing for an app

Some apps shouldn't be touched — a fullscreen movie where the backlight shouldn't chase the
scene, a photo or video editor where you're judging the image, a game. Open the menu and flip
**Pause for &lt;app&gt;** while that app is frontmost. From then on, whenever it's in front Lumos
stops adapting and holds a fixed brightness; whatever level you set while in that app (slider or
brightness keys) becomes its remembered level, **per display**. Paused apps are listed in the menu
with a button to resume auto-brightness.

## How it works (in plain terms)

Lumos takes a tiny, low-resolution snapshot of each screen *only when its content changes*,
measures the average brightness, and maps that to a backlight level through a curve it keeps
refining from your corrections. Transitions ramp smoothly so there's no flicker, and a static
screen costs essentially nothing.

---

## Under the hood

- **Per-display engine** — each display gets its own capture stream, brightness curve, and
  control loop, created and torn down automatically on hotplug ([`DisplayCoordinator`](Lumos/DisplayCoordinator.swift),
  [`DisplayEngine`](Lumos/DisplayEngine.swift)).
- **Sensing** — an event-driven [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit)
  stream downscaled to ~64×40 px. It's push-based (frames arrive only on content change), so
  reactions are near-instant and an idle screen is ~0 CPU. Each frame is reduced to its average
  **perceptual lightness** (CIE L\*) — pixels are linearized from sRGB and mapped to a
  perceptually uniform scale, so the reading tracks perceived brightness rather than raw bytes
  ([`LuminanceCalculator`](Lumos/LuminanceCalculator.swift)).
- **Learnable mapping** — an [`AdaptiveBrightnessModel`](Lumos/AdaptiveBrightnessModel.swift)
  of interpolated control points across the luminance range. It cold-starts from a fixed curve
  and is reshaped by corrections via a local, distance-weighted update that keeps the curve
  monotonic. Saved per display to `~/Library/Application Support/Lumos/curve-<id>.json`.
- **Actuation** — built-in panel through the private `DisplayServices` framework
  (`DisplayServicesSetBrightness`, resolved with `dlopen`/`dlsym`); external monitors through
  **DDC/CI** over I2C using the vendored [`Arm64DDC`](Lumos/Vendor/MonitorControl/Arm64DDC.swift)
  from MonitorControl. Because it uses private APIs it is **not sandboxed** and can't ship on the
  Mac App Store.
- **Smoothness** — a [`LuminanceStabilizer`](Lumos/LuminanceStabilizer.swift) ignores transient
  luminance during window/space-swipe animations, and brightness ramps fast for big switches,
  gently for small ones.

### Build from source

```sh
xcodebuild -project Lumos.xcodeproj -scheme Lumos -configuration Debug \
  -derivedDataPath build build
open build/Build/Products/Debug/Lumos.app
```

Or open `Lumos.xcodeproj` in Xcode and Run.

### Releasing (maintainer)

Pushing a `v*` tag triggers [`.github/workflows/release.yml`](.github/workflows/release.yml),
which builds, Developer-ID-signs, **notarizes**, packages `Lumos.dmg`, and publishes a GitHub
Release.

```sh
git tag v0.1.0
git push origin v0.1.0
```

One-time repo **secrets** (Settings → Secrets and variables → Actions):

| Secret | What it is |
| --- | --- |
| `MACOS_CERTIFICATE` | base64 of your exported *Developer ID Application* `.p12`: `base64 -i cert.p12 \| pbcopy` |
| `MACOS_CERTIFICATE_PWD` | the password you set when exporting the `.p12` |
| `KEYCHAIN_PASSWORD` | any string (temporary CI keychain) |
| `APPLE_ID` | your Apple ID email |
| `APPLE_TEAM_ID` | your 10-char Team ID |
| `APPLE_APP_PASSWORD` | an app-specific password from appleid.apple.com (for notarytool) |

### Tuning

- [`BrightnessMapper.swift`](Lumos/BrightnessMapper.swift) — `minBrightness`, `maxBrightness`,
  `gamma` (the default curve).
- [`DisplayEngine.swift`](Lumos/DisplayEngine.swift) — `jumpThreshold`, `fastRampPerSecond`,
  `gentleRampPerSecond`, `overrideThreshold`, `overrideSettleTime` (reaction / learning).
- [`LuminanceStabilizer.swift`](Lumos/LuminanceStabilizer.swift) — `settleTime` (transient
  rejection; default `0` = off).

### Limitations

- `DisplayServicesSetBrightness` and the DDC `IOAVService*` symbols are private/undocumented.
  They work on current Apple Silicon Macs but are unsupported by Apple and could change.
- External control needs DDC/CI; some displays — or connections through certain USB-C
  hubs/docks — don't support it and won't appear as controllable.
- Capture reads rendered pixels, not emitted light, so there's no feedback loop between the
  backlight and the measurement.

## Credits & license

Lumos was inspired by [lumen](https://github.com/anishathalye/lumen).
Unlike lumen, Lumos fully supports external monitors out of the box, controlling them over
DDC/CI with their own content-adapted, learnable brightness curves.

Lumos is released under the [MIT License](LICENSE). DDC/CI control on Apple Silicon
([`Arm64DDC.swift`](Lumos/Vendor/MonitorControl/Arm64DDC.swift)) is vendored from
[MonitorControl](https://github.com/MonitorControl/MonitorControl), also MIT.
