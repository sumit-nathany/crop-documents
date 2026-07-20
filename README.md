# Document Auto-Crop & PDF Bundle Tool (macOS)

A high-performance, local command-line utility for macOS to automatically detect, crop, and de-skew pictures of documents, receipts, bills, and cards. It preserves a natural background margin so they look like well-framed photos rather than sterile scans, and can automatically bundle them into custom PDFs.

---

## Features

- 🧠 **ML-Based Detection**: Uses Apple's native on-device **Vision Framework** (`VNDetectDocumentSegmentationRequest`) for high-accuracy quadrilateral segmentations.
- 🖼️ **Natural Border**: Instead of drawing artificial colored borders, the tool pushes the crop boundary outward from the document's center (by a configurable %). This preserves a sliver of the actual background (table surface, hands, etc.) to look natural.
- 📐 **Perspective Correction & No Aspect Ratio Limits**: De-skews papers shot at an angle, automatically adjusting the output shape to match the document's true proportions (long receipts, square cards, landscape documents, etc.).
- 🔄 **Auto-Rotation (opt-in)**: After cropping, uses Tesseract OSD to detect and correct documents that are rotated 90°, 180°, or 270°. Skips gracefully when confidence is low or Tesseract is not installed.
- 🍏 **Native HEIC/HEIF Support**: Directly handles photos taken with your iPhone, saving them as high-quality JPEGs.
- 📂 **Auto Folder Watcher**: Background agent monitors a directory and auto-processes incoming pictures.
- 📄 **Lossless PDF Generation**: Merges crops into custom PDFs, fitting each page exactly to the image's dimensions.

---

## Setup & Prerequisites

This tool requires **macOS 13+ (Ventura)** or later and Xcode Command Line Tools.

1. **Clone & Setup**:
   ```bash
   cd crop-documents
   chmod +x setup.sh
   ./setup.sh
   ```
   *Note: This script compiles the Swift native binary (`detector/detect`) and installs Python dependencies (`opencv-python`, `pillow`, `pillow-heif`, `img2pdf`, `watchdog`, `pyyaml`, `numpy`).*

2. **(Optional) Auto-Rotation** — install Tesseract if you want `--rotate` support:
   ```bash
   brew install tesseract
   pip install pytesseract
   ```

---

## Usage

Run all commands from the root of the project directory.

### 1. Batch Processing / Single Crop
If you omit the `--output` parameter, the cropped images will automatically be saved in the same directory as the input files. If you omit the `--input` parameter, it defaults to the current working directory.

```bash
# Crop all images in the current folder
python3 batch.py

# Crop images in a specific directory
python3 batch.py --input ~/Downloads/Receipts/

# Crop a single file
python3 batch.py --input ~/Downloads/Receipts/receipt_01.heic

# Crop and save to a custom output directory
python3 batch.py --input ~/Downloads/Receipts/ --output ./cropped_results/
```

### 2. Adjusting the Border Context
You can control the natural background border via the `--expansion` (`-e`) flag (as a percentage of the document size). Default is `4.0`.
```bash
# Get a wider natural background border (e.g., 6% padding)
python3 batch.py --expansion 6.0

# Crop tightly to the detected document edges (0% padding)
python3 batch.py --expansion 0.0
```

### 3. Automatically Watch a Folder (`--watch`)
Monitors a folder in the background. Dropping new photos here auto-crops them into the output directory:
```bash
python3 batch.py --input ~/Desktop/ScansInbox/ --output ~/Desktop/Processed/ --watch
```
*To stop the watcher, press `Ctrl+C` in your terminal.*

### 4. Bundling to PDF
You can output crops directly into a single PDF, or compile pre-cropped images:

**Crop and bundle in one command:**
```bash
python3 batch.py --input ~/Downloads/Bills/ --pdf final_bills.pdf
```
*(Creates `final_bills.pdf` inside the output directory containing all successfully processed documents).*

**Standalone compilation of pre-cropped images:**
```bash
# Merge an entire directory of images
python3 pdf_builder.py ./cropped_results/ --output ~/Desktop/monthly_report.pdf

# Merge specific images manually
python3 pdf_builder.py file1.jpg file2.png file3.jpg --output ~/Desktop/bundled.pdf
```

### 5. Alignment and Micro-Deskew (`--deskew`, `--refine-corners`)
Documents photographed at awkward angles may suffer from keystone distortion or slight rotational tilt, even after being cropped. You can correct these geometrically:

```bash
# Correct keystone distortion (non-parallel top/bottom edges)
python3 batch.py --input ~/Downloads/Receipts/ --refine-corners

# Fine-tune micro-rotation (deskew text lines horizontally)
python3 batch.py --input ~/Downloads/Receipts/ --deskew

# Apply both alignment fixes simultaneously
python3 batch.py --input ~/Downloads/Receipts/ --deskew --refine-corners
```

> **Note:** The `--deskew` flag seamlessly fills any empty corner triangles introduced by the rotation by mirroring the document's natural background padding, ensuring no text is cut off.

### 6. Auto-Rotation (`--rotate` / `-r`)
When a document is photographed rotated (e.g. sideways or upside-down), use `--rotate` to let Tesseract detect and fix the orientation **after** cropping:

```bash
# Crop + auto-rotate using Tesseract OSD
python3 batch.py --input ~/Downloads/Receipts/ --rotate

# Combine with PDF export
python3 batch.py --input ~/Downloads/Bills/ --rotate --pdf bills.pdf

# Adjust OSD confidence threshold (default 1.0; lower = more aggressive)
python3 batch.py --input ./photos/ --rotate --rotate-confidence 0.5
```

> **Requires:** `brew install tesseract` and `pip install pytesseract`  
> If Tesseract is not installed, the step is silently skipped — no crash.

---

## Configuration

You can tweak the default settings globally inside `config.yaml`:

```yaml
# Default border expansion percentage
expansion_pct: 4.0

# Output folder fallback
output_dir: "./output"

# Output JPEG quality (60-100)
jpeg_quality: 95

# Auto-rotation via Tesseract OSD (opt-in; requires tesseract + pytesseract)
auto_rotate: false
rotate_confidence: 1.0   # 0.0–∞, higher = more conservative
```

---

## Project Structure

```
crop-documents/
├── detector/
│   ├── detect.swift   # Swift script calling Apple Vision Framework
│   └── detect         # Compiled native Swift binary (macOS execution)
├── batch.py           # CLI runner (Watch, Batch, PDF flags)
├── processor.py       # Image processing, perspective warp, and HEIC loader
├── pdf_builder.py     # Lossless PDF assembler using img2pdf
├── config.yaml        # Default global configurations
├── setup.sh           # Automatic compile and environment bootstrap script
├── requirements.txt   # Python dependency list
├── lab/               # Deskew/rotation regression cases + runner
├── CLAUDE.md          # Agent context (Claude Code)
├── .cursor/rules/     # Agent context (Cursor)
└── README.md          # Project documentation
```

### Pipeline lab (deskew / rotation)

Drop hard photos into `lab/cases/`, then:

```bash
python3 lab/run_regression.py
```

See [lab/README.md](lab/README.md). Prefer fixing deskew/rotation here before any iPhone port.
