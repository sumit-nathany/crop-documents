# Pipeline lab (deskew / rotation)

Use this folder to iterate on **alignment** and **auto-rotate** against real photos.
Everything here drives the Swift CLI, so the harness exercises the same engine the
iPhone app ships.

## Layout

```
lab/
├── cases/                          # Drop hard photos here (HEIC/JPEG/PNG). Not committed.
├── out/                            # Regression outputs (gitignored)
├── run_regression.sh
├── python-reference-baseline.json  # What the retired Python pipeline produced
└── README.md
```

## Add cases

Copy failing or borderline shots into `lab/cases/`. Prefer a mix of:

- Sideways pages (`--rotate`)
- Slight tilt / keystone after a good crop (`--deskew`)
- Open flaps, stray paper, colored box edges
- Sparse receipts, dark tables, hands in frame

## Run

From the repo root (requires `./build-cli.sh` already done):

```bash
./lab/run_regression.sh

# Subset
./lab/run_regression.sh --variants crop,deskew

# Custom expansion
./lab/run_regression.sh --expansion 6
```

Single image, ad hoc:

```bash
./crop-documents --input lab/cases/ --output lab/out/manual/ --deskew --verbose
```

## Diagnosing a stage

Each probe reports what the engine decided and changes nothing:

```bash
./crop-documents probe-trim        lab/cases/foo.jpg   # rows, runs, merge, main block
./crop-documents probe-skew        lab/cases/foo.jpg   # raw deskew angle estimate
./crop-documents probe-orientation lab/cases/foo.jpg   # per-orientation text scores
```

## Judging a change

Compare **output dimensions** and **residual skew**, not per-pixel deltas. A 0.6° deskew
changes a textured photo by mean|Δ|≈13 on its own, so pixel metrics drown in texture and
will tell you two good results are wildly different. To measure residual skew, run
`probe-skew` on the *output* — closer to zero is straighter.

## Flags (keep it simple)

| Flag | Meaning |
|------|---------|
| *(none)* | Crop only |
| `--deskew` | Align: keystone, micro-rotation, top/bottom flap trim |
| `--rotate` | Straighten a sideways page (never flips 180° — see `DocumentOrienter`) |

## What to fix where

All paths are under `ios/DocumentCropCore/Sources/DocumentCropCore/`.

| Symptom | Likely code |
|---------|-------------|
| Crop box wrong / no doc found | `DocumentDetector` (and `DetectionPolicy` thresholds) |
| Tight/loose margin | `DocumentQuad.expanded` / `--expansion` |
| Residual tilt | `DocumentWarper.estimateSkewDegrees` |
| Flap kept or page over-trimmed | `DocumentTrimmer` (`cannyLite`, `analysisMaxSide`) |
| Sideways page not straightened | `DocumentOrienter` |
