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
3. Optional CoreImage auto-enhance (`--enhance` on CLI)
4. Save to Photos or share

Pipeline matches the macOS CLI stable path in `processor.py` / `enhancer/enhance.swift`.

## Layout

```
ios/
├── project.yml
├── Margin/                  # SwiftUI app
├── DocumentCropCore/        # Vision detect + warp
└── README.md
```
