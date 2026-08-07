# Margin (iOS)

Simple iPhone app to crop document photos with a natural border.

## Open

```bash
cd ios
xcodegen generate   # if needed
open Margin.xcodeproj
```

Requires Xcode 16+, iOS 17+. Use a real iPhone for camera + saving to Photos.

## Flow

1. Choose photos or take one
2. Auto-detect → expand border → warp → optional straighten + flap trim
3. Optional quarter-turn correction, then optional CoreImage auto-enhance
4. Tap a result to view it full-screen; save to Photos or share

The app and the Mac CLI (`./crop-documents`) run the *same* engine — `DocumentCropCore` —
so crop behaviour is identical by construction rather than by porting.

Note: `straighten` is off and its Settings toggle is hidden, pending on-device
re-verification of the deskew angle estimate — it has passed verification on Mac twice
without holding up on a real device. See `HANDOFF.md`.

Settings exposes Border (expansion %) and Enhance.

## Layout

```
ios/
├── project.yml
├── Margin/                          # SwiftUI app (front end only)
├── DocumentCropCore/
│   ├── Sources/DocumentCropCore/    # Shared engine — detect, warp, trim, orient, enhance, IO, PDF
│   ├── Sources/CropDocumentsCLI/    # Mac CLI front end
│   └── Tests/
└── README.md
```

## Adding a file to DocumentCropCore

Re-run `xcodegen generate`. SPM picks new files up automatically; the checked-in
`.xcodeproj` does not, so the app will fail to compile while `swift build` stays green.
