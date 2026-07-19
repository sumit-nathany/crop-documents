"""
processor.py — Core image processing module.

For each image:
  1. Call the Swift Vision detector to get document corner coordinates (JSON).
  2. Convert normalized Vision coords → pixel coords (flipping y-axis).
  3. Expand the detected quad outward by `expansion_pct` from its centroid.
  4. Apply a perspective warp to produce a flat, de-skewed image.
  5. (Optional) Use Tesseract OSD to detect and correct document rotation.
  6. Save to the output directory with the same filename.
"""

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Optional

import cv2
import numpy as np
from PIL import Image

# ── Optional Tesseract OSD for auto-rotation ──────────────────────────────────
try:
    import pytesseract
    from pytesseract import Output as TesseractOutput
    _TESSERACT_AVAILABLE = True
except ImportError:
    _TESSERACT_AVAILABLE = False

# ── HEIC support ──────────────────────────────────────────────────────────────
# Try pillow-heif first (pip install pillow-heif). If not available, fall back
# to macOS's built-in `sips` tool which can convert HEIC → JPEG on the fly.
try:
    from pillow_heif import register_heif_opener
    register_heif_opener()          # registers HEIC/HEIF as a Pillow format
    _HEIC_BACKEND = "pillow-heif"
except ImportError:
    _HEIC_BACKEND = "sips"          # macOS built-in, zero extra deps

# ── Path to the compiled Swift detector binary ────────────────────────────────
SCRIPT_DIR = Path(__file__).parent
DETECTOR_BIN = SCRIPT_DIR / "detector" / "detect"

# ── Supported input formats ───────────────────────────────────────────────────
SUPPORTED_EXTENSIONS = {".jpg", ".jpeg", ".png", ".tiff", ".tif", ".heic", ".heif"}


def detect_corners(image_path: Path) -> Optional[dict]:
    """
    Run the Swift Vision detector on `image_path`.
    Returns the parsed JSON dict, or None on hard failure.
    """
    if not DETECTOR_BIN.exists():
        raise RuntimeError(
            f"Detector binary not found at {DETECTOR_BIN}.\n"
            "Run setup.sh first to compile it."
        )

    result = subprocess.run(
        [str(DETECTOR_BIN), str(image_path)],
        capture_output=True,
        text=True,
    )

    if result.returncode not in (0, 1):  # 0 = ok, exit(0) on no-doc is fine
        raise RuntimeError(f"Detector crashed: {result.stderr.strip()}")

    try:
        return json.loads(result.stdout.strip())
    except json.JSONDecodeError as e:
        raise RuntimeError(f"Bad JSON from detector: {e}\nOutput: {result.stdout}")


def normalized_to_pixels(corners: list[dict], img_w: int, img_h: int) -> np.ndarray:
    """
    Convert Vision's normalized coords (origin bottom-left) to pixel coords
    (origin top-left, as used by OpenCV/PIL).

    Vision corner order: [topLeft, topRight, bottomRight, bottomLeft] (clockwise).
    Returns shape (4, 2) float32 array in the same clockwise order.
    """
    pts = []
    for c in corners:
        px = c["x"] * img_w
        py = (1.0 - c["y"]) * img_h  # flip y-axis
        pts.append([px, py])
    return np.array(pts, dtype=np.float32)


def expand_quad(pts: np.ndarray, expansion_pct: float) -> np.ndarray:
    """
    Push each corner outward from the centroid by `expansion_pct` percent.
    This preserves a natural sliver of the background around the document
    instead of cropping exactly at the detected edges.
    """
    centroid = pts.mean(axis=0)
    expanded = []
    factor = 1.0 + (expansion_pct / 100.0)
    for pt in pts:
        direction = pt - centroid
        expanded.append(centroid + direction * factor)
    return np.array(expanded, dtype=np.float32)


