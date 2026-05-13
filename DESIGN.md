# Window Observer Design

## Overview

This project implements a macOS native window observer that continuously emits a structured event stream for a chosen set of in-scope windows. The implementation uses a hybrid design:

- Quartz window enumeration for visual truth: what surfaces are currently visible on screen.
- Accessibility (AX) APIs for semantic enrichment: focus, title, position, size, minimized state, and selected window/app notifications.
- A reconciler that merges Quartz snapshots and AX hints into a canonical window state and produces JSON events plus an ASCII debug view.

The goal is not to reconstruct every possible macOS surface perfectly. The goal is to produce a useful, low-latency, well-documented event stream for representative user-facing windows while degrading gracefully under normal-user privileges.

## Architecture

The runtime is organized as a small hybrid pipeline.

1. **Main runtime / run loop**
   - Starts the process.
   - Installs signal handling for Ctrl+C.
   - Starts AX observers.
   - Starts a repeating Quartz sampling timer at approximately 50 ms.
   - Shuts down cleanly by removing observers and stopping timers.

2. **Quartz sampler**
   - Uses `CGWindowListCopyWindowInfo` to enumerate currently visible window surfaces.
   - Extracts window ID, process ID, owner name, title when available, bounds, layer, and on-screen state.
   - Acts as the main source of truth for what is visually present right now.

3. **Visual filter / scope classifier**
   - Applies a single in-scope rule to both the initial snapshot and live tracking.
   - Excludes shell/compositor noise and obviously non-user-facing surfaces.
   - Keeps the event stream focused on windows that matter to a user-facing observer.

4. **AX semantic enrichment**
   - Uses Accessibility APIs to read richer window semantics such as title, position, size, minimized state, role/subrole, and focus.
   - Registers for AX notifications where available, especially around focused window changes and selected window lifecycle updates.
   - Helps classify and interpret windows that Quartz alone cannot describe reliably.

5. **Reconciler / state model**
   - Maintains the current known set of in-scope windows.
   - Diffs current Quartz state against previous state to detect create/destroy/move/resize/show/hide changes.
   - Merges in AX-derived information and notifications.
   - Resolves foreground changes by matching focused AX windows back to known Quartz windows using PID + title + bounds proximity.
   - Detects minimized/restored state using AX because minimized windows may disappear from Quartz on-screen listings.

6. **Output layer**
   - Emits one JSON object per event to stdout and/or JSONL log file.
   - Optionally renders an ASCII scene in the terminal for development/debugging.
   - Keeps machine output and human-debug output separate.

## Detection mechanism

The implementation deliberately uses a hybrid mechanism rather than a single API.

### Why Quartz

Quartz window enumeration is the simplest public API for asking: “what visible windows exist right now?” It provides stable visual identifiers, bounds, owner process IDs, and other surface metadata for visible windows.

Quartz is therefore the best source for:

- Initial snapshot of visible in-scope windows.
- Low-latency polling of visual changes.
- Stable visual identity for windows currently present on screen.

### Why AX

Quartz alone is not sufficient for the full exercise. In particular:

- Focus/foreground changes are more naturally available through AX.
- Minimized windows may disappear from the visible Quartz list.
- Some semantic properties are better exposed via AX, including minimized state and role/subrole.
- AX can provide notifications that reduce reliance on pure polling for some changes.

AX is therefore used for:

- Focused window tracking.
- Minimized/restored detection.
- Additional semantic attributes.
- Best-effort window lifecycle hints.

### Why not AX alone

AX is not a complete replacement for Quartz.

- AX window coverage and notifications vary across apps and window types.
- AX does not provide a clean public one-step mapping to the Quartz window ID used in visible window enumeration.
- The exercise requires a practical observer under default user privileges, so relying entirely on AX would make visual presence and identity less robust.

### Why not polling alone

A pure polling design could detect many changes, but would be weaker for focus and minimized state and would require more inference. A hybrid approach keeps polling simple and bounded while using AX where semantics matter most.

## State model

The observer maintains a canonical set of known windows.

### Primary identity

For visible windows, the primary identity is the Quartz window ID.

Each record stores:

- Window ID.
- Process ID.
- Owner name.
- Executable name and bundle identifier when available.
- Title when available.
- Bounds.
- Visibility/on-screen state.
- Additional derived state such as foreground/minimized.

### AX to Quartz matching

Public macOS APIs do not provide a reliable, direct, public bridge from AX window references to Quartz window IDs. The implementation therefore matches AX windows back to Quartz windows heuristically using:

- PID equality.
- Title equality or normalized title similarity.
- Bounds proximity using AX position/size vs Quartz bounds.

This heuristic is sufficient for representative user-facing windows, but it is explicitly documented as best effort.

### Startup behavior

At startup:

1. Enumerate visible windows through Quartz.
2. Apply the filter rule.
3. Seed the canonical state.
4. Emit a `snapshot` event.
5. Register AX observers for currently running regular apps.
6. Refresh semantic state such as foreground/minimized.

