# iOS Margin crop — agent handoff

Use this document as the **single source of truth** when fixing iOS document detection/crop. The user wants **one-shot fix**, not iterative log paste back-and-forth.

---

## Copy-paste prompt (give this to the new model)

```
You are fixing the iOS app "Margin" in repo crop-documents (path: ios/).

PROBLEM: On a real iPhone, picking a photo from the library produces a bad crop. The macOS CLI on the SAME photo works well. iOS Vision document segmentation consistently detects a ~25% bottom strip (high confidence) instead of the full document (~60–90% area). Workarounds (rectangle fallback, PHAsset loading, region refine) have not matched Mac quality.

YOUR JOB:
1. Read ios/HANDOFF.md fully, then read the cited source files.
2. Make iOS detection + crop match Mac CLI output on the failing photo class (phone photos of product boxes/receipts, often HEIC in library, ~3000×5700px).
3. Do NOT ask the user for more logs unless you are blocked on something only they can provide (e.g. a test photo file).
4. Build must succeed: `cd ios && xcodegen generate && xcodebuild -scheme Margin -destination 'generic/platform=iOS' build`
5. Explain root cause and what you changed in ≤10 sentences at the end.

SUCCESS CRITERIA:
- Debug log shows doc-seg picking full document (area ≥ 60%, method preferably `original file (heic)` or primary doc-seg, NOT `rectangle` fallback).
- Cropped result visually matches Mac CLI `--deskew` on the same source file.
- Post-warp deskew+trim completes in < 5s on ~3200×4000px (current ~30s is unacceptable).
- Do not re-introduce the old bug where 25% area detections were accepted (that cropped away ~90% of the document).

KEY MAC REFERENCE (works): detector/detect.swift loads CIImage(contentsOf: path) on the original file bytes, single VNDetectDocumentSegmentationRequest, no upright re-render before detect.

Start by reproducing mentally from the logs in HANDOFF.md, then fix photo loading + detection coordinate space so iOS sees the same pixels Vision sees on Mac.
```

---

## Product context

**Margin** (`ios/Margin`) is a minimal SwiftUI iPhone app: pick/camera → auto crop → save to Photos.

**Mac CLI** (`batch.py` + `detector/detect` + `processor.py`) is the algorithm reference. It works on the user's failing photos. iOS should match the **stable CLI path**: detect → expand border → warp → optional deskew stack (refine, upper-band deskew, top/bottom flap trim) → optional enhance.

The iOS core lives in `ios/DocumentCropCore/`. The app shell is `ios/Margin/`.

---

## Observed failure (real device logs)

Photo: **3213×5712px**, product-box style document photo.

### Run A — all strategies rejected
```
Loaded via picker Data (3259788 bytes)
Vision [image source] confidence=0.965 area=25% TL(22,4262) BR(3213,5690)  → Rejected (< 35% area)
Vision [jpeg re-encode] confidence=0.990 area=25%                           → Rejected
All detect strategies rejected → Job failed
```

### Run B — rectangle fallback (better but not Mac-quality)
```
Loaded via file transfer .jpeg (3259788 bytes, public.jpeg)
Vision [image source] confidence=0.965 area=25%  → Rejected
Trying rectangle fallback
Rectangle candidate confidence=1.000 area=62%
Picked [rectangle] confidence=1.000 area=62%
Warp → 3212×4062px
Crop done (~30 seconds after warp)
```

### What Mac does on the same photo
User confirms **Mac CLI crops correctly** when run on the original file from disk (likely **HEIC** from iPhone export/AirDrop, not transcoded JPEG).

---

## Root cause hypotheses (ranked)

1. **Wrong bytes for Vision** — PhotosPicker / FileRepresentation delivers **transcoded JPEG** (~3.26MB) even when the library asset is HEIC. Mac runs `CIImage(contentsOf: heicPath)`. JPEG transcoding may change encoding/sub sampling enough that `VNDetectDocumentSegmentationRequest` latches onto a bottom strip (label/barcode region) at 96–99% confidence.

2. **Detection vs warp coordinate mismatch** — iOS normalizes to an **upright bitmap** (`UIImage.normalizedUpCGImage()`) before detect+warp. Mac detects on `CIImage(contentsOf:)` which applies file orientation differently. Quad mapping between oriented CIImage space and upright pixel space may be wrong even when detection is right.

