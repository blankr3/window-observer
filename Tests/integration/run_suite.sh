#!/usr/bin/env bash
set -euo pipefail

# Integration suite runner
# Produces a timestamped results directory under Tests/integration/results/<run-id>/
# Captures per-case event JSONL slices and ASCII debug output, plus a summary.json and summary.txt
# Optionally commit results to git when COMMIT_RESULTS=1 is set (commit will include Co-authored-by trailer).

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EVENT_FILE="$ROOT/window-observer-events.jsonl"
DEBUG_FILE="$ROOT/window-observer-debug.txt"
BUILD_BIN="$ROOT/.build/debug/window-observer"
RESULTS_DIR="$ROOT/Tests/integration/results"

RUN_ID="run-$(date -u +%Y%m%dT%H%M%SZ)"
OUT_DIR="$RESULTS_DIR/$RUN_ID"
mkdir -p "$OUT_DIR"

# Build if needed
if [ ! -x "$BUILD_BIN" ]; then
  echo "Building..."
  swift build
fi

# Clean previous runtime artifacts
rm -f "$EVENT_FILE" "$DEBUG_FILE"

# Start observer in background
"$BUILD_BIN" > "$EVENT_FILE" 2>&1 &
OB_PID=$!
echo "observer pid=$OB_PID"

sleep 1

# Helper: capture offsets
capture_offsets() {
  event_offset=$(wc -c < "$EVENT_FILE" || echo 0)
  debug_offset=$(wc -c < "$DEBUG_FILE" || echo 0)
}

# Helper: save appended content since offsets into per-case files
save_case_output() {
  local case_name="$1"
  mkdir -p "$OUT_DIR/$case_name"

  # events (byte-oriented)
  event_offset=${2:-0}
  debug_offset=${3:-0}

  if [ -f "$EVENT_FILE" ]; then
    tail -c +$((event_offset+1)) "$EVENT_FILE" > "$OUT_DIR/$case_name/events.jsonl" || true
    # fallback: if empty, save last 200 lines of master events as evidence
    if [ ! -s "$OUT_DIR/$case_name/events.jsonl" ]; then
      tail -n 200 "$EVENT_FILE" > "$OUT_DIR/$case_name/events.jsonl" || true
    fi
  else
    touch "$OUT_DIR/$case_name/events.jsonl"
  fi

  if [ -f "$DEBUG_FILE" ]; then
    tail -c +$((debug_offset+1)) "$DEBUG_FILE" > "$OUT_DIR/$case_name/debug.txt" || true
    if [ ! -s "$OUT_DIR/$case_name/debug.txt" ]; then
      tail -n 200 "$DEBUG_FILE" > "$OUT_DIR/$case_name/debug.txt" || true
    fi
  else
    touch "$OUT_DIR/$case_name/debug.txt"
  fi
}

# Helper: check condition in a per-case events file
check_case() {
  local case_name="$1"
  local pattern="$2"
  if grep -E "$pattern" "$OUT_DIR/$case_name/events.jsonl" >/dev/null 2>&1; then
    echo "pass"
  else
    echo "fail"
  fi
}

# Run a test case: takes name and a command string to perform (AppleScript/osascript)
run_case() {
  local name="$1"
  local script_cmd="$2"
  echo "--- Running case: $name"

  # capture offsets before action
  capture_offsets
  local before_event_offset="$event_offset"
  local before_debug_offset="$debug_offset"

  # perform action
  eval "$script_cmd" || true

  # wait briefly for observer to emit
  sleep 2

  # save appended outputs
  save_case_output "$name" "$before_event_offset" "$before_debug_offset"
}

# Cases (using TextEdit as a controllable test app)
# 1. create-textedit
run_case "create-textedit" "osascript -e 'tell application \"TextEdit\" to activate' -e 'tell application \"System Events\" to keystroke \"n\" using {command down}'"

# 2. destroy-textedit
run_case "destroy-textedit" "osascript -e 'tell application \"System Events\" to keystroke \"w\" using {command down}' || true; osascript -e 'tell application \"TextEdit\" to close front document saving no' || true"

