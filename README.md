# Poosh

A lightweight macOS image previewer for Finder — Quick Look–style browsing with tone curve adjustments, crop, rotation, and trackpad zoom.

<img width="1268" height="736" alt="Screenshot 2026-07-12 at 5 32 02 AM" src="https://github.com/user-attachments/assets/dcfd4521-8e1d-4261-b0d0-89ef7f3cbce7" />
<img width="1277" height="742" alt="Screenshot 2026-07-12 at 5 33 07 AM" src="https://github.com/user-attachments/assets/5d89fd3c-4aa5-42ab-bdb1-08035e5d6fd2" />

## Features

- Open the selected Finder image with **Space** (replaces Quick Look while Poosh is running and Finder is frontmost) or **⌘⇧Space**
- Press **Space** again to close (saves edits); **Esc** discards and closes
- Browse neighboring images with arrow keys (follows Finder selection)
- **Pinch to zoom** and two-finger pan while zoomed (image stays edged to the viewport)
- **⌘+/−/0** or double-tap to zoom in, out, or reset
- Freeform **crop** before saving
- Fast tone curve editing in a floating HUD
- Rotate left / right before saving
- Supports JPEG, PNG, HEIC, and WebP

## What's new in 1.3.1

- **Snappier first open** — Finder selection no longer freezes the UI; Metal/CI warms at launch; monitors install after the first frame
- **Faster soft→sharp** — shorter upgrade delay, sharper first paint (720px), and ±1 neighbor prefetch at full preview size
- **Cropped previews match immediately** — saved crop/rotation/curve apply on first paint instead of flashing the uncropped thumb
- Zoom/pan only while the pointer is over the **image** window (not the curve HUD)

## What's new in 1.3.0

- Pinch-to-zoom and trackpad pan with edge clamping (image can’t slide fully offscreen)
- Freeform crop overlay
- Faster first open — paints before the panel appears; defers fingerprint lookup off the hot path
- Reliable Space toggle — Space closes the preview instead of reopening it
- Prompts for **Input Monitoring** (and Accessibility) so pinch works while Finder stays frontmost

## Requirements

- macOS 14.0+
- **Automation** permission for Finder (System Settings → Privacy & Security → Automation)
- For pinch zoom while Finder is frontmost:
  - **Accessibility**
  - **Input Monitoring**

Poosh prompts for these on first use when needed.

## Build from source

```bash
xcodebuild -scheme Poosh -configuration Release -derivedDataPath build
open build/Build/Products/Release/Poosh.app
```

Or open `Poosh.xcodeproj` in Xcode and run.

## Release build (Developer ID + notarization)

Requires a **Developer ID Application** certificate and notarization credentials stored via `notarytool`:

```bash
# One-time: store credentials in Keychain
xcrun notarytool store-credentials "Poosh-Notary" \
  --apple-id "YOUR_APPLE_ID" \
  --team-id "GSLU4J8LYR" \
  --password "app-specific-password"

./Scripts/release.sh
```

The script produces a signed, notarized, stapled `.app` (and zip) under `dist/`.

## Usage

1. Launch Poosh (menu bar / accessory app).
2. Select an image in Finder.
3. Press **Space** (or **⌘⇧Space**) to preview.
4. Pinch to zoom, pan while zoomed, adjust the tone curve, crop, or rotate as needed.
5. Press **Space** or **Enter** to save and close, or **Esc** to discard.

While Finder is frontmost, Space is claimed by Poosh so Quick Look does not open. In other apps, Space behaves normally.

## License

MIT — see [LICENSE](LICENSE).
