#!/usr/bin/env bash
# Downscale PNGs wider than 1200px for PDF rendering.
# Called during RTD build to prevent WeasyPrint failures.
set -e

for f in $(find docs/user-manual/assets -name '*.png'); do
    w=$(identify -format '%w' "$f" 2>/dev/null || echo 0)
    if [ "$w" -gt 1200 ] 2>/dev/null; then
        convert "$f" -resize 1200x "$f"
        echo "Resized: $f ($w -> 1200)"
    fi
done
