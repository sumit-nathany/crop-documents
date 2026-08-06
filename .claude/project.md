# Claude project notes

Canonical context lives in `/CLAUDE.md` and `.cursor/rules/`. Prefer those over duplicating long docs here.

Architecture: one shared Swift engine (`ios/DocumentCropCore`) behind two thin front ends —
the Mac CLI (`ios/DocumentCropCore/Sources/CropDocumentsCLI`) and the iPhone app (`ios/Margin`).
Pixel changes go in the engine, never in a front end.

Priorities: close the `--deskew` trim parity gap (last blocker before retiring the Python
reference implementation) → re-verify auto-rotate on device → Mac GUI deferred.