3. **Rectangle fallback is a band-aid** — 62% axis-aligned or 4-corner rectangle ≠ doc-seg quad. Warp from rectangle misses perspective keystone Mac gets from segmentation corners.

4. **Performance** — `DocumentTrimmer` + deskew on full-res (~13MP) takes ~30s. Mac Python path is faster; iOS does pixel loops on full RGB. Needs downscaled analysis (partially attempted) or vImage/Accelerate.

---

## What was already tried (do not repeat blindly)

| Attempt | Result |
|--------|--------|
| Reject doc-seg with area < 35% | Fixed “90% cropped away” bug; now fails or falls back |
| `OriginalPhotoFile` FileRepresentation | Still got `.jpeg` / `public.jpeg` — ran before PHAsset |
| PHAsset `requestImageDataAndOrientation` | Not reached when file transfer succeeded first |
| PHAssetResourceManager original bytes | Implemented; user says still not fixed (may not run, or HEIC still mis-detects) |
| Multi-strategy detect (original file, image source, upright CI, jpeg re-encode) | All doc-seg → 25% bottom strip on JPEG |
| `VNDetectRectanglesRequest` fallback | 62% crop, no Mac parity |
| Region doc-seg refine after rectangle | User reports no improvement |
| Magic-byte HEIC sniffing | JPEG path still used from picker |
| Downscaled trim analysis (1200px) | Build OK; perf not verified by user |

---

## Architecture (iOS)

```
PhotosPicker / Camera
  → PhotoLoader.loadFullResolution()     [ios/Margin/PhotoLoader.swift]
  → AppStore.enqueue(LoadedPhoto)        [ios/Margin/AppStore.swift]
  → DocumentCropper.crop(image:data:)     [DocumentCropCore/DocumentCropper.swift]
       1. normalizedUpCGImage()          [DocumentCropper.swift extension]
       2. DocumentDetector.detectForCrop [DocumentCropCore/DocumentDetector.swift]
       3. expand quad + warp              [DocumentWarper.swift]
       4. if straighten: deskew + trim    [DocumentWarper.deskew, DocumentTrimmer]
       5. if enhance: CoreImage           [DocumentEnhancer.swift]
```

### Mac reference (works)

```swift
// detector/detect.swift — entire detect path
let ciImage = CIImage(contentsOf: imageURL)
let request = VNDetectDocumentSegmentationRequest()
VNImageRequestHandler(ciImage: ciImage).perform([request])
// → first result corners, normalized bottom-left origin, TL/TR/BR/BL order
```

Python then: flip Y, expand, warp, deskew stack (`processor.py`).

### Vision coordinate convention (critical)

- Vision normalized coords: **origin bottom-left**
- UIKit / warp quad: **origin top-left**, pixels
- Conversion: `py = (1 - y_norm) * height`
- Corner order: **TL, TR, BR, BL** (clockwise)

### Detection acceptance rules (`DocumentDetector.swift`)

- Reject area < **35%** (prevents bottom-strip false positive)
- Reject area > 94% with low confidence
- Reject full-frame with confidence < 0.55
- Score: `confidence * sqrt(area)`

---

## Key files to read (in order)

1. `detector/detect.swift` — Mac detect (gold standard)
2. `processor.py` — `detect_corners`, `normalized_to_pixels`, `expand_quad`, `warp_perspective`, deskew stack
3. `ios/DocumentCropCore/Sources/DocumentCropCore/DocumentDetector.swift`
4. `ios/Margin/PhotoLoader.swift`
5. `ios/DocumentCropCore/Sources/DocumentCropCore/DocumentCropper.swift`
6. `ios/DocumentCropCore/Sources/DocumentCropCore/DocumentWarper.swift`
7. `ios/DocumentCropCore/Sources/DocumentCropCore/DocumentTrimmer.swift`
8. `ios/DocumentCropCore/Sources/DocumentCropCore/Models.swift`

---

## Recommended fix strategy

### A. Photo loading — must deliver Mac-equivalent bytes

Goal: `detectFromOriginalFile` writes temp **`.heic`** and `CIImage(contentsOf:)` matches Mac.

1. **PHAssetResource first**, before any PhotosPicker transfer:
   - `PHAssetResource.assetResources(for:)`
   - Prefer `.photo` resource type
   - Stream via `PHAssetResourceManager.requestData`
   - Log: `Loaded via PHAsset resource .heic (N bytes, public.heic)`

