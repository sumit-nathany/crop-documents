"""
pdf_builder.py — PDF generation utility.

Losslessly combines processed images into a single PDF file.
Each page in the output PDF is sized exactly to match the dimensions
of the source image (no white borders or margins added).
"""

import sys
from pathlib import Path
from typing import List, Union

import img2pdf


def build_pdf(image_paths: List[Path], output_pdf_path: Path) -> bool:
    """
    Combines a list of image paths into a single PDF.
    
    Returns True on success, raises or returns False on failure.
    """
    if not image_paths:
        print("❌  No images provided for PDF creation.")
        return False

    # Filter for existing files
    valid_paths = []
    for p in image_paths:
        if p.exists() and p.is_file():
            valid_paths.append(p)
        else:
            print(f"⚠️  Skipping missing image file: {p}")

    if not valid_paths:
        print("❌  No valid existing images to combine.")
        return False

    print(f"📄  Combining {len(valid_paths)} image(s) into PDF: {output_pdf_path.name}")
    
    try:
        # img2pdf handles files as bytes or path strings
        path_strs = [str(p) for p in valid_paths]
        
        # Write PDF bytes
        with open(output_pdf_path, "wb") as f:
            f.write(img2pdf.convert(path_strs))
            
        print(f"✅  Successfully created PDF → {output_pdf_path}")
        return True
    except Exception as e:
        print(f"❌  Error generating PDF: {e}")
        return False


if __name__ == "__main__":
    # Quick CLI entrypoint for testing/standalone usage
    import argparse
    
    parser = argparse.ArgumentParser(description="Combine multiple images into a single PDF.")
    parser.add_argument(
        "images",
        nargs="+",
        type=Path,
        help="List of images or a folder containing images to merge."
    )
    parser.add_argument(
        "--output", "-o",
        required=True,
        type=Path,
        help="Output path for the generated PDF."
    )
    
    args = parser.parse_args()
    
    # If the single argument is a directory, grab all images in it
    resolved_paths = []
    if len(args.images) == 1 and args.images[0].is_dir():
        from processor import SUPPORTED_EXTENSIONS
        resolved_paths = sorted(
            p for p in args.images[0].iterdir()
            if p.is_file() and p.suffix.lower() in SUPPORTED_EXTENSIONS
        )
    else:
        resolved_paths = args.images

    build_pdf(resolved_paths, args.output)
