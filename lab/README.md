# Pipeline lab (deskew / rotation)

Use this folder to iterate on **deskew** and **auto-rotate** without touching the iOS app yet. The Mac Python CLI remains the source of truth.

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

- Sideways / upside-down pages (OSD)
- Slight tilt (1–5°) after a good crop (deskew)
- Sparse receipts, dark tables, hands in frame
- Keystone / folded corners (`--refine-corners`)

## Run

From the repo root (requires `./setup.sh` already done):

```bash
# All variants: crop, +deskew, +rotate, +deskew+rotate, +refine+deskew
python3 lab/run_regression.py

# Only deskew vs baseline
python3 lab/run_regression.py --variants crop,deskew

# Custom expansion
python3 lab/run_regression.py --expansion 4.0
```

Outputs land in `lab/out/<variant>/` with the same filenames. Compare visually (Finder / Quick Look).

## What to fix where

| Symptom | Likely code |
|---------|-------------|
| Crop box wrong / no doc | `detector/detect.swift` |
| Tight/loose margin | `expand_quad` / `--expansion` |
| Residual tilt after crop | `deskew_image` in `processor.py` |
| Wrong 90/180/270 | `auto_rotate_image` (needs Tesseract) |
| Keystone / folded corner | `refine_corners` |

Keep changes opt-in via flags and soft-fail when Tesseract is missing.