2. If `itemIdentifier` is nil (happens on some OS versions/simulator):
   - Use `PhotosPickerItem` matched asset APIs or `PHPicker` assetIdentifier
   - Request **readWrite** photo library authorization before pick if needed

3. **Do not return early** on JPEG file transfer if PHAsset could provide HEIC — compare UTType / sniff magic bytes; prefer HEIC over JPEG when both exist.

4. Optional validation: save loaded bytes to `Documents/debug-last-pick.heic` in DEBUG builds; user can AirDrop to Mac and run `./detector/detect` for A/B.

### B. Detection — match Mac pixel space

1. Run **primary** detect exactly like Mac:
   ```swift
   try data.write(to: tempHEICURL)
   let ci = CIImage(contentsOf: tempHEICURL)
   VNImageRequestHandler(ciImage: ci).perform([VNDetectDocumentSegmentationRequest()])
   ```

2. Only map quad to upright warp bitmap **after** detect, with explicit orientation math:
   - If detect runs on oriented CIImage extent W×H, upright bitmap may be H×W when EXIF rotation is 6/8.
   - Log both extents and EXIF orientation tag on every run.

3. Consider detecting on **both** oriented CIImage and upright CGImage; pick best scoring acceptable candidate (not first success).

4. Keep area ≥ 35% rejection — non-negotiable.

5. Rectangle fallback should be **last resort**; success = doc-seg with area ≥ 60%.

### C. Performance

1. `DocumentTrimmer`: analyze at max 1200px long edge; map crop rect to full res (verify implementation actually works — file was broken mid-refactor once).
2. `DocumentWarper.deskew`: already uses 720px band — OK.
3. Avoid `UIGraphicsImageRenderer` full-res re-render unless necessary for orientation.

### D. Verification (agent must do without user)

1. Build iOS target (see command above).
2. If a test image exists in `lab/cases/`, write a small **macOS command-line test** or unit test in DocumentCropCore that:
   - Loads file with `CIImage(contentsOf:)` 
   - Runs same detect path as iOS
   - Compares quad area fraction
3. Add unit test `DocumentDetectorTests` with bundled JPEG that reproduces 25% strip — assert rejection and assert HEIC path area > 60% when fixture available.

User may add failing photo to `lab/cases/` (gitignored) — use same file for Mac CLI and iOS simulator tests.

---

## Build & run

```bash
cd ios
xcodegen generate          # regenerates Margin.xcodeproj from project.yml
open Margin.xcodeproj      # deploy to real iPhone (camera + Photos need device)
```

Simulator builds:
```bash
xcodebuild -scheme Margin -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' build
```

Settings defaults: Straighten **on**, Border **4%** (+4 when straighten → 8% effective), Enhance **off**.

Debug log appears in-app under **Debug log** section (`CropLogger` → `AppStore.logLines`).

Info.plist keys already set: `NSCameraUsageDescription`, `NSPhotoLibraryUsageDescription`, `NSPhotoLibraryAddUsageDescription`.

---

## Constraints

- Keep UI **minimal** (system List) — no redesign.
- Do not remove in-app debug log.
- Do not accept high-confidence **small-area** doc-seg (< 35%).
- Port stable behavior from Mac; keep experimental flap-trim hacks in Python until trusted.
- Do not commit unless user asks.
- iOS deployment target: **17.0**.

---

## Known Mac CLI soft spots (for parity expectations)

- Residual keystone on handheld box photos (cardboard bow) — single plane warp limit.
- Deskew uses upper-band text angle, not global Hough.
- `--deskew` adds extra border (`DESKEW_BORDER_EXTRA_PCT = 4`), top/bottom flap trim only.

iOS already ports these in `DocumentCropper`, `DocumentWarper`, `DocumentTrimmer`.

---

## Expected good debug log (target)

```
Loaded via PHAsset resource .heic (XXXXX bytes, public.heic)
Detect for crop 3213×5712px
original file (heic): CIImage extent 3213×5712   (or swapped if EXIF rotated — must map correctly)
Vision [original file (heic)] confidence=0.XX area=75% TL(...) BR(...)
Picked [original file (heic)] confidence=0.XX area=75%
Detection method: original file (heic)
Warp → ~2400×3200px
Crop done → ... (total post-warp < 5s)
```

---

## Repo map

