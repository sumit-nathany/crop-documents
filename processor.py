"""
processor.py — Core image processing module.

For each image:
  1. Call the Swift Vision detector to get document corner coordinates (JSON).
  2. Convert normalized Vision coords → pixel coords (flipping y-axis).
  3. Expand the detected quad outward by `expansion_pct` from its centroid.
  4. Apply a perspective warp to produce a flat, de-skewed image.
  5. (Optional `--deskew`) Conservative align: corner refine, wider border,
     upper-band deskew, top/bottom flap trim only.
  6. (Optional `--rotate`) Tesseract OSD for 90°/180°/270° orientation.
  7. Save to the output directory with the same filename.
"""

import json
import math
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

# ── Path to the compiled Swift binaries ────────────────────────────────────────
SCRIPT_DIR = Path(__file__).parent
DETECTOR_BIN = SCRIPT_DIR / "detector" / "detect"
ENHANCER_BIN = SCRIPT_DIR / "enhancer" / "enhance"

# ── Supported input formats ───────────────────────────────────────────────────
SUPPORTED_EXTENSIONS = {".jpg", ".jpeg", ".png", ".tiff", ".tif", ".heic", ".heif"}


def enhance_image(image_path: Path, quality: float = 0.95) -> bool:
    """
    Apply native Apple Photos CoreImage auto-enhancements to `image_path` in place.
    (exposure, contrast, tone curves, color balance).
    """
    if not ENHANCER_BIN.exists():
        print(f"  ⚠️  Enhancer binary not found at {ENHANCER_BIN}. Run setup.sh first.")
        return False

    result = subprocess.run(
        [str(ENHANCER_BIN), str(image_path), str(image_path), str(quality)],
        capture_output=True,
        text=True,
    )
    if result.returncode == 0:
        return True
    else:
        err = result.stderr.strip() or "enhancer error"
        print(f"  ⚠️  Auto-enhancement failed: {err}")
        return False



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


def _edge_angle(p1: np.ndarray, p2: np.ndarray) -> float:
    return float(np.degrees(np.arctan2(p2[1] - p1[1], p2[0] - p1[0])))


def top_bottom_edge_divergence(pts: np.ndarray) -> float:
    """Absolute angle difference (degrees) between top (TL→TR) and bottom (BL→BR) edges."""
    tl, tr, br, bl = pts
    diff = abs(_edge_angle(tl, tr) - _edge_angle(bl, br)) % 360
    if diff > 180:
        diff = 360 - diff
    return float(diff)


def refine_corners(pts: np.ndarray, img_h: int) -> np.ndarray:
    """
    Detects and repairs a folded corner by forcing the top/bottom edges to be
    roughly parallel if they diverge significantly.
    pts: [TL, TR, BR, BL] (shape (4, 2))
    """
    tl, tr, br, bl = pts.copy()

    def intersect(p1, p2, p3, p4):
        x1, y1 = p1; x2, y2 = p2
        x3, y3 = p3; x4, y4 = p4
        denom = (x1-x2)*(y3-y4) - (y1-y2)*(x3-x4)
        if abs(denom) < 1e-5:
            return None
        px = ((x1*y2 - y1*x2)*(x3-x4) - (x1-x2)*(x3*y4 - y3*x4)) / denom
        py = ((x1*y2 - y1*x2)*(y3-y4) - (y1-y2)*(x3*y4 - y3*x4)) / denom
        return np.array([px, py], dtype=np.float32)

    diff = top_bottom_edge_divergence(pts)

    if diff > 4.0:
        if tl[1] > tr[1] + img_h * 0.03:
            tr_virtual = tr + (bl - br)
            new_tl = intersect(bl, tl, tr, tr_virtual)
            if new_tl is not None: tl = new_tl
        elif tr[1] > tl[1] + img_h * 0.03:
            tl_virtual = tl + (br - bl)
            new_tr = intersect(br, tr, tl, tl_virtual)
            if new_tr is not None: tr = new_tr
        elif bl[1] < br[1] - img_h * 0.03:
            br_virtual = br + (tl - tr)
            new_bl = intersect(tl, bl, br, br_virtual)
            if new_bl is not None: bl = new_bl
        elif br[1] < bl[1] - img_h * 0.03:
            bl_virtual = bl + (tr - tl)
            new_br = intersect(tr, br, bl, bl_virtual)
            if new_br is not None: br = new_br
            
    return np.array([tl, tr, br, bl], dtype=np.float32)


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


