# CLAUDE.md — crop-documents

## What this is

Local **macOS CLI** to auto-detect and crop document photos (receipts, bills, cards) with a natural background margin, optional deskew/rotation, and PDF bundling. Apple Vision for quads; Python/OpenCV for warp and post-process.

## Quick start

```bash
./setup.sh                          # compile detector/detect + pip deps
python3 batch.py --input ./photos/  # crop in place (or --output DIR)
python3 batch.py --input ./photos/ --deskew --rotate --pdf out.pdf
```

Optional rotate: `brew install tesseract` and `pip install pytesseract`.

## Architecture

```
image → detector/detect (Vision JSON) → processor.py
         → expand → warp → [--deskew align stack] → [--rotate OSD] → save
batch.py orchestrates; pdf_builder.py merges crops; config.yaml defaults.
```

| File | Responsibility |
|------|----------------|
| `detector/detect.swift` | Vision segmentation → JSON corners |
| `processor.py` | Full image pipeline |
| `batch.py` | CLI entry (batch / watch / pdf) |
| `pdf_builder.py` | img2pdf assembler |
| `lab/` | Regression cases + runner for deskew/rotate work |

Vision coords: normalized, origin bottom-left, order TL,TR,BR,BL. Python flips Y for OpenCV.

## Product / agent priorities

1. **Keep fixing deskew & rotation in Python** (`processor.deskew_image`, `auto_rotate_image`) using `lab/`.
2. **iPhone app is the ship target** (native Swift later). Mac GUI deferred.
3. Do **not** port the CV pipeline to Swift or scaffold Xcode apps until the user asks and CLI quality is good enough.
4. Prefer small, flag-compatible changes; soft-skip when Tesseract is absent.

## Known soft spots

- `--deskew` is a conservative align stack (refine, upper-band deskew, top/bottom flap trim). Vision re-square / color-flap trim are off by default.
- Residual **perspective / cardboard bow** on handheld box photos cannot be fully removed by one plane warp.
- OSD auto-rotate depends on Tesseract confidence; 90°/270° must use negated PIL angle.

## Regression

Put hard photos in `lab/cases/` (gitignored images OK). Run:

```bash
python3 lab/run_regression.py
```

See `lab/README.md`.
