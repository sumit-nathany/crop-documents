"""
batch.py — CLI entrypoint for the document auto-crop tool.

Usage:
  Current folder (no args needed):
    python3 batch.py

  Specific folder:
    python3 batch.py --input ./photos/

  Single image:
    python3 batch.py --input photo.jpg

  Custom output folder:
    python3 batch.py --input ./photos/ --output ./cropped/

  Custom expansion border (default 4%):
    python3 batch.py --input ./photos/ --expansion 6

  Watch mode (Phase 2):
    python3 batch.py --input ./inbox/ --watch

  Batch crop AND combine into a PDF (Phase 3):
    python3 batch.py --input ./photos/ --pdf combined.pdf
"""

import argparse
import sys
import time
from pathlib import Path

import yaml

from processor import SUPPORTED_EXTENSIONS, process_image
from pdf_builder import build_pdf


# ── Load config ───────────────────────────────────────────────────────────────
CONFIG_PATH = Path(__file__).parent / "config.yaml"


def load_config() -> dict:
    if CONFIG_PATH.exists():
        with open(CONFIG_PATH) as f:
            return yaml.safe_load(f) or {}
    return {}


# ── Batch processing ──────────────────────────────────────────────────────────

def collect_images(input_path: Path) -> list[Path]:
    """Return all supported image files under `input_path` (file or directory)."""
    if input_path.is_file():
        if input_path.suffix.lower() in SUPPORTED_EXTENSIONS:
            return [input_path]
        else:
            print(f"❌  Unsupported format: {input_path.suffix}")
            sys.exit(1)
    elif input_path.is_dir():
        images = sorted(
            p for p in input_path.iterdir()
            if p.is_file() and p.suffix.lower() in SUPPORTED_EXTENSIONS
        )
        return images
    else:
        print(f"❌  Input not found: {input_path}")
        sys.exit(1)


def run_batch(images: list[Path], output_dir: Path, expansion_pct: float,
              auto_rotate: bool = False, rotate_confidence: float = 1.0) -> None:
    total = len(images)
    if total == 0:
        print("⚠️  No supported images found.")
        return

    print(f"\n📂  Processing {total} image(s) → {output_dir}/")
    print(f"🔍  Expansion border: {expansion_pct}%")
    if auto_rotate:
        print(f"🔄  Auto-rotate: ON (confidence threshold: {rotate_confidence})")
    print()

    skipped_log: list[str] = []
    success = 0

    for i, img_path in enumerate(images, 1):
        print(f"[{i}/{total}] {img_path.name}")
        try:
            ok = process_image(img_path, output_dir, expansion_pct, skipped_log,
                               auto_rotate=auto_rotate,
                               rotate_confidence=rotate_confidence)
            if ok:
                success += 1
        except Exception as e:
            print(f"  ❌  Error: {e}")
            skipped_log.append(f"{img_path.name}: {e}")

    # ── Summary ───────────────────────────────────────────────────────────────
    print(f"\n{'━'*48}")
    print(f"  ✅  Processed : {success}/{total}")
    print(f"  ⚠️  Skipped   : {len(skipped_log)}/{total}")
    print(f"{'━'*48}")

    if skipped_log:
        log_path = output_dir / "skipped.txt"
        log_path.write_text("\n".join(skipped_log))
        print(f"\n  Skipped log → {log_path}")

    return success > 0



# ── Watch mode (Phase 2 placeholder) ─────────────────────────────────────────

