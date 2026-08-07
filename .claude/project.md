# Claude project notes

Canonical context lives in `/CLAUDE.md` and `.cursor/rules/`. Prefer those over duplicating long docs here.

Architecture: one shared Swift engine (`ios/DocumentCropCore`) behind two thin front ends —
the Mac CLI (`ios/DocumentCropCore/Sources/CropDocumentsCLI`) and the iPhone app (`ios/Margin`).
Pixel changes go in the engine, never in a front end.

Priority: re-verify deskew and auto-rotate **on a real device**. Both are verified on Mac
against `lab/cases/`, and neither has held up on-device before — that is the open unknown,
and why `straighten` is off and hidden in the iOS UI. Mac GUI deferred.
