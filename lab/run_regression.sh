#!/usr/bin/env bash
# lab/run_regression.sh — Compare crop variants for deskew/rotation tuning.
#
# Reads images from lab/cases/, writes lab/out/<variant>/.
# Replaces the Python run_regression.py; drives the Swift CLI so the harness
# exercises the same engine the app ships.
#
#   ./lab/run_regression.sh
#   ./lab/run_regression.sh --variants crop,deskew
#   ./lab/run_regression.sh --expansion 6
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CASES="$ROOT/lab/cases"
OUT="$ROOT/lab/out"
CLI="$ROOT/crop-documents"

VARIANTS="crop,deskew,rotate,deskew_rotate"
EXPANSION=4

while [[ $# -gt 0 ]]; do
    case "$1" in
        --variants)  VARIANTS="$2"; shift 2 ;;
        --expansion) EXPANSION="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,12p' "$0" | sed 's/^# \?//'
            exit 0 ;;
        *) echo "❌  Unknown option: $1  (try --help)" >&2; exit 2 ;;
    esac
done

if [[ ! -x "$CLI" ]]; then
    echo "❌  $CLI not found. Run ./build-cli.sh first." >&2
    exit 1
fi

shopt -s nullglob nocaseglob
IMAGES=("$CASES"/*.jpg "$CASES"/*.jpeg "$CASES"/*.png "$CASES"/*.tiff "$CASES"/*.tif "$CASES"/*.heic "$CASES"/*.heif)
shopt -u nullglob nocaseglob

if [[ ${#IMAGES[@]} -eq 0 ]]; then
    echo "⚠️  No images in $CASES/"
    echo "   Copy hard cases there (jpg/png/heic), then re-run."
    exit 0
fi

echo "📂  ${#IMAGES[@]} case(s) in $CASES/"

# variant name → extra CLI flags
flags_for() {
    case "$1" in
        crop)          echo "" ;;
        deskew)        echo "--deskew" ;;
        rotate)        echo "--rotate" ;;
        deskew_rotate) echo "--deskew --rotate" ;;
        *) echo "__UNKNOWN__" ;;
    esac
}

IFS=',' read -ra NAMES <<< "$VARIANTS"
for name in "${NAMES[@]}"; do
    name="$(echo "$name" | xargs)"
    [[ -z "$name" ]] && continue

    extra="$(flags_for "$name")"
    if [[ "$extra" == "__UNKNOWN__" ]]; then
        echo "❌  Unknown variant: $name. Choose from: crop, deskew, rotate, deskew_rotate" >&2
        exit 1
    fi

    dest="$OUT/$name"
    rm -rf "$dest"
    mkdir -p "$dest"

    echo
    echo "━━━ variant: $name → $dest/ ━━━"
    # shellcheck disable=SC2086 # $extra is intentionally word-split into flags
    "$CLI" --input "$CASES" --output "$dest" --expansion "$EXPANSION" $extra || true
done

echo
echo "✅  Compare outputs under $OUT/"
