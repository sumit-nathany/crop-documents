# Document Auto-Crop & PDF Bundle Tool (macOS + iOS)

A local tool for macOS and iOS that automatically detects, crops, and de-skews photos of documents, receipts, bills, and cards. It preserves a natural background margin so they look like well-framed photos rather than sterile scans, and can bundle them into PDFs.

The Mac CLI and the iPhone app share one engine — the `DocumentCropCore` Swift package — so a change to detection, warping, or trimming lands on both platforms at once. Each front end only picks files and shows results.

```
                    ┌──────────────────────┐
   Mac CLI ────────▶│  DocumentCropCore    │
   (crop-documents) │  detect → warp →     │
                    │  align → rotate →    │
   iPhone app ─────▶│  enhance → save      │
   (ios/Margin)     └──────────────────────┘
```

---

## Features

- 🧠 **ML-Based Detection**: Uses Apple's native on-device **Vision Framework** (`VNDetectDocumentSegmentationRequest`) for high-accuracy quadrilateral segmentations.
- 🖼️ **Natural Border**: Instead of drawing artificial colored borders, the tool pushes the crop boundary outward from the document's center (by a configurable %). This preserves a sliver of the actual background (table surface, hands, etc.) to look natural.
- 📐 **Perspective Correction & No Aspect Ratio Limits**: De-skews papers shot at an angle, automatically adjusting the output shape to match the document's true proportions (long receipts, square cards, landscape documents, etc.).
- 🔄 **Auto-Rotation (opt-in)**: After cropping, uses Vision text recognition to straighten a sideways page. It deliberately does *not* flip 180° — Vision reads upside-down text nearly as well as upright text, so that call would be a coin toss (see `DocumentOrienter`).
- ✨ **Apple Photos Auto-Enhancement (`--enhance`)**: Leverages Apple's native CoreImage `autoAdjustmentFilters` (exposure, contrast, tone curves, color balance).
- 📦 **Zero runtime dependencies**: No Python, OpenCV, Tesseract, or `img2pdf`. Everything is Vision, CoreImage, and CoreGraphics.
- 🍏 **Native HEIC/HEIF Support**: Directly handles photos taken with your iPhone, saving them as high-quality JPEGs.
- 📂 **Auto Folder Watcher**: Background agent monitors a directory and auto-processes incoming pictures.
- 📄 **Lossless PDF Generation**: Merges crops into custom PDFs, fitting each page exactly to the image's dimensions.

---

## Setup

Requires **macOS 13+ (Ventura)** and Xcode Command Line Tools. Nothing else.

```bash
cd crop-documents
./build-cli.sh
```

That builds `./crop-documents` (release mode — the pixel loops are ~10x slower
unoptimized). To use it from anywhere:

```bash
sudo ln -sf "$PWD/crop-documents" /usr/local/bin/
```

---

## Usage

Run all commands from the root of the project directory.

### 1. Batch Processing / Single Crop
If you omit the `--output` parameter, the cropped images will automatically be saved in the same directory as the input files. If you omit the `--input` parameter, it defaults to the current working directory.

```bash
# Crop all images in the current folder
./crop-documents

# Crop images in a specific directory
./crop-documents --input ~/Downloads/Receipts/

# Crop a single file
./crop-documents --input ~/Downloads/Receipts/receipt_01.heic

# Crop and save to a custom output directory
./crop-documents --input ~/Downloads/Receipts/ --output ./cropped_results/
```

### 2. Adjusting the Border Context
You can control the natural background border via the `--expansion` (`-e`) flag (as a percentage of the document size). Default is `4.0`.
```bash
# Get a wider natural background border (e.g., 6% padding)
./crop-documents --expansion 6.0

# Crop tightly to the detected document edges (0% padding)
./crop-documents --expansion 0.0
```

### 3. Automatically Watch a Folder (`--watch`)
Monitors a folder in the background. Dropping new photos here auto-crops them into the output directory:
```bash
./crop-documents --input ~/Desktop/ScansInbox/ --output ~/Desktop/Processed/ --watch
```
*To stop the watcher, press `Ctrl+C` in your terminal.*

### 4. Bundling to PDF
You can output crops directly into a single PDF, or compile pre-cropped images:

**Crop and bundle in one command:**
```bash
./crop-documents --input ~/Downloads/Bills/ --pdf final_bills.pdf
```
*(Creates `final_bills.pdf` inside the output directory containing all successfully processed documents).*

**Bundling images that are already cropped:**
```bash
# Point at the folder with --expansion 0 to pass them through, or use the
# legacy standalone builder:
python3 pdf_builder.py ./cropped_results/ --output ~/Desktop/monthly_report.pdf
```