def warp_perspective(img: np.ndarray, src_pts: np.ndarray) -> np.ndarray:
    """
    Apply a 4-point perspective warp.

    Destination is a rectangle whose width/height is derived from the
    average of the two pairs of opposite sides of the source quad.
    No aspect ratio is enforced — the output proportions match the detected doc.
    """
    tl, tr, br, bl = src_pts

    # Width = average of top edge and bottom edge lengths
    width_top = np.linalg.norm(tr - tl)
    width_bot = np.linalg.norm(br - bl)
    dst_w = int(max(width_top, width_bot))

    # Height = average of left edge and right edge lengths
    height_left = np.linalg.norm(bl - tl)
    height_right = np.linalg.norm(br - tr)
    dst_h = int(max(height_left, height_right))

    dst_pts = np.array(
        [[0, 0], [dst_w - 1, 0], [dst_w - 1, dst_h - 1], [0, dst_h - 1]],
        dtype=np.float32,
    )

    M = cv2.getPerspectiveTransform(src_pts, dst_pts)
    warped = cv2.warpPerspective(img, M, (dst_w, dst_h), flags=cv2.INTER_LANCZOS4)
    return warped


def process_image(
    image_path: Path,
    output_dir: Path,
    expansion_pct: float = 4.0,
    skipped_log: Optional[list] = None,
    auto_rotate: bool = False,
    rotate_confidence: float = 1.0,
) -> bool:
    """
    Full pipeline for a single image.

    Returns True on success, False if skipped (no document detected).
    Raises on hard errors (file I/O, detector crash, etc.).

    If `auto_rotate` is True, Tesseract OSD is used after the perspective warp
    to detect and correct document rotation (requires tesseract to be installed).
    """
    # ── Load image ──────────────────────────────────────────────────────────
    try:
        pil_img = _open_image(image_path)
        # Honour EXIF orientation
        pil_img = _apply_exif_rotation(pil_img)
        img_w, img_h = pil_img.size
        # Convert to RGB numpy array for OpenCV (drops alpha if present)
        cv_img = cv2.cvtColor(np.array(pil_img.convert("RGB")), cv2.COLOR_RGB2BGR)
    except Exception as e:
        raise RuntimeError(f"Cannot open {image_path.name}: {e}")

    # ── Detect corners ──────────────────────────────────────────────────────
    detection = detect_corners(image_path)

    if detection.get("error") or not detection.get("corners"):
        reason = detection.get("error", "No document detected")
        print(f"  ⚠️  Skipped ({reason})")
        if skipped_log is not None:
            skipped_log.append(f"{image_path.name}: {reason}")
        return False

    # ── Convert + expand ────────────────────────────────────────────────────
    corners_px = normalized_to_pixels(detection["corners"], img_w, img_h)
    expanded_px = expand_quad(corners_px, expansion_pct)

    # Clamp to image bounds to avoid black strips from warpPerspective
    expanded_px[:, 0] = np.clip(expanded_px[:, 0], 0, img_w - 1)
    expanded_px[:, 1] = np.clip(expanded_px[:, 1], 0, img_h - 1)

    # ── Perspective warp ────────────────────────────────────────────────────
    warped = warp_perspective(cv_img, expanded_px)

    # ── Auto-rotate (optional) ──────────────────────────────────────────────
    # Convert to PIL now so auto_rotate_image and the save logic share one copy.
    warped_rgb = cv2.cvtColor(warped, cv2.COLOR_BGR2RGB)
    out_pil = Image.fromarray(warped_rgb)

    if auto_rotate:
        out_pil = auto_rotate_image(out_pil, min_confidence=rotate_confidence)

    # ── Save output ─────────────────────────────────────────────────────────
    output_dir.mkdir(parents=True, exist_ok=True)
    out_path = output_dir / image_path.name

    ext = image_path.suffix.lower()
    if ext in {".jpg", ".jpeg"}:
        out_pil.save(out_path, format="JPEG", quality=95, subsampling=0)
    elif ext == ".png":
        out_pil.save(out_path, format="PNG", optimize=True)
    elif ext in {".tiff", ".tif"}:
        out_pil.save(out_path, format="TIFF")
    elif ext in {".heic", ".heif"}:
        # Save as high-quality JPEG with the same filename stem.
        # Re-encoding to HEIC from Python is lossy and unreliable across
        # library versions, so JPEG is the safe, universally compatible choice.
        out_path = out_path.with_suffix(".jpg")
        out_pil.save(out_path, format="JPEG", quality=95, subsampling=0)
    else:
        # Unknown format — save as JPEG with same stem
        out_path = out_path.with_suffix(".jpg")
        out_pil.save(out_path, format="JPEG", quality=95, subsampling=0)

    confidence = detection.get("confidence")
    conf_str = f" (confidence {confidence:.2f})" if confidence is not None else ""
    print(f"  ✅  Saved → {out_path.name}{conf_str}")
    return True


