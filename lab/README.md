# Pipeline lab (deskew / rotation)

Use this folder to iterate on **alignment** and **auto-rotate**. The Mac Python CLI remains the source of truth.

## Layout

```
lab/
├── cases/          # Drop hard photos here (HEIC/JPEG/PNG). Not committed by default.
├── out/            # Regression outputs (gitignored)
├── run_regression.py
└── README.md
```

## Add cases

Copy failing or borderline shots into `lab/cases/`. Prefer a mix of:

- Sideways / upside-down pages (`--rotate`)
- Slight tilt / keystone after a good crop (`--deskew`)
- Open flaps, stray paper, colored box edges
- Sparse receipts, dark tables, hands in frame

## Run

From the repo root (requires `./setup.sh` already done):

```bash
python3 lab/run_regression.py

# Subset
python3 lab/run_regression.py --variants crop,deskew

# Custom expansion
python3 lab/run_regression.py --expansion 4.0
```

CLI equivalent:

```bash
python3 batch.py --input lab/cases/ --output lab/out/manual/ --deskew
```

## Flags (keep it simple)

| Flag | Meaning |
|------|---------|
| *(none)* | Crop only |
| `--deskew` | Align: keystone, micro-rotation, top/bottom flap trim |
| `--rotate` | Fix 90°/180°/270° (needs Tesseract) |

## What to fix where

| Symptom | Likely code |
|---------|-------------|
| Crop box wrong / no doc | `detector/detect.swift` |
| Tight/loose margin | `expand_quad` / `--expansion` |
| Residual tilt / keystone / flaps | `--deskew` path in `processor.py` |
| Wrong 90/180/270 | `auto_rotate_image` (needs Tesseract) |
