#!/bin/bash
# debug-capture.sh - Automated state capture for Lungfish debugging
#
# Usage: ./debug-capture.sh [--live SECONDS]
#
# This script captures debugging information for Lungfish Genome Explorer:
# - Console logs from the unified logging system
# - Screenshot of the app window
# - Process information
# - Test folder contents
#
# For the 20-expert team to use during debugging sessions.

set -e

# Configuration
SUBSYSTEM="com.lungfish.browser"
TEST_FOLDER="${LUNGFISH_DEBUG_TEST_FOLDER:-$HOME/Desktop/test}"
LIVE_DURATION=${2:-30}

# Parse arguments
CAPTURE_LIVE=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --live)
            CAPTURE_LIVE=true
            LIVE_DURATION="${2:-30}"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

# Create output directory
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUTPUT_DIR="$HOME/Desktop/lungfish-debug-$TIMESTAMP"
mkdir -p "$OUTPUT_DIR"

echo "=============================================="
echo "🔬 Lungfish Debug Capture"
echo "=============================================="
echo "📂 Output directory: $OUTPUT_DIR"
echo ""

# 1. Capture console logs (last 10 minutes)
echo "📋 [1/5] Capturing console logs (last 10 minutes)..."
if log show --predicate "subsystem == '$SUBSYSTEM'" --last 10m --style compact > "$OUTPUT_DIR/console-logs.txt" 2>/dev/null; then
    LINE_COUNT=$(wc -l < "$OUTPUT_DIR/console-logs.txt" | tr -d ' ')
    echo "   ✓ Captured $LINE_COUNT log lines"
else
    echo "   ⚠ No logs found or log command failed"
    echo "No logs found" > "$OUTPUT_DIR/console-logs.txt"
fi

# 2. Capture screenshot
echo "🖼️  [2/5] Capturing screenshot..."
APP_NAME="Lungfish"

if pgrep -x "$APP_NAME" > /dev/null 2>&1; then
    echo "   Found running $APP_NAME process"

    # Try to capture specific window
    WINDOW_ID=$(osascript -e "tell application \"System Events\" to tell process \"$APP_NAME\" to get id of first window" 2>/dev/null || echo "")

    if [ -n "$WINDOW_ID" ]; then
        if screencapture -l "$WINDOW_ID" "$OUTPUT_DIR/lungfish-window.png" 2>/dev/null; then
            echo "   ✓ Captured Lungfish window"
        else
            screencapture "$OUTPUT_DIR/screen-fallback.png"
            echo "   ✓ Captured full screen (window capture failed)"
        fi
    else
        screencapture "$OUTPUT_DIR/screen-fallback.png"
        echo "   ✓ Captured full screen (no window ID)"
    fi
else
    echo "   ⚠ Lungfish not running"
    echo "   Taking full screenshot anyway..."
    screencapture "$OUTPUT_DIR/screen-no-app.png"
fi

# 3. Capture process info
echo "🔍 [3/5] Capturing process information..."
{
    echo "=== Lungfish Process Info ==="
    echo "Timestamp: $(date)"
    echo ""
    echo "=== Process List (grep lungfish) ==="
    ps aux | grep -i lungfish | grep -v grep || echo "No Lungfish process found"
    echo ""
    echo "=== Swift Processes ==="
    ps aux | grep -i swift | grep -v grep || echo "No Swift processes found"
} > "$OUTPUT_DIR/process-info.txt"
echo "   ✓ Process info captured"

# 4. List test folder contents
echo "📁 [4/5] Cataloging test folder..."
if [ -d "$TEST_FOLDER" ]; then
    {
        echo "=== Test Folder Contents ==="
        echo "Path: $TEST_FOLDER"
        echo "Timestamp: $(date)"
        echo ""
        ls -laR "$TEST_FOLDER"
        echo ""
        echo "=== File Type Summary ==="
        find "$TEST_FOLDER" -type f | sed 's/.*\.//' | sort | uniq -c | sort -rn
    } > "$OUTPUT_DIR/test-folder-contents.txt"
    FILE_COUNT=$(find "$TEST_FOLDER" -type f | wc -l | tr -d ' ')
    echo "   ✓ Found $FILE_COUNT files in test folder"
else
    echo "   ⚠ Test folder not found: $TEST_FOLDER"
    echo "Test folder not found: $TEST_FOLDER" > "$OUTPUT_DIR/test-folder-contents.txt"
fi

# 5. Live log streaming (optional)
if [ "$CAPTURE_LIVE" = true ]; then
    echo "🔴 [5/5] Streaming live logs for $LIVE_DURATION seconds..."
    echo "   >>> Perform your test actions NOW <<<"
    echo ""

    # Stream to file and also show abbreviated output
    timeout "$LIVE_DURATION" log stream --predicate "subsystem == '$SUBSYSTEM'" --style compact 2>/dev/null | tee "$OUTPUT_DIR/live-logs.txt" | head -100 &
    STREAM_PID=$!

    # Wait for streaming to complete
    sleep "$LIVE_DURATION"
    kill $STREAM_PID 2>/dev/null || true

    LIVE_LINES=$(wc -l < "$OUTPUT_DIR/live-logs.txt" 2>/dev/null | tr -d ' ' || echo "0")
    echo ""
    echo "   ✓ Captured $LIVE_LINES live log lines"
else
    echo "⏭️  [5/5] Skipping live capture (use --live to enable)"
fi

# Summary
echo ""
echo "=============================================="
echo "✅ Debug Capture Complete!"
echo "=============================================="
echo ""
echo "📂 Output saved to: $OUTPUT_DIR"
echo ""
echo "Files captured:"
ls -lh "$OUTPUT_DIR" | tail -n +2
echo ""

# Quick analysis
echo "=== Quick Analysis ==="

# Check for errors in logs
ERROR_COUNT=$(grep -ci "error" "$OUTPUT_DIR/console-logs.txt" 2>/dev/null || echo "0")
WARNING_COUNT=$(grep -ci "warning" "$OUTPUT_DIR/console-logs.txt" 2>/dev/null || echo "0")
echo "📊 Errors in logs: $ERROR_COUNT"
echo "📊 Warnings in logs: $WARNING_COUNT"

# Check for key events
if grep -q "loadDocument: Successfully completed" "$OUTPUT_DIR/console-logs.txt" 2>/dev/null; then
    echo "✓ Document loading detected"
else
    echo "⚠ No successful document load detected"
fi

if grep -q "displayDocument: Starting" "$OUTPUT_DIR/console-logs.txt" 2>/dev/null; then
    echo "✓ Document display detected"
else
    echo "⚠ No document display detected"
fi

if grep -q "addLoadedDocument" "$OUTPUT_DIR/console-logs.txt" 2>/dev/null; then
    echo "✓ Sidebar update detected"
else
    echo "⚠ No sidebar update detected"
fi

echo ""
echo "🔧 To view detailed logs:"
echo "   open $OUTPUT_DIR/console-logs.txt"
echo ""
echo "🖼️  To view screenshot:"
echo "   open $OUTPUT_DIR/*.png"
