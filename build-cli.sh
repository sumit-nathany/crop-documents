#!/usr/bin/env bash
# Build the Swift Mac CLI and symlink it into the project root as ./crop-documents.
#
# Release mode matters here: the pipeline runs hand-written pixel loops (edge
# detection, morphology, Hough), and -Onone makes them roughly an order of
# magnitude slower.
set -euo pipefail

cd "$(dirname "$0")"
PACKAGE="ios/DocumentCropCore"

echo "🔨  Building crop-documents (release)…"
swift build --package-path "$PACKAGE" -c release --product crop-documents

BIN="$(swift build --package-path "$PACKAGE" -c release --show-bin-path)/crop-documents"
ln -sf "$BIN" ./crop-documents

echo "✅  Built → ./crop-documents"
echo
echo "    ./crop-documents --help"
echo "    ./crop-documents --input ./photos/"
echo
echo "    To use it from anywhere:  sudo ln -sf \"$PWD/crop-documents\" /usr/local/bin/"