This ordering avoids a gap where events are emitted before the observer has a baseline state.

### Duplicate reduction

To avoid flooding on rapidly changing titles, title changes are debounced over a small interval. This keeps the stream useful during bursty updates such as browser download progress or rapidly changing tab titles.

## Filter rule

The observer reports windows that are meaningful user-facing surfaces using a conservative baseline plus an explicit whitelist for common panel-like windows that users interact with.

### Baseline

- By default accept normal application windows in the normal (layer 0) window layer.
- Require the window to be on-screen, have a non-empty owner name, and meet a minimum size threshold (the code uses 120×80 as the baseline).
- Exclude obvious shell/compositor noise by owner name (Dock, Window Server, Control Center, Notification Center).

### Special-window whitelist (heuristics)

To surface key transient UI that is often task-relevant, the implementation heuristically includes a small set of special windows even when they are not in layer 0. These are included conservatively using owner-name and title heuristics:

- Spotlight / launcher overlays: detected by owner name keywords such as `Spotlight` or `Launchpad`.
- File open / save panels and choosers: detected by window name/title keywords such as `Open`, `Save`, `Save As`, `Choose`, `Chooser`, or `Print`.
- Sheets, modal dialogs, and alerts: detected by title keywords like `Sheet`, `Alert`, `Dialog` or by short non-empty titles common to modal panels (`Preferences`, `Inspector`, `Panel`).
- App utility panels (Preferences, Inspectors): included when the title is a short, non-empty string (conservative length check in code) and the owner is a regular app.

These heuristics are intentionally conservative: they require either a recognizable owner keyword or meaningful title text to avoid pulling in stray compositor overlays.

### Excluded categories

- Dock, Window Server (compositor surfaces), Control Center, Notification Center remain excluded.
- Very small windows (under the minimum size) and owner-less surfaces are excluded.

### Rationale and limitations

- The whitelist is heuristic and best-effort: it improves inclusion of common task-relevant panels but cannot guarantee coverage for all apps or system UI variants.
- Some system-provided overlays or third-party panels may be missed or falsely included depending on owner/title conventions.
- AX-based enrichment is still used to detect minimized/restored state and to reconcile focused windows; the whitelist only affects the Quartz-derived in-scope filter.


## Event schema

The output format is one JSON object per line.

Representative event types:

- `snapshot`
- `window_created`
- `window_destroyed`
- `moved`
- `resized`
- `title_changed`
- `foreground_changed`
- `minimized`
- `restored`
- `shown`
- `hidden`
- `note` (internal lifecycle/debug note)

Representative fields:

- `timestamp`
- `eventType`
- `windowID`
- `pid`
- `ownerName`
- `executableName`
- `bundleIdentifier`
- `title`
- `bounds`
- `windows` (for snapshot)
- `note` (for lifecycle/debug notes)

## ASCII debug view

The observer also includes a terminal ASCII renderer for manual debugging.

It shows:

- Approximate visible layout of in-scope windows.
- Foreground window indicator.
- Minimized window list/pills.
- Legend mapping symbols to windows.

This output is not part of the required machine interface. It exists to help inspect behavior during development and validation.

## Privileges and runtime assumptions

The program runs as a normal user process.

On macOS, AX enrichment requires Accessibility permission to be enabled for the executing app or terminal session. This is documented as part of setup. The observer should continue to degrade gracefully where data is unavailable, emitting partial events rather than crashing.

## Failure modes and limitations

Several macOS-specific limitations are expected and documented.

1. **No perfect AX-to-Quartz bridge**
   - Matching focused/minimized AX windows back to visible Quartz windows is heuristic.
   - This may fail for unusual windows with unstable titles or rapidly changing bounds.

2. **Coverage varies across window types**
   - AX notification support is not uniform across all applications.
   - Some apps or transient surfaces may emit incomplete semantic data.

3. **Mission Control Spaces**
   - Cross-Space inventory is out of scope because modern public APIs do not expose a reliable full model of windows on other Spaces/desktops.

4. **Special shell panels**
   - Some panel-like windows such as Spotlight or similar overlays may need explicit heuristic treatment.
   - The implementation prefers a useful, documented rule over pretending full shell coverage.

5. **Current-monitor only assumption in debug presentation**
   - Multi-monitor visualization is deferred.
   - The current design focuses on a single combined visible scene.

6. **Burst behavior remains best effort**
   - Title debouncing reduces noise but does not attempt perfect semantic compression.

## Explicit out-of-scope items

The current submission intentionally does not attempt to solve:

- Cross-Space / other-desktop tracking.
- Full multi-monitor modeling in JSON/ASCII.
- Audio/media semantic analysis.
- Deep content understanding of what a window contains.

## Exit criteria

The project is considered complete enough for submission when all of the following are true:

### Functional criteria

- Startup emits a correct `snapshot` of in-scope windows.
- Live tracking emits all required event classes in representative cases:
  - created
  - destroyed
  - moved
  - resized
  - title changed
  - foreground changed
  - minimized
  - restored
  - shown
  - hidden