def run_watch(input_dir: Path, output_dir: Path, expansion_pct: float,
              auto_rotate: bool = False, rotate_confidence: float = 1.0) -> None:
    try:
        from watchdog.events import FileSystemEventHandler
        from watchdog.observers import Observer
    except ImportError:
        print("❌  watchdog not installed. Run: pip install watchdog")
        sys.exit(1)

    class Handler(FileSystemEventHandler):
        def on_created(self, event):
            if event.is_directory:
                return
            p = Path(event.src_path)
            if p.suffix.lower() not in SUPPORTED_EXTENSIONS:
                return
            # Small delay to let the file finish writing
            time.sleep(0.5)
            print(f"\n🆕  New file detected: {p.name}")
            try:
                process_image(p, output_dir, expansion_pct,
                              auto_rotate=auto_rotate,
                              rotate_confidence=rotate_confidence)
            except Exception as e:
                print(f"  ❌  Error: {e}")

    output_dir.mkdir(parents=True, exist_ok=True)
    observer = Observer()
    observer.schedule(Handler(), str(input_dir), recursive=False)
    observer.start()
    print(f"👀  Watching {input_dir}/ for new images. Press Ctrl+C to stop.\n")
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        observer.stop()
    observer.join()
    print("\n🛑  Watch mode stopped.")


# ── CLI ───────────────────────────────────────────────────────────────────────

def main():
    config = load_config()

    parser = argparse.ArgumentParser(
        description="Batch auto-crop document photos using Apple Vision."
    )
    parser.add_argument(
        "--input", "-i",
        type=Path,
        default=Path.cwd(),
        help="Path to a single image or a folder of images (default: current directory).",
    )
    parser.add_argument(
        "--output", "-o",
        type=Path,
        default=None,
        help="Output directory (default: same folder as --input).",
    )
    parser.add_argument(
        "--expansion", "-e",
        type=float,
        default=float(config.get("expansion_pct", 4.0)),
        help="How much to expand the crop border beyond the detected document edges, "
             "as a percentage (default: 4).",
    )
    parser.add_argument(
        "--rotate", "-r",
        action="store_true",
        default=bool(config.get("auto_rotate", False)),
        help="Auto-rotate the cropped document using Tesseract OSD "
             "(requires: pip install pytesseract && brew install tesseract).",
    )
    parser.add_argument(
        "--rotate-confidence",
        type=float,
        default=float(config.get("rotate_confidence", 1.0)),
        help="Minimum OSD confidence required to apply rotation (default: 1.0).",
    )
    parser.add_argument(
        "--watch", "-w",
        action="store_true",
        help="Watch mode: monitor the input folder and auto-process new images.",
    )
    parser.add_argument(
        "--pdf",
        type=Path,
        default=None,
        help="Compile all successfully cropped images into a single PDF with this name (saves to the output directory).",
    )


    args = parser.parse_args()

    # Resolve output directory: default to the input's parent dir (or input dir itself).
    if args.output is None:
        if args.input.is_dir():
            output_dir = args.input
        else:
            output_dir = args.input.parent
    else:
        output_dir = args.output

    if args.watch:
        if not args.input.is_dir():
            print("❌  --watch requires a directory as --input.")
            sys.exit(1)
        run_watch(args.input, output_dir, args.expansion,
                  auto_rotate=args.rotate,
                  rotate_confidence=args.rotate_confidence)
    else:
        images = collect_images(args.input)
        # Keep track of generated output paths if we want to combine them into a PDF
        success = run_batch(images, output_dir, args.expansion,
                            auto_rotate=args.rotate,
                            rotate_confidence=args.rotate_confidence)
        
        if success and args.pdf:
            # Gather paths of the cropped images that were successfully generated
            cropped_images = []
            for img in images:
                # If it's HEIC, the saved extension will be .jpg
                ext = img.suffix.lower()
                target_name = img.name
                if ext in {".heic", ".heif"}:
                    target_name = img.with_suffix(".jpg").name
                
                cropped_path = output_dir / target_name
                if cropped_path.exists():
                    cropped_images.append(cropped_path)
            
            # Save the PDF in the output directory (or custom path if it's absolute)
            pdf_path = args.pdf if args.pdf.is_absolute() else output_dir / args.pdf
            build_pdf(cropped_images, pdf_path)



if __name__ == "__main__":
    main()
