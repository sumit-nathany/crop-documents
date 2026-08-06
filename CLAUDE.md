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
| `lab/` | Deskew/rotate regression harness (Python) |
| `processor.py`, `batch.py`, `pdf_builder.py`, `detector/`, `enhancer/` | Legacy Python CLI — reference implementation, see below |

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

1. **Close the `--deskew` parity gap** between `DocumentTrimmer` and `processor.trim_external_content`,
   using `lab/`. This is the last thing blocking Python retirement.
2. **Re-verify auto-rotate on device** before re-enabling it in the iOS UI.
3. Mac GUI deferred.
4. Prefer small, flag-compatible CLI changes.

## Known soft spots

- **`--deskew` trim is not at parity.** On the lab set, one image matches Python exactly;
  the other keeps a flap Python trims. Swift errs conservative (safe direction). The
  Canny hysteresis bug behind the *destructive* divergence is fixed; what remains is a
  difference in the run-merging/threshold analysis.
- **`straighten` is off by default and hidden in the iOS UI** — two rounds of
  "verified" fixes did not hold up on real device photos. See `ios/HANDOFF.md`.
- **`--rotate` fixes sideways pages only, never 180°.** Vision reads upside-down text
  nearly as well as upright text, so the 180° call is a coin toss. Measured, documented
  in `DocumentOrienter`. This is narrower than the Tesseract OSD it replaced.
- Residual perspective / cardboard bow on handheld box photos can't be removed by one
  plane warp.

## Why the Python CLI still exists

`processor.py` is the reference implementation and the only ground truth for the
unfinished deskew port. The Swift CLI reproduces the **default crop path** exactly —
same detections, dimensions, and confidences, with pixel differences only at
high-gradient edges (Lanczos vs CoreImage resampling). It is not yet equivalent on
`--deskew`. Retire the Python pipeline only after that gap closes.

## Regression

Put hard photos in `lab/cases/` (gitignored images OK).

```bash
python3 lab/run_regression.py                      # Python pipeline
swift test --package-path ios/DocumentCropCore     # engine unit tests
./crop-documents probe-orientation lab/cases/*.jpg # inspect rotate decisions
```

To compare the two implementations on the same inputs, run `batch.py` and
`./crop-documents` into separate output directories and diff dimensions first —
geometry divergence matters, resampling noise doesn't.

See `lab/README.md`.
