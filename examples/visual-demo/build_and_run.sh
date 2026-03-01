#!/bin/bash
# build_and_run.sh — Build and run the visual demo
#
# Usage:
#   ./build_and_run.sh              # Build and run (saves output.png)
#   ./build_and_run.sh --capture    # Build, run with .gputrace capture, analyze
#   ./build_and_run.sh --clean      # Remove build artifacts

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

build() {
    echo "Compiling shaders..."
    xcrun -sdk macosx metal -c Shaders.metal -o Shaders.air
    xcrun -sdk macosx metallib Shaders.air -o Shaders.metallib

    echo "Compiling Swift..."
    swiftc -framework Metal -framework CoreGraphics -framework ImageIO main.swift -o visual_demo

    echo "Build complete."
}

run_normal() {
    echo ""
    echo "Running visual_demo..."
    echo "================================"
    ./visual_demo
    echo "================================"
    echo ""
    if [ -f output.png ]; then
        echo "Output: output.png ($(stat -f%z output.png) bytes)"
        echo "Open: open output.png"
    fi
}

run_capture() {
    echo ""
    echo "Running with GPU capture..."
    echo "================================"
    METAL_CAPTURE_ENABLED=1 ./visual_demo
    echo "================================"
    echo ""

    if [ -d capture.gputrace ]; then
        echo "Analyzing capture..."
        python3 ../../parse_gputrace.py capture.gputrace
        echo ""
        echo "Vertex data from capture:"
        python3 ../../parse_gputrace.py capture.gputrace --buffer "Triangle Vertices" --layout "float2,float4" --index 0-2
        echo ""
        echo "Open in Xcode: open capture.gputrace"
    fi
}

clean() {
    rm -f Shaders.air Shaders.metallib visual_demo output.png
    rm -rf capture.gputrace
    echo "Clean."
}

case "${1:-}" in
    --capture)
        build
        run_capture
        ;;
    --clean)
        clean
        ;;
    --help|-h)
        echo "Usage: $0 [--capture|--clean]"
        echo "  (no args)    Build and run (saves output.png)"
        echo "  --capture    Build, capture .gputrace, analyze"
        echo "  --clean      Remove build artifacts"
        ;;
    *)
        build
        run_normal
        ;;
esac