# When aligning, start (and finish) with a wider organic border so flap trim /
# re-square still leave a natural margin. Crop-only keeps `expansion_pct` as-is.
DESKEW_BORDER_EXTRA_PCT = 4.0


def process_image(
    image_path: Path,
    output_dir: Path,
    expansion_pct: float = 4.0,
    skipped_log: Optional[list] = None,
    auto_rotate: bool = False,
    rotate_confidence: float = 1.0,
    deskew: bool = False,
    deskew_max_angle: float = 15.0,
    auto_enhance: bool = False,
) -> bool:
    """
    Full pipeline for a single image.

    Returns True on success, False if skipped (no document detected).
    Raises on hard errors (file I/O, detector crash, etc.).

    Default: detect → expand → warp → save.

    If `deskew` is True, run a conservative alignment stack (corner refine,
    wider border, upper-band deskew, top/bottom flap trim only).

    If `auto_rotate` is True, Tesseract OSD corrects 90°/180°/270° orientation
    (requires tesseract).

    If `auto_enhance` is True, native Apple CoreImage auto-enhancement is applied
    (exposure, contrast, tone curves, color balance).
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

    # Deskew needs headroom so later trims don't erase the organic border.
    border_pct = (
        expansion_pct + DESKEW_BORDER_EXTRA_PCT if deskew else expansion_pct
    )

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

    # Deskew path: refine keystoned Vision quads before warp.
    left_pad = 0.0
    if deskew:
        divergence = top_bottom_edge_divergence(corners_px)
        if divergence > 4.0:
            print(f"  📐  Refine corners (top/bottom diverge {divergence:.1f}°)")
            left_pad = max(img_w * 0.055, 60.0)
        corners_px = refine_corners(corners_px, img_h)

    expanded_px = expand_quad(corners_px, border_pct)

    if left_pad > 0:
        expanded_px[0, 0] -= left_pad  # TL
        expanded_px[3, 0] -= left_pad  # BL

    # Clamp to image bounds to avoid black strips from warpPerspective
    expanded_px[:, 0] = np.clip(expanded_px[:, 0], 0, img_w - 1)
    expanded_px[:, 1] = np.clip(expanded_px[:, 1], 0, img_h - 1)

    # ── Perspective warp ────────────────────────────────────────────────────
    warped = warp_perspective(cv_img, expanded_px)

    # ── Convert to PIL for post-processing ─────────────────────────────────
    warped_rgb = cv2.cvtColor(warped, cv2.COLOR_BGR2RGB)
    out_pil = Image.fromarray(warped_rgb)

    # ── Alignment stack (`--deskew`) ─────────────────────────────────────────
    # Keep this conservative: aggressive Vision re-square + side/color trims
    # routinely destroy good crops (e.g. latch onto a barcode sticker). Prefer
    # a slightly imperfect organic frame over a "complete toss".
    if deskew:
        out_pil = deskew_image(out_pil, max_angle=deskew_max_angle)
        # Open flaps / stray paper are usually above or below the face —
        # never nibble left/right (hands, orange box edge = organic border).
        out_pil = trim_external_content(
            out_pil,
            margin_pct=border_pct,
            sides=("top", "bottom"),
            max_trim_frac=0.35,
        )

    # ── Auto-rotate (optional) ──────────────────────────────────────────────
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

    # ── Native Apple Auto-Enhancement (optional) ───────────────────────────
    if auto_enhance:
        enhance_image(out_path)

    confidence = detection.get("confidence")
    conf_str = f" (confidence {confidence:.2f})" if confidence is not None else ""
    enhance_str = " ✨ enhanced" if auto_enhance else ""
    print(f"  ✅  Saved → {out_path.name}{conf_str}{enhance_str}")
    return True



# ── Helpers ───────────────────────────────────────────────────────────────────

def resquare_with_vision(
    img: Image.Image,
    expansion_pct: float = 4.0,
    min_confidence: float = 0.85,
) -> Optional[Image.Image]:
    """
    Re-run Vision on an already-cropped page and warp again.

    Kept for experiments — not used by the default `--deskew` stack (it often
    latches onto stickers/sub-rects). Rejects low-confidence detections and
    aspect-ratio flips.
    """
    tmp_path = None
    try:
        with tempfile.NamedTemporaryFile(suffix=".jpg", delete=False) as tmp:
            tmp_path = Path(tmp.name)
        img.convert("RGB").save(tmp_path, format="JPEG", quality=95)

        detection = detect_corners(tmp_path)
        if detection.get("error") or not detection.get("corners"):
            return None

        confidence = float(detection.get("confidence") or 0.0)
        if confidence < min_confidence:
            print(
                f"  ⚠️  Vision re-square skipped "
                f"(confidence {confidence:.2f} < {min_confidence:.2f})"
            )
            return None

        img_w, img_h = img.size
        corners_px = normalized_to_pixels(detection["corners"], img_w, img_h)
        if top_bottom_edge_divergence(corners_px) > 3.0:
            corners_px = refine_corners(corners_px, img_h)

        expanded = expand_quad(corners_px, expansion_pct)
        expanded[:, 0] = np.clip(expanded[:, 0], 0, img_w - 1)
        expanded[:, 1] = np.clip(expanded[:, 1], 0, img_h - 1)

        # Reject if the new quad is a tiny sub-region (barcode sticker trap).
        xs, ys = expanded[:, 0], expanded[:, 1]
        quad_w = float(xs.max() - xs.min())
        quad_h = float(ys.max() - ys.min())
        if quad_w < img_w * 0.55 or quad_h < img_h * 0.55:
            print("  ⚠️  Vision re-square skipped (quad too small vs frame)")
            return None

        src_ar = img_w / max(img_h, 1)
        dst_ar = quad_w / max(quad_h, 1)
        # Reject landscape↔portrait flips from a bad secondary detection.
        if (src_ar >= 1.2 and dst_ar <= 0.85) or (src_ar <= 0.85 and dst_ar >= 1.2):
            print("  ⚠️  Vision re-square skipped (aspect flip)")
            return None

        cv_img = cv2.cvtColor(np.array(img.convert("RGB")), cv2.COLOR_RGB2BGR)
        warped = warp_perspective(cv_img, expanded)
        print(f"  📐  Re-squared with Vision (confidence {confidence:.2f})")
        return Image.fromarray(cv2.cvtColor(warped, cv2.COLOR_BGR2RGB))
    except Exception as e:
        print(f"  ⚠️  Vision re-square skipped ({e})")
        return None
    finally:
        if tmp_path is not None:
            try:
                tmp_path.unlink()
            except OSError:
                pass


def trim_colored_side_flaps(
    img: Image.Image,
    margin_pct: float = 4.0,
    min_trim_pct: float = 2.0,
    orange_frac: float = 0.12,
) -> Image.Image:
    """
    Crop saturated side/bottom strips (box color flaps).

    Looks for edge bands that are mostly orange/red cardboard or dark gaps and
    trims inward until the white label begins, leaving an organic `margin_pct`
    border (same idea as crop expansion).
    """
    rgb = np.array(img.convert("RGB"))
    h, w = rgb.shape[:2]
    hsv = cv2.cvtColor(rgb, cv2.COLOR_RGB2HSV)
    gray = cv2.cvtColor(rgb, cv2.COLOR_RGB2GRAY)

    warm = cv2.inRange(hsv, (0, 40, 40), (35, 255, 255))
    warm |= cv2.inRange(hsv, (160, 40, 40), (180, 255, 255))
    col_frac = warm.mean(axis=0) / 255.0
    dark = (gray < 70).mean(axis=0)
    external_x = np.maximum(col_frac, dark * 0.5)

    def first_content_from_left() -> int:
        limit = int(w * 0.35)
        run = max(3, w // 200)
        for x in range(limit):
            if external_x[x: x + run].mean() < orange_frac:
                return x
        return 0

    def first_content_from_right() -> int:
        limit = int(w * 0.65)
        run = max(3, w // 200)
        for x in range(w - 1, limit, -1):
            if external_x[max(0, x - run + 1): x + 1].mean() < orange_frac:
                return x
        return w - 1

    left = first_content_from_left()
    right = first_content_from_right()
    pad_x = max(4, int(w * (margin_pct / 100.0)))
    crop_left = max(0, left - pad_x)
    crop_right = min(w - 1, right + pad_x)

    # Bottom: orange shelf / box lip
    row_warm = warm.mean(axis=1) / 255.0
    row_dark = (gray < 70).mean(axis=1)
    external_y = np.maximum(row_warm, row_dark * 0.5)
    crop_bot = h - 1
    run_y = max(3, h // 200)
    for y in range(h - 1, int(h * 0.75), -1):
        if external_y[max(0, y - run_y + 1): y + 1].mean() < orange_frac:
            crop_bot = y
            break
    pad_y = max(4, int(h * (margin_pct / 100.0)))
    crop_bot = min(h - 1, crop_bot + pad_y)
    crop_top = 0

    min_trim_x = int(w * (min_trim_pct / 100.0))
    min_trim_y = int(h * (min_trim_pct / 100.0))
    trimmed_l = crop_left
    trimmed_r = w - 1 - crop_right
    trimmed_b = h - 1 - crop_bot

    if trimmed_l < min_trim_x:
        crop_left = 0
        trimmed_l = 0
    if trimmed_r < min_trim_x:
        crop_right = w - 1
        trimmed_r = 0
    if trimmed_b < min_trim_y:
        crop_bot = h - 1
        trimmed_b = 0

    if crop_left == 0 and crop_right == w - 1 and crop_bot == h - 1:
        return img
    if crop_right - crop_left + 1 < w * 0.5:
        return img

    parts = []
    if trimmed_l:
        parts.append(f"left {trimmed_l}px")
    if trimmed_r:
        parts.append(f"right {trimmed_r}px")
    if trimmed_b:
        parts.append(f"bottom {trimmed_b}px")
    if parts:
        print(f"  ✂️  Trimmed color flaps ({', '.join(parts)})")
    return Image.fromarray(rgb[crop_top: crop_bot + 1, crop_left: crop_right + 1])


def trim_external_content(
    img: Image.Image,
    margin_pct: float = 4.0,
    min_trim_pct: float = 2.0,
    max_trim_frac: float = 0.35,
    sides: tuple[str, ...] = ("top", "bottom", "left", "right"),
    edge_row_thr: float = 0.008,
    edge_col_thr: float = 0.006,
) -> Image.Image:
    """
    Crop away external non-content (open box flaps, stray paper, empty table).

    Used by the `--deskew` alignment stack. Uses Canny edge density so smooth
    flaps / dark blurry background are not mistaken for text ink. Keeps an
    organic `margin_pct` pad. By default only trims top/bottom (flaps); side
    trims are opt-in because they often eat hands / box edges. Refuses any
    edge that would remove more than `max_trim_frac` of the image.
    """
    rgb = np.array(img.convert("RGB"))
    gray = cv2.cvtColor(rgb, cv2.COLOR_RGB2GRAY)
    h, w = gray.shape

    edges = cv2.Canny(cv2.GaussianBlur(gray, (5, 5), 0), 50, 150)
    # Ignore extreme side strips (hands / dark bg) when scoring rows.
    x0, x1 = int(w * 0.08), int(w * 0.92)
    row_frac = edges[:, x0:x1].mean(axis=1) / 255.0

    kernel = max(5, h // 150 | 1)
    if kernel % 2 == 0:
        kernel += 1
    row_smooth = cv2.GaussianBlur(
        row_frac.astype(np.float32).reshape(-1, 1), (1, kernel), 0
    ).ravel()

    content_rows = np.where(row_smooth >= edge_row_thr)[0]
    if len(content_rows) < max(20, h // 50):
        return img

    # Build contiguous runs, then merge runs separated by modest gaps so a
    # sparse mid-page band doesn't split title from body into two "documents".
    gap = max(5, h // 120)
    runs: list[list[int]] = []
    start = int(content_rows[0])
    prev = start
    for y in content_rows[1:]:
        y = int(y)
        if y <= prev + gap:
            prev = y
        else:
            runs.append([start, prev])
            start = y
            prev = y
    runs.append([start, prev])

    merge_gap = max(30, h // 12)  # ~8% — flaps are usually a much larger void
    merged: list[list[int]] = [runs[0]]
    for s, e in runs[1:]:
        if s - merged[-1][1] <= merge_gap:
            merged[-1][1] = e
        else:
            merged.append([s, e])

    min_run = max(40, int(h * 0.08))
    substantial = [r for r in merged if r[1] - r[0] >= min_run]
    if not substantial:
        substantial = [max(merged, key=lambda r: r[1] - r[0])]

    # Main face = largest substantial block (drops a small scrap above/below).
    y_top, y_bot = max(substantial, key=lambda r: r[1] - r[0])

    # Column bounds inside that vertical span (full width — side scraps too)
    band = edges[y_top: y_bot + 1]
    col_frac = band.mean(axis=0) / 255.0
    content_cols = np.where(col_frac >= edge_col_thr)[0]
    if len(content_cols) < max(20, w // 50):
        x_left, x_right = 0, w - 1
    else:
        x_left, x_right = int(content_cols[0]), int(content_cols[-1])

    pad_y = int(h * (margin_pct / 100.0))
    pad_x = int(w * (margin_pct / 100.0))
    crop_top = max(0, y_top - pad_y)
    crop_bot = min(h - 1, y_bot + pad_y)
    crop_left = max(0, x_left - pad_x)
    crop_right = min(w - 1, x_right + pad_x)

    # Honour allowed sides — leave disallowed edges untouched.
    if "top" not in sides:
        crop_top = 0
    if "bottom" not in sides:
        crop_bot = h - 1
    if "left" not in sides:
        crop_left = 0
    if "right" not in sides:
        crop_right = w - 1

    trimmed_top = crop_top
    trimmed_bot = h - 1 - crop_bot
    trimmed_left = crop_left
    trimmed_right = w - 1 - crop_right
    min_trim = int(h * (min_trim_pct / 100.0))
    min_trim_x = int(w * (min_trim_pct / 100.0))
    max_trim_y = int(h * max_trim_frac)
    max_trim_x = int(w * max_trim_frac)

    # Only trim an edge when the external band is meaningful (flap / scrap)
    # and not so large that we'd be deleting half the page.
    if trimmed_top < min_trim or trimmed_top > max_trim_y:
        crop_top = 0
        trimmed_top = 0
    if trimmed_bot < min_trim or trimmed_bot > max_trim_y:
        crop_bot = h - 1
        trimmed_bot = 0
    if trimmed_left < min_trim_x or trimmed_left > max_trim_x:
        crop_left = 0
        trimmed_left = 0
    if trimmed_right < min_trim_x or trimmed_right > max_trim_x:
        crop_right = w - 1
        trimmed_right = 0

    if crop_top == 0 and crop_bot == h - 1 and crop_left == 0 and crop_right == w - 1:
        return img

    keep_h = crop_bot - crop_top + 1
    keep_w = crop_right - crop_left + 1
    if keep_h < h * 0.45 or keep_w < w * 0.45:
        return img

    parts = []
    if trimmed_top >= min_trim:
        parts.append(f"top {trimmed_top}px")
    if trimmed_bot >= min_trim:
        parts.append(f"bottom {trimmed_bot}px")
    if trimmed_left >= min_trim_x:
        parts.append(f"left {trimmed_left}px")
    if trimmed_right >= min_trim_x:
        parts.append(f"right {trimmed_right}px")
    if parts:
        print(f"  ✂️  Trimmed external content ({', '.join(parts)})")

    return Image.fromarray(rgb[crop_top: crop_bot + 1, crop_left: crop_right + 1])


def deskew_image(
    img: Image.Image,
    max_angle: float = 15.0,
    max_passes: int = 3,
) -> Image.Image:
    """
    Correct small rotational skew after the perspective warp.

    Uses upper-band text orientation with damped multi-pass. Empty corners are
    filled with BORDER_REFLECT.
    """
    out = img
    prev_abs = None
    for _ in range(max_passes):
        skew = _estimate_skew_angle(out, max_angle=max_angle)
        if skew is None or abs(skew) < 0.25:
            break
        if prev_abs is not None and abs(skew) >= prev_abs * 0.92:
            break
        prev_abs = abs(skew)

        step = float(skew) * 0.85
        print(f"  📐  Deskewing {step:+.2f}° (measured {skew:+.2f}°)")
        cv_img = np.array(out)
        h, w = cv_img.shape[:2]
        M = cv2.getRotationMatrix2D((w / 2, h / 2), step, 1.0)
        rotated_cv = cv2.warpAffine(
            cv_img, M, (w, h),
            flags=cv2.INTER_CUBIC,
            borderMode=cv2.BORDER_REFLECT,
        )
        out = Image.fromarray(rotated_cv)

    return out


def _estimate_skew_angle(img: Image.Image, max_angle: float = 15.0) -> Optional[float]:
    """
    Skew estimate from upper-band text (title rules + dark polyfit).

    Falls back to global Hough median if the upper band has no signal.
    """
    gray = np.array(img.convert("L"))
    h, w = gray.shape
    if h < 50 or w < 50:
        return None

    y0, y1 = int(h * 0.06), int(h * 0.22)
    band = gray[y0:y1, int(w * 0.05): int(w * 0.95)]

    inv = cv2.adaptiveThreshold(
        band, 255, cv2.ADAPTIVE_THRESH_GAUSSIAN_C, cv2.THRESH_BINARY_INV, 31, 12
    )
    rule_mask = cv2.morphologyEx(
        inv, cv2.MORPH_OPEN,
        cv2.getStructuringElement(cv2.MORPH_RECT, (max(20, band.shape[1] // 10), 1)),
    )
    lines = cv2.HoughLinesP(
        rule_mask, 1, np.pi / 1800, 40,
        minLineLength=int(band.shape[1] * 0.35),
        maxLineGap=12,
    )
    rule_angles: list[float] = []
    if lines is not None:
        for x1, y1_, x2, y2 in lines.reshape(-1, 4):
            angle = np.degrees(np.arctan2(float(y2 - y1_), float(x2 - x1)))
            if abs(angle) <= max_angle:
                rule_angles.append(angle)

    ys, xs = np.where(band < 95)
    poly_angle: Optional[float] = None
    if len(xs) >= 400:
        if len(xs) > 8000:
            rng = np.random.RandomState(0)
            pick = rng.choice(len(xs), 8000, replace=False)
            xs, ys = xs[pick], ys[pick]
        slope, _ = np.polyfit(xs.astype(np.float64), ys.astype(np.float64), 1)
        poly_angle = float(np.degrees(np.arctan(slope)))
        if abs(poly_angle) > max_angle:
            poly_angle = None

    candidates = []
    if rule_angles:
        candidates.append(float(np.median(rule_angles)))
    if poly_angle is not None:
        candidates.append(poly_angle)

    if candidates:
        return float(sorted(candidates, key=lambda a: abs(a))[-1])

    # Fallback: global near-horizontal Hough
    blurred = cv2.GaussianBlur(gray, (5, 5), 0)
    edges = cv2.Canny(blurred, 50, 150, apertureSize=3)
    lines = cv2.HoughLinesP(
        edges, 1, np.pi / 180, 80,
        minLineLength=int(w * 0.15), maxLineGap=25,
    )
    if lines is None:
        return None
    angles = []
    for x1, y1_, x2, y2 in lines.reshape(-1, 4):
        angle = np.degrees(np.arctan2(float(y2 - y1_), float(x2 - x1)))
        if abs(angle) <= max_angle:
            angles.append(angle)
    if len(angles) < 5:
        return None
    return float(np.median(angles))


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
