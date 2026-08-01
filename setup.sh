#!/usr/bin/env bash
# setup.sh — Compile the Swift Vision detector binary and install Python deps.
# Run this ONCE before using the tool.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DETECTOR_DIR="$SCRIPT_DIR/detector"
BINARY="$DETECTOR_DIR/detect"
SWIFT_SRC="$DETECTOR_DIR/detect.swift"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Document Auto-Crop Tool — Setup"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── 1. Check macOS version ──────────────────
MACOS_MAJOR=$(sw_vers -productVersion | cut -d. -f1)
if [ "$MACOS_MAJOR" -lt 13 ]; then
    echo "❌  macOS 13 (Ventura) or later required. You have $(sw_vers -productVersion)."
    exit 1
fi
echo "✅  macOS $(sw_vers -productVersion) detected"

# ── 2. Check swiftc ─────────────────────────
if ! command -v swiftc &>/dev/null; then
    echo "❌  swiftc not found. Install Xcode Command Line Tools:"
    echo "    xcode-select --install"
    exit 1
fi
echo "✅  swiftc found: $(swiftc --version | head -1)"

# ── 3. Compile Swift binary ─────────────────────────────────────────────────
echo ""
echo "⚙️   Compiling Swift Vision detector..."

# Use xcrun to match the active Xcode/CLT SDK with its bundled compiler,
# avoiding the SDK mismatch that occurs with a bare 'swiftc' call.
# -module-cache-path points to a writable location inside the project.
MODULE_CACHE="$SCRIPT_DIR/.module-cache"
mkdir -p "$MODULE_CACHE"

xcrun swiftc "$SWIFT_SRC" \
    -framework Vision \
    -framework Foundation \
    -framework CoreImage \
    -module-cache-path "$MODULE_CACHE" \
    -O \
    -o "$BINARY"
echo "✅  Vision detector compiled → $BINARY"

ENHANCER_DIR="$SCRIPT_DIR/enhancer"
ENHANCER_BIN="$ENHANCER_DIR/enhance"
ENHANCER_SRC="$ENHANCER_DIR/enhance.swift"

echo "⚙️   Compiling Swift CoreImage enhancer..."
rm -f "$ENHANCER_BIN"
xcrun swiftc "$ENHANCER_SRC" \
    -framework Foundation \
    -framework CoreImage \
    -framework ImageIO \
    -framework CoreGraphics \
    -module-cache-path "$MODULE_CACHE" \
    -O \
    -o "$ENHANCER_BIN"
echo "✅  CoreImage enhancer compiled → $ENHANCER_BIN"


# ── 4. Python deps ──────────────────────────
echo ""
echo "⚙️   Installing Python dependencies..."
python3 -m pip install -q opencv-python pillow img2pdf watchdog pyyaml
echo "✅  Python dependencies installed"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Setup complete! Usage:"
echo ""
echo "  Single image:"
echo "    python batch.py --input photo.jpg --output ./output/"
echo ""
echo "  Entire folder:"
echo "    python batch.py --input ./photos/ --output ./output/"
echo ""
echo "  Custom border expansion (default 4%):"
echo "    python batch.py --input ./photos/ --expansion 6"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
