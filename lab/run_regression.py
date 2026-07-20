#!/usr/bin/env python3
"""
lab/run_regression.py — Compare crop variants for deskew/rotation tuning.

Reads images from lab/cases/, writes lab/out/<variant>/.
Run from repo root after ./setup.sh.
"""

from __future__ import annotations

import argparse
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from processor import SUPPORTED_EXTENSIONS, process_image  # noqa: E402

CASES = Path(__file__).parent / "cases"
OUT = Path(__file__).parent / "out"

# name → kwargs passed to process_image (beyond path/out/expansion)
VARIANTS: dict[str, dict] = {
    "crop": {},
    "deskew": {"deskew": True},
    "rotate": {"auto_rotate": True},
    "deskew_rotate": {"deskew": True, "auto_rotate": True},
}


def collect_cases() -> list[Path]:
    if not CASES.is_dir():
        return []
    return sorted(
        p for p in CASES.iterdir()
        if p.is_file() and p.suffix.lower() in SUPPORTED_EXTENSIONS
    )


def run_variant(
    name: str,
    images: list[Path],
    expansion: float,
    rotate_confidence: float,
) -> None:
    opts = dict(VARIANTS[name])
    dest = OUT / name
    if dest.exists():
        shutil.rmtree(dest)
    dest.mkdir(parents=True)

    print(f"\n━━━ variant: {name} → {dest}/ ━━━")
    skipped: list[str] = []
    ok = 0
    for img in images:
        print(f"  {img.name}")
        try:
            success = process_image(
                img,
                dest,
                expansion_pct=expansion,
                skipped_log=skipped,
                rotate_confidence=rotate_confidence,
                **opts,
            )
            if success:
                ok += 1
        except Exception as e:
            print(f"    ❌  {e}")
            skipped.append(f"{img.name}: {e}")
    print(f"  done: {ok}/{len(images)} ok, {len(skipped)} skipped")
    if skipped:
        (dest / "skipped.txt").write_text("\n".join(skipped) + "\n")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Run crop regression variants over lab/cases/."
    )
    parser.add_argument(
        "--variants",
        default=",".join(VARIANTS.keys()),
        help=f"Comma-separated subset of: {','.join(VARIANTS)}",
    )
    parser.add_argument("--expansion", type=float, default=4.0)
    parser.add_argument("--rotate-confidence", type=float, default=1.0)
    args = parser.parse_args()

    names = [v.strip() for v in args.variants.split(",") if v.strip()]
    unknown = [n for n in names if n not in VARIANTS]
    if unknown:
        print(f"❌  Unknown variants: {unknown}. Choose from: {list(VARIANTS)}")
        sys.exit(1)

    images = collect_cases()
    if not images:
        print(
            f"⚠️  No images in {CASES}/\n"
            "   Copy hard cases there (jpg/png/heic), then re-run."
        )
        sys.exit(0)

    print(f"📂  {len(images)} case(s) in {CASES}/")
    OUT.mkdir(parents=True, exist_ok=True)
    for name in names:
        run_variant(name, images, args.expansion, args.rotate_confidence)

    print(f"\n✅  Compare outputs under {OUT}/")


if __name__ == "__main__":
    main()