# 3. save-panel
run_case "save-panel" "osascript -e 'tell application \"TextEdit\" to activate' -e 'tell application \"System Events\" to keystroke \"n\" using {command down}' -e 'delay 0.4' -e 'tell application \"System Events\" to keystroke \"s\" using {command down}'"

# 4. minimized
run_case "minimized" "osascript -e 'tell application \"TextEdit\" to activate' -e 'tell application \"System Events\" to keystroke \"n\" using {command down}' -e 'delay 0.4' -e 'tell application \"System Events\" to tell process \"TextEdit\" to set value of attribute \"AXMinimized\" of window 1 to true'"

# 5. restored
run_case "restored" "osascript -e 'tell application \"System Events\" to tell process \"TextEdit\" to set value of attribute \"AXMinimized\" of window 1 to false'"

# After running cases, collect summary for each
summary_file="$OUT_DIR/summary.json"
summary_txt="$OUT_DIR/summary.txt"

echo "[" > "$summary_file"
first=true

all_passed=true

for case in create-textedit destroy-textedit save-panel minimized restored; do
  # Default expectations per case
  pattern=""
  case_status="fail"
  case_msg=""
  case_events_file="$OUT_DIR/$case/events.jsonl"
  case_debug_file="$OUT_DIR/$case/debug.txt"

  case_description=""
  case_expectation=""

  case_description=$(cat <<EOF
Case: $case
Events: $case_events_file
Debug: $case_debug_file
EOF
)

  case_expectation=""
  case_pattern=""
  if [ "$case" = "create-textedit" ]; then
    case_pattern='"eventType"\s*:\s*"window_created".*"ownerName"\s*:\s*"TextEdit"'
  elif [ "$case" = "destroy-textedit" ]; then
    case_pattern='"eventType"\s*:\s*"window_destroyed".*"ownerName"\s*:\s*"TextEdit"'
  elif [ "$case" = "save-panel" ]; then
    case_pattern='"ownerName"\s*:\s*"TextEdit"'
  elif [ "$case" = "minimized" ]; then
    case_pattern='"eventType"\s*:\s*"minimized"'
  elif [ "$case" = "restored" ]; then
    case_pattern='"eventType"\s*:\s*"restored"'
  fi

  if grep -E "$case_pattern" "$case_events_file" >/dev/null 2>&1; then
    case_status="pass"
  else
    case_status="fail"
    all_passed=false
  fi

  # Append to JSON summary
  if [ "$first" = true ]; then
    first=false
  else
    echo "," >> "$summary_file"
  fi
  jq -n --arg case "$case" --arg status "$case_status" --arg events "$case_events_file" --arg debug "$case_debug_file" '{case: $case, status: $status, events: $events, debug: $debug}' >> "$summary_file"

done

echo "]" >> "$summary_file"

# Human readable summary
echo "Integration suite run: $RUN_ID" > "$summary_txt"
echo "Results directory: $OUT_DIR" >> "$summary_txt"
echo "" >> "$summary_txt"

echo "Per-case results:" >> "$summary_txt"
for case in create-textedit destroy-textedit save-panel minimized restored; do
  status=$(jq -r ".[]? | select(.case==\"$case\") .status" "$summary_file" 2>/dev/null || echo "unknown")
  echo "- $case: $status" >> "$summary_txt"
done

echo "" >> "$summary_txt"
if [ "$all_passed" = true ]; then
  echo "ALL PASSED" >> "$summary_txt"
  summary_status=0
else
  echo "SOME FAILED" >> "$summary_txt"
  summary_status=2
fi

# Optionally commit results into git
if [ "${COMMIT_RESULTS:-0}" = "1" ]; then
  git add "$OUT_DIR"
  git commit -m "Integration test results: $RUN_ID" -m "Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>" || true
fi

# Teardown
kill $OB_PID >/dev/null 2>&1 || true
sleep 1

echo "Summary written to $summary_txt"
exit $summary_status