### 5. Alignment (`--deskew`)

Fixes keystone, micro-rotation, and open flaps (top/bottom). Use this for handheld photos:

```bash
./crop-documents --input ~/Downloads/Receipts/ --deskew

# Align + straighten sideways pages
./crop-documents --input ~/Downloads/Receipts/ --deskew --rotate
```

> **Note:** Deskew fills empty corner triangles from rotation by mirroring the natural background padding.
>
> **Status:** the Swift port of the flap trim is not yet at full parity with the
> Python pipeline — it is more conservative and can leave a flap Python would trim.
> See "Why the Python CLI is still here" below.

### 6. Auto-Rotation (`--rotate` / `-r`)
When a page is photographed sideways, `--rotate` straightens it **after** cropping using Vision text recognition:

```bash
# Crop + straighten sideways pages
./crop-documents --input ~/Downloads/Receipts/ --rotate

# Combine with PDF export
./crop-documents --input ~/Downloads/Bills/ --rotate --pdf bills.pdf
```

> **Scope: sideways pages only — this does not flip 180°.**
> The orienter reads text at each quarter turn and keeps the best-scoring one.
> Measured on rotated fixtures, the correct *axis* wins by more than 10x, but the
> 180° partner scores within ~1% and is sometimes *higher* — Vision reads
> upside-down text nearly as well as upright text. Rather than coin-flip on a very
> visible error, it corrects the axis and leaves flips alone. If nothing reads
> confidently, the image is left untouched.

To see the decision without cropping anything:

```bash
./crop-documents probe-orientation ~/Downloads/Receipts/*.jpg
```

### 7. Apple Photos Auto-Enhancement (`--enhance` / `-a`)
Applies Apple's native CoreImage `autoAdjustmentFilters` (the exact same engine used by Apple Photos / iOS Photos app) to balance exposure, contrast, tone curves, and colors:

```bash
# Crop + apply Apple Photos auto-enhancement
./crop-documents --input ~/Downloads/Receipts/ --enhance

# Combine crop, deskew, auto-rotate, and auto-enhance into PDF
./crop-documents --input ~/Downloads/Receipts/ --deskew --rotate --enhance --pdf bundle.pdf
```


---

## Configuration

The Swift CLI takes its settings from flags, with the same defaults `config.yaml`
documented (`--expansion 4`, deskew/rotate/enhance all off). `config.yaml` is still
read by the legacy Python pipeline in `lab/`.

```bash
./crop-documents --expansion 6 --jpeg-quality 0.9 --input ./photos/
```

---

## Project Structure

```
crop-documents/
├── build-cli.sh                        # Builds ./crop-documents (release)
├── ios/
│   ├── DocumentCropCore/               # THE ENGINE — shared by CLI and app
│   │   ├── Sources/DocumentCropCore/   #   detect, warp, trim, orient, enhance, IO, PDF
│   │   ├── Sources/CropDocumentsCLI/   #   Mac front end (args, file walk, console)
│   │   └── Tests/                      #   swift test
│   ├── Margin/                         # iPhone front end (SwiftUI)
│   └── Margin.xcodeproj                # Generated — re-run xcodegen after adding files
├── lab/                                # Deskew/rotation regression harness (Python)
├── legacy Python CLI ────────────────  # Reference implementation, still runnable
│   ├── batch.py  processor.py  pdf_builder.py
│   ├── detector/detect.swift  enhancer/enhance.swift
│   ├── config.yaml  setup.sh  requirements.txt
├── CLAUDE.md                           # Agent context (Claude Code)
├── .cursor/rules/                      # Agent context (Cursor)
└── README.md
```

### Why the Python CLI is still here

The Swift CLI reproduces the default crop path exactly — same detections, same
output dimensions, same confidences, with pixel differences only at high-gradient
edges (Lanczos vs CoreImage resampling).

`--deskew` is not yet at full parity. On the lab set, one image matches Python
exactly and the other keeps a flap that Python trims. Swift errs conservative
there, which is the safe direction, but it is a real gap — and `processor.py` is
the only ground truth for closing it. Keeping deskew development in Python against
`lab/` is the project's stated priority, so the reference implementation stays
until the port is verified.

### iPhone app (Margin)

```bash
cd ios && xcodegen generate && open Margin.xcodeproj
```

Pick or capture photos → crop → save to Photos. See [ios/README.md](ios/README.md).

### Pipeline lab (deskew / rotation)

Drop hard photos into `lab/cases/`, then:

```bash
python3 lab/run_regression.py
python3 lab/run_regression.py --variants crop,deskew
```

CLI:

```bash
./crop-documents --input ./photos/ --deskew
```

See [lab/README.md](lab/README.md).
