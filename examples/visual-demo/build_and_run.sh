#!/bin/bash
# build_and_run.sh — Build and run the visual demo
#
# Usage:
#   ./build_and_run.sh              # Build and run (opens window)
#   ./build_and_run.sh --screenshot # Build, render, save output.png, exit
#   ./build_and_run.sh --capture    # Build, capture .gputrace, analyze
#   ./build_and_run.sh --clean      # Remove build artifacts

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

build() {
    echo "Compiling shaders..."
    xcrun -sdk macosx metal -c Shaders.metal -o Shaders.air
    xcrun -sdk macosx metallib Shaders.air -o Shaders.metallib

    echo "Compiling Swift..."
    swiftc -framework Cocoa -framework Metal -framework MetalKit main.swift -o visual_demo

    echo "Build complete."
}

run_normal() {
    echo ""
    echo "Running visual_demo..."
    ./visual_demo
}

run_capture() {
    echo ""
    echo "Running with GPU capture..."
    METAL_CAPTURE_ENABLED=1 ./visual_demo --capture

    if [ -d capture.gputrace ]; then
        echo ""
        echo "Analyzing capture..."
        python3 ../../parse_gputrace.py capture.gputrace
        echo ""
        echo "Vertex data from capture:"
        python3 ../../parse_gputrace.py capture.gputrace --buffer "Triangle Vertices" --layout "float2,float4" --index 0-2
        echo ""
        echo "Open in Xcode: open capture.gputrace"
    fi
}

run_screenshot() {
    echo ""
    echo "Rendering and saving screenshot..."
    ./visual_demo --screenshot
}

clean() {
    rm -f Shaders.air Shaders.metallib visual_demo
    rm -rf capture.gputrace
    echo "Clean."
}

case "${1:-}" in
    --screenshot)
        build
        run_screenshot
        ;;
    --capture)
        build
        run_capture
        ;;
    --clean)
        clean
        ;;
    --help|-h)
        echo "Usage: $0 [--screenshot|--capture|--clean]"
        echo "  (no args)      Build and run (opens window)"
        echo "  --screenshot   Build, render, save output.png, exit"
        echo "  --capture      Build, capture .gputrace, analyze"
        echo "  --clean        Remove build artifacts"
        ;;
    *)
        build
        run_normal
        ;;
esac