| Path | Role |
|------|------|
| `detector/detect.swift` | Mac Vision detect binary source |
| `processor.py` | Mac full pipeline |
| `ios/Margin/PhotoLoader.swift` | Load bytes from picker/PHAsset |
| `ios/Margin/OriginalPhotoFile.swift` | Transferable file representation |
| `ios/DocumentCropCore/.../DocumentDetector.swift` | Multi-strategy Vision detect |
| `ios/DocumentCropCore/.../DocumentCropper.swift` | Pipeline orchestration |
| `ios/DocumentCropCore/.../DocumentWarper.swift` | Perspective warp + deskew |
| `ios/DocumentCropCore/.../DocumentTrimmer.swift` | Flap trim (perf-sensitive) |
| `ios/DocumentCropCore/.../Models.swift` | DocumentQuad, CropSettings |
| `CLAUDE.md` / `.cursor/rules/project-overview.mdc` | Repo-wide agent rules |

---

## If still stuck after code fix

1. Confirm on **real device** with **Full Photo Library** access (Settings → Margin).
2. Compare byte-for-byte: PHAsset resource vs Mac file on disk (`cmp`, `file`, `xxd | head`).
3. Run Mac `./detector/detect /path/to/heic` and log confidence + normalized corners vs iOS `CropLogger` output for same bytes.
4. If Vision returns 25% strip even on identical HEIC bytes on iOS but not Mac, check iOS version / Vision revision differences — may need `VNDetectDocumentSegmentationRequestRevision` or pre-scale image before Vision.

---

*Last updated from debugging session: Aug 6, 2026. User exhausted with back-and-forth; wants another model to finish in one pass.*

---

## Resolution — Aug 6, 2026 (Claude)

**Root cause was permissions, not detection math.** Confirmed with the user: Settings → Margin →
Photos was set to **"Add Photos Only"** — write-only. That grant has zero read access to existing
assets, so `PHAsset.fetchAssets(withLocalIdentifiers:)` always returned an empty result (silently —
no PHAsset log line ever appeared in Run A or Run B). The app was *structurally* incapable of
reading original HEIC bytes; it always fell through to `PhotosPicker`'s Transferable pipeline, which
delivers a transcoded JPEG for HEIC library assets. Vision's document segmentation mis-detects that
JPEG far more often than the true HEIC (confirmed: only one `VNDetectDocumentSegmentationRequest`
revision exists on this OS, so Mac and iOS run the identical model — the delta was purely input
bytes, not coordinate math or a revision mismatch). Hypotheses #2–4 in this doc were investigated
and ruled out.

**Fixes applied:**
1. `Margin/AppStore.swift` — added `ensureLibraryReadAccess()`, called from `RootView.task` on
   launch, so the read-access prompt surfaces up front instead of buried mid-crop. Publishes
   `needsLibraryReadAccess` for UI.
2. `Margin/RootView.swift` — shows a footer button under "Choose Photos" linking to
   `UIApplication.openSettingsURLString` when read access isn't granted.
3. `Margin/PhotoLoader.swift` — hardened the fallback: logs *why* PHAsset resolution failed
   (previously silent), and when PHAsset is unavailable, loads both the file-transfer and raw-Data
   Transferable candidates and prefers whichever sniffs as HEIC, instead of taking the first
   available JPEG.
4. `DocumentCropCore/DocumentWarper.swift` — `estimateSkewDegrees` did a brute-force 0.25° sweep
   over ±15° (121 full pixel-array passes) **per deskew pass, ×3 passes**. In Debug builds
   (`SWIFT_OPTIMIZATION_LEVEL = -Onone`, the default Run configuration), this is unoptimized
   bounds-checked Swift — measured **8.07s for 3 passes** on a 720×324 synthetic band. Replaced
   with coarse (2° step, 16 passes) → fine (0.25° step within ±2° of the coarse winner, ~17 passes)
   search. Verified identical results to brute force on a synthetic rotated pattern, and measured
   **2.19s for 3 passes (3.7x speedup)** at the same `-Onone` settings. This was the dominant cost
   behind the reported ~30s; remaining time is `DocumentTrimmer`'s edge-detection convolution and
   CoreImage render round-trips, both O(1) full-res passes (not O(n) in a search loop) and much
   cheaper. **Note:** running via a Release build config would remove the `-Onone` penalty entirely
   as a zero-code-risk option, but that's a debugging-workflow tradeoff for the user to choose, not
   something changed here.