# ── Helpers ───────────────────────────────────────────────────────────────────

def auto_rotate_image(img: Image.Image, min_confidence: float = 1.0) -> Image.Image:
    """
    Use Tesseract OSD (Orientation and Script Detection) to detect and correct
    image rotation. The image should ideally be already cropped/de-skewed for
    best results.

    Returns the (possibly rotated) PIL image unchanged if:
      - pytesseract is not installed
      - Tesseract binary is not found
      - OSD confidence is below `min_confidence`
      - The detected rotation is 0° (already upright)
    """
    if not _TESSERACT_AVAILABLE:
        print("  ⚠️  pytesseract not installed — skipping auto-rotate. "
              "Run: pip install pytesseract  (and: brew install tesseract)")
        return img

    try:
        osd = pytesseract.image_to_osd(img, output_type=TesseractOutput.DICT)
        angle = osd.get("rotate", 0)
        confidence = osd.get("orientation_conf", 0.0)

        if angle == 0:
            return img

        if confidence < min_confidence:
            print(
                f"  ℹ️   OSD detected {angle}° rotation but confidence "
                f"({confidence:.2f}) is below threshold ({min_confidence:.2f}) — skipping."
            )
            return img

        print(f"  🔄  Auto-rotating {angle}° (OSD confidence: {confidence:.2f})")
        # Tesseract's `rotate` = degrees the image is CCW-offset from upright.
        # PIL rotate() also goes CCW, so we must negate to *undo* the offset.
        # (180° is symmetric so it worked before; 90°/270° were wrong.)
        return img.rotate(-angle, expand=True)

    except pytesseract.TesseractNotFoundError:
        print("  ⚠️  Tesseract binary not found — skipping auto-rotate. "
              "Install with: brew install tesseract")
    except Exception as e:
        print(f"  ⚠️  OSD failed ({e}) — skipping auto-rotate.")

    return img


def _open_image(image_path: Path) -> Image.Image:
    """
    Open any supported image, including HEIC/HEIF.

    - If pillow-heif is installed, Pillow handles HEIC transparently.
    - Otherwise fall back to macOS `sips` to convert HEIC to a temp JPEG
      before handing off to Pillow. `sips` is built into every macOS install.
    """
    ext = image_path.suffix.lower()
    if ext in {".heic", ".heif"} and _HEIC_BACKEND == "sips":
        return _open_heic_via_sips(image_path)
    return Image.open(image_path)


def _open_heic_via_sips(image_path: Path) -> Image.Image:
    """Convert a HEIC file to a temporary JPEG using macOS sips, then open it."""
    with tempfile.NamedTemporaryFile(suffix=".jpg", delete=False) as tmp:
        tmp_path = tmp.name

    try:
        result = subprocess.run(
            ["sips", "-s", "format", "jpeg", str(image_path), "--out", tmp_path],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            raise RuntimeError(
                f"sips conversion failed: {result.stderr.strip()}"
            )
        return Image.open(tmp_path).copy()  # .copy() so we can delete the tmp file
    finally:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass


def _apply_exif_rotation(img: Image.Image) -> Image.Image:
    """Rotate image according to its EXIF orientation tag."""
    try:
        exif = img._getexif()  # type: ignore[attr-defined]
        if exif is None:
            return img
        orientation = exif.get(274)  # 274 = Orientation tag
        rotations = {3: 180, 6: 270, 8: 90}
        if orientation in rotations:
            return img.rotate(rotations[orientation], expand=True)
    except Exception:
        pass
    return img
