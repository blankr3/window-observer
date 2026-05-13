# window-observer

A small macOS command-line observer that emits JSON events describing user-facing windows. Uses Quartz (CGWindowList) for visual truth and Accessibility (AX) APIs for semantic enrichment (focus, minimized state, titles).

## Build & run

- Build: `swift build`
- Run: `swift run`
- Test (full): `swift test`
- Run a single test: `swift test --filter <name-or-substring>` (e.g. `swift test --filter example`)

## What is "in scope"?

The observer reports windows that are likely to be meaningful to the user. Scope is determined by a conservative baseline plus a small heuristic whitelist for common panel-like windows:

Baseline rules:
- Layer 0 (normal app windows) are accepted.
- Window must be on-screen, have a non-empty owner name, and meet a minimum size (120×80).
- Excluded owners: `Dock`, `Window Server`, `Control Center`, `Notification Center`.

Special-window whitelist (heuristics):
- Spotlight / Launchpad overlays (owner name keywords).
- Open/Save file panels and choosers (title keywords: `Open`, `Save`, `Save As`, `Choose`, `Chooser`, `Print`).
- Sheets, alerts, and modal dialogs (title keywords: `Sheet`, `Alert`, `Dialog`, `Preferences`, `Inspector`, `Panel`).
- Short non-empty titles from regular apps (conservative length check) are included as likely utility panels.

Detection is conservative and based on Quartz-exposed metadata (owner name and window title). Earlier attempts to use AX role/subrole or deep AX child inspection to identify Save/Open panels were reverted due to reliability concerns; the current behavior uses the title/owner heuristics implemented in `Sources/window-observer/Utilities.swift::isInScope(_:)`.

## Known limitations

- The whitelist is heuristic and best-effort; some special windows may be missed or misclassified depending on app-specific names.
- AX → Quartz matching remains heuristic (PID + normalized title + bounds proximity) and can fail for unusual windows.
- Multi-monitor and cross-space edge cases are intentionally out of scope for now.

## Manual validation (quick)

1. Start the observer: `swift run`.
2. Verify startup `snapshot` event is emitted and contains expected windows.
3. Open an app file dialog (File → Open) and confirm the Open panel appears in the event stream.
4. Minimize and restore a window; confirm `minimized` and `restored` events are emitted.
5. Use Spotlight and confirm its window is included when visible.

If behavior differs from expectations, check Accessibility permission and inspect `window-observer-debug.txt` for ASCII debug output.