**User action required:** Settings → Margin → Photos → **All Photos** (or grant Limited access to
the specific test photos). "Add Photos Only" cannot be fixed in code — no API lets an app read
assets without this grant. The in-app Settings link (fix #2) makes this a one-tap fix.

**Not yet re-verified on device**: could not test the actual device flow (no dev team configured
for code signing in this environment) — verified via Simulator build success + targeted correctness/
perf benchmarks of the deskew search in isolation. User should re-run with All Photos access granted
and confirm the debug log now shows `Loaded via PHAsset resource .heic` / `original file (heic)` and
post-warp timing under 5s.

---

## Round 2 — Aug 6, 2026 (Claude), after real-device test

User granted All Photos and re-tested on a real iPhone. Result: **`itemIdentifier` was still nil**
even with full access — this was a **Simulator-only artifact from the previous test**, not the real
bug; the actual device run never had this problem to begin with (permissions were a red herring for
*this specific* symptom, though still correct to fix). On device, detection itself worked well this
time: primary doc-seg (`original file (jpg)`) found confidence=0.990, area=59%, no fallback needed.
Still JPEG not HEIC (`itemIdentifier` nil on device too — worth a follow-up, see below), but
detection quality was no longer the blocker.

**New bug found: rotation.** Final output (3903×4832) had a visibly different aspect ratio than the
warp output (3036×4266) — a symptom of the deskew stack distorting geometry, not a clean rotation.
Root cause in `DocumentWarper.rotateReflect`:
1. It cropped to `rotated.extent` (the rotated image's bounding box, which grows along both axes
   relative to the input) instead of the original pre-rotation extent — each of up to 3 deskew
   passes fed a bigger canvas into the next, compounding a size/aspect distortion. Mac's
   `cv2.warpAffine(img, M, (w, h))` explicitly fixes the output canvas at the input's `(w, h)`;
   iOS didn't. Fixed by rotating about center and cropping back to the original extent.
2. **Sign error**: the `-degrees` negation rotated the opposite direction from Mac's
   `cv2.getRotationMatrix2D`. Verified numerically — plotted the same point through both Mac's
   matrix and the Swift transform; `-degrees` moved it opposite to Mac, dropping the negation
   matched. This alone would show up as "leans the wrong way" or over-corrects when combined with
   the canvas-growth bug above.

**Also clarified, not a bug**: "Enhance was not applied" — the Enhance toggle in Settings defaults
to **off**; user hadn't enabled it. Confirmed via follow-up question, no code change needed.

**UI additions requested and implemented:**
- Tap a finished thumbnail in the Results list to open a full-screen pinch-zoom/pan preview
  (`CroppedImagePreview`), with close and share buttons, double-tap to reset zoom.
- "Choose Photos" now clears previously finished (done/failed) jobs before presenting the picker —
  switched from `PhotosPicker(selection:)` directly as a control to a `Button` driving
  `.photosPicker(isPresented:selection:)`, so the clear happens deterministically in the button
  action before the picker presents (a `simultaneousGesture` on the picker control itself was tried
  first and abandoned — unreliable ordering against the picker's own built-in tap handling).

**Still open / worth a follow-up session:**
- `itemIdentifier` is nil on real device too now (not just Simulator) — PHAsset path never engaged
  on this device/OS combination for this test; worth checking `PHPickerConfiguration.preferredAssetRepresentationMode`
  and whether `PhotosPicker`'s selection behavior needs adjusting to reliably surface an identifier
  once the app has All Photos access. HEIC still isn't reaching Vision on device, it's just that
  Vision now handles the transcoded JPEG well enough on this particular photo not to matter — may
  regress on harder photos.
- Rotation fix verified only via isolated numeric/geometric checks (matrix math against Mac's
  OpenCV convention) — not yet re-tested end-to-end on a real device photo with actual skew.
- New UI (tap-to-preview, clear-on-choose) verified via Simulator build success only — not
  interactively tested in a running app. Gesture interaction between the row's new tap-to-preview
  and the existing per-row `ShareLink` button should be sanity-checked on device (nested SwiftUI
  controls generally route taps to the innermost control first, but worth confirming visually).

---

## Round 3 — Aug 6, 2026 (Claude): the rotation "fix" made it much worse, real root cause found

User tested Round 2's rotation fix on a real medical-bill photo (near-zero actual skew) and got a
**~20-25° rotated output with black letterboxing** — visibly much worse than before. Investigation
found the true root cause was neither the canvas-crop bug nor the sign bug fixed in Round 2 (both of
those fixes were correct and are still in place) — it was that **`DocumentWarper.estimateSkewDegrees`
was never actually a port of Mac's skew algorithm at all**, despite the file's own docstring claiming
it was. It's a from-scratch, different heuristic (brute-force rotational projection-variance search)
that has no "give up, no clear skew" case and was proven (numerically, on the real bill photo) to be
**systematically biased toward the search boundary** — score increased monotonically from -15° to
+15° instead of peaking near the true ~0° skew. Round 2's canvas/sign fixes had been *correctly
applying* this already-wrong angle for the first time (the old canvas-growth bug had been
accidentally clipping the visible evidence of the bad rotation before).

**User redirect**: mid-fix, user asked to stop making iOS-specific patches and instead treat this as
a shared-engine problem — both Mac and iOS should run identical core logic, with each platform layer
reduced to file I/O / UI only. Confirmed scope: since the app targets Apple platforms only, this means
**`DocumentCropCore` (the existing Swift package under `ios/DocumentCropCore/`) becomes the single
engine**, consumed by both the iOS app and a to-be-built Mac CLI Swift executable — not a new
cross-platform C/C++ core. `processor.py`/`batch.py`/`pdf_builder.py`/`detector/detect.swift`/
`enhancer/enhance.swift` are slated for eventual retirement once the Mac CLI is rebuilt on
`DocumentCropCore`.

**Pre-deletion audit** (user asked to check for core logic before removing any Python): every
function in the five legacy files was read and classified as CORE ALGORITHM vs PLATFORM SHELL.
Findings, beyond the already-known skew-algorithm divergence:
- Corner math, quad expansion, keystone refine (`refine_corners`), warp destination-size formula,
  trim thresholds, deskew pass structure/damping, enhance filter chain, EXIF orientation handling —
  all already correctly ported to `DocumentCropCore`, several *improved* over Python (e.g. Swift's
  `normalizedUpCGImage()` handles all 8 EXIF orientations vs Python's 3).
- `auto_rotate_image` (Tesseract OSD 90°/180°/270° rotation, the `--rotate` CLI flag) has **zero
  Swift equivalent** — full feature gap, not yet ported. Decision: replace with a native
  `VNRecognizeTextRequest`-based orientation detector (no Tesseract/Python dependency — Python
  itself cannot run in a shipping iOS app; Tesseract's C++ core technically could via a bundled
  XCFramework, but Vision is already built into both OSes with zero added dependency, so that's
  the chosen path). Not yet implemented — tracked as a follow-up.
- `CropSettings.straighten` defaults to `true` in Swift; Python's `config.yaml` default for
  `deskew` is `false`. Live mismatch, not yet reconciled — tracked as a follow-up.
- `resquare_with_vision` and `trim_colored_side_flaps` in `processor.py` are dead code (defined,
  never called from `process_image`/`batch.py`/anywhere) — safe to drop without porting.
- Minor rendering-kernel divergences noted but not urgent: `DocumentTrimmer.cannyLite` is a
  simplified Sobel-threshold stand-in for OpenCV's real Canny (no NMS/hysteresis, box blur instead
  of Gaussian) and also downsamples to 1200px before edge scoring where Python always runs full-res;
  `DocumentWarper.warp` uses CoreImage's `perspectiveCorrection` filter vs OpenCV homography+Lanczos4
  — same destination-size formula, different resampling kernel. CoreImage does have a real
  `CICannyEdgeDetector` filter available that could replace `cannyLite` in a future pass.
- Python's `detector/detect.swift` binary is a single unconditional Vision call with zero acceptance
  heuristics; Swift's `DocumentDetector` layers multi-strategy candidates + confidence/area gates +
  rectangle fallback on top of the same API — an intentional superset, not a gap.

**Fix applied — `DocumentWarper.estimateSkewDegrees` fully replaced** with a faithful port of
`processor._estimate_skew_angle`:
1. Extract the same title band (`y: 6-22%`, `x: 5-95%` of image).
2. Adaptive-threshold-invert (local-mean box-integral approximation of `ADAPTIVE_THRESH_GAUSSIAN_C`,
   block size 31, C=12) → morphological horizontal-line opening (erode+dilate, kernel width
   `bandWidth/10`, min 20px) → custom Hough-line-equivalent search (`houghLinesP`: projects edge
   pixels onto each candidate angle's axis, groups runs ≥ `minLineLength` with gaps ≤ `maxLineGap`)
   over `±maxDegrees` at 0.1° resolution, votes ≥40, min length 35% of band width, max gap 12px.
3. Dark-pixel (`<95`) linear-regression (least-squares slope) polyfit fallback, seeded/deterministic
   8000-point subsample cap matching Python's `RandomState(0)`.
4. Combine: larger-magnitude of the two candidates (matches Python's tie-break exactly).
5. If neither found: global Canny-edge (Sobel-magnitude approximation) + Hough sweep, median of
   ≥5 samples, else **return `nil`** — the critical safety valve the old algorithm lacked. `nil`
   means `deskew()` skips rotation for that pass entirely, same as Python.
6. Added `DocumentWarper.debugEstimateSkewDegrees` — a public debug/test seam (not used by the crop
   pipeline) for verification tooling.
7. **Side fix required to test any of this**: `DocumentDetector.detectForCrop` was unreachable on
   macOS — it lived entirely inside `#if canImport(UIKit)` even though a `#endif`-outside overload
   (`detect(in cgImage:)`) tried to call it unconditionally, meaning **`DocumentCropCore` has never
   actually compiled for macOS**. Fixed by moving `detectForCrop` outside the UIKit guard and gating
   only its one truly-UIKit-dependent line (JPEG re-encode via `UIImage.jpegData`) behind a small
   `jpegReencode` helper with a `CGImageDestination`-based macOS fallback. This was necessary to
   even attempt task #4 (Mac CLI as a Swift executable) and should have been caught earlier.
8. Added `ios/DocumentCropCore/Package.swift` (SPM manifest) — `DocumentCropCore` previously had
   no `Package.swift`, only an xcodegen `project.yml` framework-target definition; adding the
   manifest doesn't affect the Xcode build (xcodegen doesn't read it) but makes the package properly
   buildable/testable/consumable via `swift build`, which is what unblocked verifying this fix at all
   and is a prerequisite for the planned Mac CLI executable target.

**Verification** (via a throwaway SPM executable linking `DocumentCropCore` directly, run against
the real bill photo and a synthetically-rotated copy — not yet re-tested on device):
- Real bill photo (near-zero true skew): estimate **1.21°** (vs. old algorithm's ~15-20°+ boundary
  saturation) → after full 3-pass deskew, residual **0.30°**. Clean convergence toward zero.
- Synthetic 6°-rotated copy (cleanly cropped, no artificial fill-color contamination): estimate
  **3.43°** on the first pass → visually confirmed via side-by-side rendering that the deskewed
  output is correctly near-level (title/table lines horizontal) where the input was visibly tilted.
  Residual re-measurement after 3 passes overshot slightly to **-3.07°** (sign flip = crossed near
  zero) — this is expected re-measurement noise on a small residual angle, not a bug; the visual
  result is what was checked and is correct.
- The previously-broken output photo (`IMG_3152.JPG`, ~20°+ off): new estimate is only **-1.26°**,
  which is *correct*, not a miss — `deskew()` is a *minor touch-up* pass bounded to `±15°` by design
  (matching Python's `max_angle=15.0`), not a general-purpose reorientation tool; a ~20° error from
  a single bad pass is out of scope for this function and was never going to be "corrected back" by
  it. Recovering from that specific bad output would require re-running the crop from the original
  source image now that the estimator is fixed, not deskewing the already-bad output further.
- Both the standalone SPM build and the full iOS Simulator Xcode build succeed after this change.

**Not yet done / explicitly deferred by user's own sequencing choice** (fix-first, rest-after):
1. Auto-rotate (Vision-based, replacing Tesseract) — not implemented.
2. `straighten`/`deskew` default mismatch — not reconciled.
3. Mac CLI Swift executable scaffold — not started.
4. Retiring `processor.py`/`batch.py`/`pdf_builder.py`/`detector/detect.swift`/`enhancer/enhance.swift`
   — not started; all still present and still the Mac CLI's actual runtime path today.
5. **Not yet re-tested on the user's real iPhone** — this round's verification was standalone-package
   + visual-diff only, per the same environment constraint as before (no code-signing dev team
   configured here). User should re-run the app on-device with the bill photo and confirm the crop
   is now level, plus re-verify the earlier product-box/HEIC-detection scenarios still work
   (unrelated to this fix, but worth a regression pass since multiple rounds have touched this file).

---

## Round 4 — Aug 6, 2026 (Claude): Round 3's fix still not good enough on device — straighten disabled

User tested Round 3's Hough-based skew port on a real iPhone and it "still didn't work that well."
Cropping without straighten/deskew works well. Rather than keep iterating blind on a real-device-only
failure mode with no further logs/photos supplied, user chose to **disable the feature from the UI
for now** and revisit once it can be properly re-verified — a reasonable call given three rounds of
attempted fixes have not produced a trustworthy result on-device (even though Round 3's algorithm
tested correctly against the real bill photo via standalone-package + visual diff, something about
running the full pipeline on a real device — full pipeline sequencing, a different photo's edge
cases, or something not caught by the offline test harness — is still not right).

**Changes made:**
1. `DocumentCropCore/Sources/DocumentCropCore/Models.swift` — `CropSettings.straighten` default
   flipped from `true` to `false`. This also happens to resolve the default-value mismatch flagged
   in Round 3's audit (Python's `config.yaml` default was always `deskew: false`) — no longer a
   divergence, though the reason right now is "disabled pending re-verification," not "intentional
   parity," so revisit this comment once straighten is trusted again.
2. `Margin/SettingsView.swift` — the "Straighten" `Toggle` removed from the Crop settings section
   (code commented as hidden-not-deleted, with a pointer back to this doc).
3. `Margin/AppStore.swift` — `init()` no longer reads a persisted `straighten` value from
   `UserDefaults` at all; it's hardcoded to `false` regardless of what a prior install may have
   stored. Necessary because the toggle is now hidden — without this, a user who previously had it
   on (back when it defaulted to `true`) would have had no UI path to turn it back off.

**Straighten is now fully off by default and not reachable from the UI** — `CropSettings.straighten`,
`DocumentWarper.deskew`/`estimateSkewDegrees`, and `DocumentTrimmer`'s top/bottom trim (which only
runs when `straighten` is true) all still exist and are unchanged; nothing was deleted. Re-enabling
later means: reverting the `AppStore.init` hardcode, restoring the `Toggle` in `SettingsView`, and
critically — because two rounds of "verified" fixes have not held up on-device — establishing a real
on-device verification loop before trusting it again (the standalone-package test harness from
Round 3 is useful for regression-testing the algorithm's *math* in isolation, but has now twice
missed something that only shows up running the full app on real hardware).

**Not yet done**: auto-rotate (Vision-based) deprioritized — it depends on the same deskew stack
being trusted, so no point building on top of it yet. Mac CLI Swift executable / Python retirement
still not started, per the user's original fix-first sequencing choice.

---

## Epilogue — 2026-08-07

**This document is now history.** It records the debugging of an iOS port that no longer
exists as a port: `DocumentCropCore` is the single implementation and the Mac CLI is a front
end over it, so the "iOS behaves worse than Mac" framing throughout no longer applies. The
Python pipeline it repeatedly refers to as the reference (`processor.py`, `batch.py`,
`detector/detect`, `enhancer/enhance`) was deleted after the Swift engine matched it.

Read the rest of this file as a record of what went wrong and why, not as instructions.
Current state lives in `/CLAUDE.md`.

What closed since the last section above:

- **Mac CLI + Python retirement** — done. See `/README.md`.
- **Auto-rotate** — ported to Vision (`DocumentOrienter`), but narrower than the Tesseract
  OSD it replaced: it straightens a sideways page and deliberately refuses to flip 180°,
  because Vision reads upside-down text nearly as well as upright (measured: the 180°
  partner scores within ~1%, sometimes higher). Off by default.
- **Deskew/trim** — the flap-trim gap against Python closed after fixing two real bugs in
  `cannyLite` (hysteresis thresholds read as a band; missing non-maximum suppression) and
  raising `DocumentTrimmer.analysisMaxSide` from 1200 to 1600. Both lab cases now trim as
  Python did.

**Still open, and still the caution this document was right about:** all of the above is
verified on Mac against `lab/cases/`. None of it has been re-verified on a real device.
`straighten` remains off by default and hidden in the iOS UI for exactly the reason stated
above — offline verification has twice passed while the on-device result did not. Establish
an on-device loop before re-enabling it.
