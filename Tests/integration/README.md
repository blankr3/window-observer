Integration tests (run_integration_tests.sh)

These tests control the macOS GUI using AppleScript/System Events. Requirements:

- Run on macOS with a logged-in GUI session.
- The test runner (Terminal) must have Accessibility permission in System Settings → Privacy & Security → Accessibility so that System Events and osascript can control apps.

Run:

  chmod +x Tests/integration/run_integration_tests.sh
  Tests/integration/run_integration_tests.sh

The script starts the built `window-observer` binary, performs UI actions with TextEdit to create/close/minimize/restore windows, greps the `window-observer-events.jsonl` file, and reports results.

Notes:
- Tests are best-effort: different macOS versions or TextEdit behavior may require small timing or script changes.
