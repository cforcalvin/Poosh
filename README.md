# Poosh

A lightweight macOS image previewer for Finder — Quick Look–style browsing with tone curve adjustments and rotation.

<img width="1470" height="956" alt="Screenshot 2026-07-12 at 5 33 07 AM" src="https://github.com/user-attachments/assets/03edf84d-7d92-44dd-85bf-5aa9c758aecb" />
<img width="1470" height="956" alt="Screenshot 2026-07-12 at 5 32 02 AM" src="https://github.com/user-attachments/assets/8a5028aa-5ecf-4ab0-99e4-cd5fb811045f" />

## Features

- Open the selected Finder image with **⌘⇧Space**
- Browse neighboring images with arrow keys (follows Finder selection)
- Fast tone curve editing in a floating HUD
- Rotate left / right before saving
- **Enter** / **Arrow keys to next photo** — save curve + rotation and close  
  **Esc** — discard changes and close
- Supports JPEG, PNG, HEIC, and WebP

## Requirements

- macOS 14.0+
- Automation permission for Finder (System Settings → Privacy & Security → Automation)

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
3. Press **⌘⇧Space** to preview.
4. Adjust the tone curve or rotate as needed.
5. Press **Enter** or **Space** to save, or **Esc** to discard.

## License

MIT — see [LICENSE](LICENSE).