- Event output is one JSON object per line.
- The observer normally reacts within approximately 50 ms for move/resize/focus interactions.
- Ctrl+C exits cleanly within 1 second and unregisters hooks/observers.

### Quality criteria

- Filter rule is documented and consistently applied.
- At least three excluded window categories are documented with rationale.
- Burst title updates do not flood the stream with unusable duplicates.
- Missing AX data does not crash the process.
- Logs/debug output are understandable enough to inspect manually.

### Deliverable criteria

- Repo structure is no longer monolithic enough to block readability.
- README contains build, run, setup, schema, and scope information.
- Design document explains architecture, detection, state model, filter, failure modes, portability, and AI usage.
- Manual validation notes exist and reflect real observed behavior.

## Manual validation plan

Manual validation is used to verify representative behavior and document differences across window types.

### Case 1: Startup snapshot

**Setup**
- Open several normal app windows before starting the observer.

**Actions**
- Launch the observer.

**Check**
- One `snapshot` event is emitted at startup.
- The snapshot includes only in-scope windows.
- Excluded shell surfaces do not dominate the snapshot.
- ASCII debug view roughly matches the visible scene.

### Case 2: Window created / destroyed

**Setup**
- Start the observer.

**Actions**
- Open a Finder/Safari/Terminal window.
- Close it.

**Check**
- `window_created` appears once for the new in-scope window.
- `window_destroyed` appears once when it closes.
- No duplicate bursts appear for a simple open/close action.

### Case 3: Move and resize latency

**Setup**
- Start the observer with one normal app window visible.

**Actions**
- Drag the window around.
- Resize the window continuously.

**Check**
- `moved` and `resized` events appear during interaction.
- Observed latency feels near the target of approximately 50 ms.
- The stream remains understandable rather than exploding into clearly redundant noise.
- ASCII view updates in a visually plausible way.

### Case 4: Foreground / focus change

**Setup**
- Have at least two visible app windows.

**Actions**
- Switch focus between them by clicking and by app switching.

**Check**
- `foreground_changed` is emitted for the focused window.
- Foreground in ASCII matches the active window.
- Foreground changes are not repeatedly emitted when focus has not really changed.

### Case 5: Minimize / restore

**Setup**
- Start with one or more normal app windows visible.

**Actions**
- Minimize a window.
- Restore it.

**Check**
- `minimized` appears when the window is minimized.
- `restored` appears when it returns.
- The minimized window remains represented in debug state as intended.
- Restoration returns it to visible layout tracking.

### Case 6: Title burst behavior

**Setup**
- Use a browser tab or other window with rapidly changing title text.

**Actions**
- Trigger a title that updates quickly, such as download progress or loading progress.

**Check**
- `title_changed` events are emitted, but not at unusable near-frame rates.
- Debounce behavior visibly reduces floods.
- Final titles still converge to current state.

### Case 7: Special window categories

**Setup**
- Exercise several window families, for example:
  - standard document windows
  - browser windows
  - utility/floating windows
  - Spotlight-like or panel-like windows

**Actions**
- Interact with each type.

**Check**
- Document which are included/excluded.
- Note any differences in event quality or semantic richness.
- Verify that unusual windows fail gracefully rather than destabilizing the observer.

### Case 8: Accessibility disabled / partial access

**Setup**
- Run without AX permission, or temporarily test a reduced-permission scenario if practical.

**Actions**
- Launch and interact with normal windows.

**Check**
- The process does not crash.
- Quartz-derived events still work as far as possible.
- Missing semantic fields are absent/partial rather than fatal.
- README/setup instructions clearly explain the requirement.

### Case 9: Clean shutdown

**Setup**
- Run the observer normally.

**Actions**
- Press Ctrl+C.

**Check**
- Process exits within about 1 second.
- No hanging timers or run-loop activity remain.
- Final logs are flushed as expected.

## Validation notes template

During testing, capture notes in a lightweight format such as:

- **Case**: Move and resize latency
- **Apps tested**: Finder, Safari, VS Code
- **Observed behavior**: Moved/resized events emitted continuously; foreground stayed correct; no crash.
- **Issue seen**: Spotlight not included by default filter.
- **Resolution**: Keep out of scope or special-case as documented.

These notes are useful for the README/design doc and for the follow-up conversation.

## Porting note

The design intentionally separates visual enumeration, semantic enrichment, reconciliation, filtering, and output. That makes the architecture portable even though the APIs are not.

A Windows port would likely keep:

- The same canonical state model.
- The same event taxonomy.
- The same diff/reconciliation layer.
- The same JSON and ASCII outputs.

What would change is the source of visual and semantic data, the event loop integration, and the platform-specific heuristics for window scope and lifecycle semantics.

## Future improvements

Potential future work includes:

1. Multi-monitor modeling in JSON and ASCII.
2. Better panel/special-window heuristics.
3. Content-aware classification, such as text-rich vs image-rich windows.
4. Higher-level contextual timeline inference, such as likely task transitions.
5. Lightweight latency instrumentation rather than purely observational validation.