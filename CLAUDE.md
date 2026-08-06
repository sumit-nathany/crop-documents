# CLAUDE.md — crop-documents

## What this is

Auto-crops document photos (receipts, bills, cards) with a natural background margin,
optional deskew/rotation, and PDF bundling. Two front ends — a **macOS CLI** and an
**iPhone app** — over one shared Swift engine.

## Quick start

```bash
./build-cli.sh                              # builds ./crop-documents (release)
./crop-documents --input ./photos/          # crop in place (or --output DIR)
./crop-documents --input ./photos/ --deskew --rotate --pdf out.pdf

cd ios && xcodegen generate && open Margin.xcodeproj   # iPhone app
```

## Architecture

Everything that touches pixels lives in `DocumentCropCore`. The front ends only pick
files and show results — that separation is deliberate and load-bearing, so resist
fixing a crop bug inside the app or the CLI.

```
Mac CLI ─────┐
             ├─▶ DocumentCropCore: load → detect → expand → warp
iPhone app ──┘                     → [deskew + trim] → [rotate] → [enhance] → save
```

| File | Responsibility |
|------|----------------|
| `ios/DocumentCropCore/Sources/DocumentCropCore/` | **The engine** (see below) |
| `ios/DocumentCropCore/Sources/CropDocumentsCLI/` | Mac front end: args, file walk, console |
| `ios/Margin/` | iPhone front end (SwiftUI) |
| `lab/` | Regression cases + variant runner (`run_regression.sh`) |

Inside the engine:

| Type | Responsibility |
|------|----------------|
| `DocumentDetector` | Vision doc-seg + rectangle fallback → quad |
| `DocumentWarper` | Perspective warp, deskew (Hough/polyfit skew estimate) |
| `DocumentTrimmer` | Top/bottom flap trim via edge density |
| `DocumentOrienter` | Quarter-turn correction via Vision text |
| `DocumentEnhancer` | CoreImage `autoAdjustmentFilters` |
| `DocumentImageIO` | Load/save, EXIF bake, HEIC→JPEG naming |
| `DocumentPDFBuilder` | Native CGContext multi-page PDF |
| `DocumentCropper` | Orchestrates the above; `cropFile` is the file-level entry |

Vision coords: normalized, origin bottom-left, order TL,TR,BR,BL. The engine converts
to top-left pixel space at the boundary.

## Gotchas that have bitten before

- **Adding a file to `DocumentCropCore` requires `cd ios && xcodegen generate`.** SPM globs
  the directory; the checked-in `.xcodeproj` enumerates files. Skipping this leaves
  `swift build` green while the iOS app fails with "cannot find X in scope".
- **Always verify both front ends** after touching the core:
  `swift build --package-path ios/DocumentCropCore` **and**
  `xcodebuild -project ios/Margin.xcodeproj -scheme Margin -destination 'generic/platform=iOS Simulator' build`.
- **Detection thresholds are per-platform policy, not algorithm.** `DetectionPolicy.strict`
  (iOS, 35% area floor) rejects sub-region latches on camera photos; `.lenient` (Mac)
  matches Python's no-floor behaviour on curated files. Don't hardcode one platform's
  tuning into shared code — that already broke a working Mac case once.
- **Build release for anything timed.** The pixel loops are ~10x slower under `-Onone`.

## Product / agent priorities

1. **Re-verify deskew + auto-rotate on a real device** before re-enabling the straighten
   toggle in the iOS UI. Both are verified on Mac against the lab set; neither has held up
   on-device yet, and that is the remaining unknown.
2. Mac GUI deferred.
3. Prefer small, flag-compatible CLI changes.

## Known soft spots

- **The trim's edge detector is delicate.** `cannyLite` has broken twice: once by treating
  Canny's 50/150 hysteresis thresholds as a band (discarding strong edges), once by omitting
  non-maximum suppression (edges too thick, inflating row density ~50% so flap and page
  merged into one block). `DocumentTrimmerTests` pins both. `DocumentTrimmer.analysisMaxSide`
  is likewise load-bearing — below 1600 the void between flap and page closes up.
- **`straighten` is off by default and hidden in the iOS UI** — two rounds of
  "verified" fixes did not hold up on real device photos. See `ios/HANDOFF.md`.
- **`--rotate` fixes sideways pages only, never 180°.** Vision reads upside-down text
  nearly as well as upright text, so the 180° call is a coin toss. Measured, documented
  in `DocumentOrienter`. This is narrower than the Tesseract OSD it replaced.
- Residual perspective / cardboard bow on handheld box photos can't be removed by one
  plane warp.

## The Python pipeline this replaced

Removed 2026-08-07. It was Python + OpenCV + Tesseract with a shelled-out Swift Vision
binary, and it was the reference the engine was validated against — default crop path
(identical dimensions and confidences) and `--deskew` (both lab cases trim identically,
residual skew comparable or better). `lab/python-reference-baseline.json` preserves the
dimensions it produced. Treat a large drift from those numbers as a regression to explain,
not to re-baseline.

## Regression

Put hard photos in `lab/cases/` (gitignored images OK).

```bash
./lab/run_regression.sh                            # crop / deskew / rotate variants
swift test --package-path ios/DocumentCropCore     # engine unit tests
```

Diagnostic subcommands, for when a stage misbehaves — each reports what the engine
decided without changing anything:

```bash
./crop-documents probe-trim        <image>   # row analysis: runs, merge, main block
./crop-documents probe-skew        <image>   # raw deskew angle estimate
./crop-documents probe-orientation <image>   # quarter-turn scores per orientation
```

When comparing outputs, diff **dimensions and residual skew**, not per-pixel deltas — a
0.6° deskew changes an image by mean|Δ|≈13 on textured photos, so pixel metrics drown in
texture. See `lab/README.md`.
