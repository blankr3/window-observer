# Copilot instructions for window-observer

This file gives repository-specific guidance for Copilot-powered sessions: how to build/test/run the project, the high-level architecture, and repository-specific conventions Copilot should follow.

---

## Build, test, and lint commands

- Build: `swift build` (uses Swift Package Manager; package defined in Package.swift).
- Run (CLI): `swift run` (runs the executable target `window-observer`).
- Test (full suite): `swift test`.
- Run a single test: `swift test --filter <name-or-substring>` — supply a test case name or test function name (e.g. `swift test --filter example`).
- Xcode: open `Package.swift` to import the package into Xcode.

Linting: No repository-level linter configuration was found (no `.swiftlint.yml` or similar). If adding linters, update this file with the commands and config locations.

---

## High-level architecture

- This is a macOS command-line Swift package (Package.swift) targeting macOS 13+. The main executable target is `window-observer`.
- Purpose: observe macOS windows using CoreGraphics window list and Accessibility (AX) APIs, emit events as JSONL to stdout and append to a local events file, and optionally render a debug ASCII layout to a debug log.
- Key runtime components (in Sources/window-observer/window_observer.swift):
  - WindowRecord/WindowBounds/EventPayload: Codable models representing windows and emitted events.
  - WindowObserverApp (singleton): coordinates polling, AX observer registration, workspace notifications, foreground/minimized state, debouncing title changes, and emits events.
  - AXObserverManager: manages AXObserver instances per PID and registers AX notifications for app/window lifecycle and property changes.
  - DebugLog + ascii rendering: writes a human-readable debug trace and an ASCII layout of windows for debugging.
  - Utilities: mapping between AX window snapshots and CGWindow info, parsing bounds, and helper functions.
- Runtime behavior:
  - On start the app emits a `snapshot` event (JSON) containing current in-scope windows.
  - It maintains `knownWindows`, polls CGWindowList every 50ms, and also listens to AX and workspace notifications for more immediate updates.
  - Events are encoded with ISO8601 timestamps and written to STDOUT and to `window-observer-events.jsonl` in the current working directory. Debug ASCII/log written to `window-observer-debug.txt`.

---

## Key conventions and repository specifics for Copilot

- macOS + Accessibility:
  - This tool requires macOS Accessibility permission for the running process (grant access to Terminal or the built binary in System Settings → Privacy & Security → Accessibility).
  - Package.swift declares `.macOS(.v13)` — do not suggest changes that break this constraint without explicit user approval.

- Output & logs:
  - Two files are created in the current working directory at runtime: `window-observer-debug.txt` (human/readable debug) and `window-observer-events.jsonl` (newline-delimited JSON records). Copilot-based changes that alter these filenames or formats should also update any code paths and docs that reference them.
  - The OptionSet `OutputMode` at the top of Sources/window-observer/window_observer.swift controls whether JSON and/or debug ASCII are emitted. For testability, prefer making this configurable rather than hardcoding when proposing changes.

- Event model stability:
  - EventPayload is Codable and used for persisted JSONL output. Keep schema-compatible changes minimal and consider migration strategies if altering fields (e.g., add new optional fields rather than renaming/removing).

- Window selection and filtering:
  - Windows are filtered by `isInScope(_:)` (owner name exclusions, layer==0, minimum size thresholds). When suggesting changes that affect scope, verify cross-checks with parseBounds and CGWindow keys.

- Matching AX -> CG windows:
  - The code matches AX snapshots to CG windows using pid, normalized titles, and a bounding-box distance heuristic (threshold 80). Don't replace this logic without tests demonstrating improved matching on real window data.

- Concurrency and main-thread assumptions:
  - Many Accessibility and AppKit calls are made on the main actor. Keep main-thread/@MainActor constraints and RunLoop usage in mind when refactoring.

- Tests:
  - Tests are present but minimal (Tests/window-observerTests/window_observerTests.swift contains a placeholder `example` test). When adding or editing tests, use `swift test --filter` to run specific cases.

---

## Files and artifacts Copilot should pay attention to

- Sources/window-observer/window_observer.swift — single-file executable; most logic is here.
- Package.swift — defines the package and macOS minimum.
- Tests/window-observerTests/window_observerTests.swift — test entry.
- .gitignore — ignores build artifacts and Xcode-derived files; avoid committing those.

---

## Guidance for automated edits

- Changing CLI behavior (output format, filenames, flags) should include updating the place where OutputMode and filenames are defined (top of window_observer.swift) and tests or README if added.
- For changes touching Accessibility or AppKit interactions, preserve @MainActor annotations and CFRunLoop/AXObserver lifecycles.
- For performance-sensitive changes (e.g., polling frequency), keep default 50ms polling and explain trade-offs; expose as a runtime-configurable parameter if suggesting changes.

---

If additional repository docs (README/CONTRIBUTING) are added later, incorporate their authoritative guidance into this file. Update this file when adding linters, CI, or project-level config.

