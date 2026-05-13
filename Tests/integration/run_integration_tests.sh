#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EVENT_FILE="$ROOT/window-observer-events.jsonl"
DEBUG_FILE="$ROOT/window-observer-debug.txt"
BUILD_BIN="$ROOT/.build/debug/window-observer"

# Build if needed
if [ ! -x "$BUILD_BIN" ]; then
  echo "Building..."
  swift build
fi

rm -f "$EVENT_FILE" "$DEBUG_FILE"

# Start observer in background
"$BUILD_BIN" > "$EVENT_FILE" 2>&1 &
OB_PID=$!
echo "observer pid=$OB_PID"

sleep 1

cases_passed=0
cases_failed=0

report_case() {
  local name="$1"; local pass="$2"; local msg="$3"
  if [ "$pass" = true ]; then
    echo "[PASS] $name: $msg"
    cases_passed=$((cases_passed+1))
  else
    echo "[FAIL] $name: $msg"
    cases_failed=$((cases_failed+1))
  fi
}

# Helper to grep JSONL for eventType and ownerName (single-line JSON per event)
check_event() {
  local etype="$1"; local owner="$2"
  if grep -E "\"eventType\"\s*:\s*\"$etype\".*\"ownerName\"\s*:\s*\"$owner\"" "$EVENT_FILE" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# Case 1: Create a TextEdit window
echo "Case: Create TextEdit window"
# Activate TextEdit and create new document
osascript -e 'tell application "TextEdit" to activate' -e 'tell application "System Events" to keystroke "n" using {command down}' || true
sleep 2
if check_event "window_created" "TextEdit"; then
  report_case "create-textedit" true "found window_created for TextEdit"
else
  report_case "create-textedit" false "no window_created event for TextEdit in $EVENT_FILE"
fi

# Case 2: Destroy TextEdit window (close)
echo "Case: Close TextEdit window"
osascript -e 'tell application "System Events" to keystroke "w" using {command down}' || true
sleep 2
# Some apps may keep a document (unsaved) prompting dialog instead of closing; attempt quit
osascript -e 'tell application "TextEdit" to close front document saving no' || true
sleep 1
if check_event "window_destroyed" "TextEdit"; then
  report_case "destroy-textedit" true "found window_destroyed for TextEdit"
else
  report_case "destroy-textedit" false "no window_destroyed event for TextEdit in $EVENT_FILE"
fi

# Case 3: Open Save dialog from TextEdit (File -> Save As)
# Re-open a document and trigger Save As
osascript -e 'tell application "TextEdit" to activate' -e 'tell application "System Events" to keystroke "n" using {command down}' || true
sleep 1
# capture byte offset to search only new events
offset=$(wc -c < "$EVENT_FILE" || echo 0)
# Trigger Save dialog
osascript -e 'tell application "System Events" to keystroke "s" using {command down}' || true
sleep 2
# Check new lines for a TextEdit-related event (window_created or ax_notification)
if tail -c +$((offset+1)) "$EVENT_FILE" 2>/dev/null | grep -E '"ownerName"\s*:\s*"TextEdit"' >/dev/null 2>&1; then
  # If any new event for TextEdit exists, consider Save panel observed (best-effort)
  report_case "save-panel" true "found TextEdit event after triggering Save"
else
  report_case "save-panel" false "no TextEdit events detected after triggering Save"
fi

# Case 4: Minimize and restore a TextEdit window
# Create a window again
osascript -e 'tell application "TextEdit" to activate' -e 'tell application "System Events" to keystroke "n" using {command down}' || true
sleep 1
# Minimize via System Events
osascript -e 'tell application "System Events" to tell process "TextEdit" to set value of attribute "AXMinimized" of window 1 to true' || true
sleep 1
# Check minimized event
if grep -E '"eventType"\s*:\s*"minimized"' "$EVENT_FILE" >/dev/null 2>&1; then
  report_case "minimized" true "found minimized event"
else
  report_case "minimized" false "no minimized event found"
fi
# Restore
osascript -e 'tell application "System Events" to tell process "TextEdit" to set value of attribute "AXMinimized" of window 1 to false' || true
sleep 1
if grep -E '"eventType"\s*:\s*"restored"' "$EVENT_FILE" >/dev/null 2>&1; then
  report_case "restored" true "found restored event"
else
  report_case "restored" false "no restored event found"
fi

# Teardown: kill observer
kill $OB_PID >/dev/null 2>&1 || true
sleep 1

# Summary
echo
echo "Summary: passed=$cases_passed failed=$cases_failed"
if [ $cases_failed -eq 0 ]; then
  echo "ALL PASSED"
  exit 0
else
  echo "SOME FAILED"
  exit 2
fi
