#!/bin/bash
# build_and_run.sh — Build and run the buggy renderer
#
# Usage:
#   ./build_and_run.sh              # Build and run normally
#   ./build_and_run.sh --validate   # Run with Metal validation layers
#   ./build_and_run.sh --profile    # Build, profile with xctrace, export data
#   ./build_and_run.sh --full       # All of the above
#   ./build_and_run.sh --clean      # Remove build artifacts

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ---- Functions ----

check_tools() {
    echo -e "${YELLOW}Checking tools...${NC}"
    xcode-select -p >/dev/null 2>&1 || {
        echo -e "${RED}ERROR: Xcode not found. Install Xcode and run:${NC}"
        echo "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
        exit 1
    }
    xcrun xctrace version >/dev/null 2>&1 || {
        echo -e "${RED}ERROR: xctrace not available${NC}"
        exit 1
    }
    xcrun -sdk macosx metal --version >/dev/null 2>&1 || {
        echo -e "${RED}ERROR: Metal compiler not available${NC}"
        exit 1
    }
    echo -e "${GREEN}All tools OK${NC}"
}

build() {
    echo -e "${YELLOW}Compiling shaders...${NC}"
    xcrun -sdk macosx metal -c -gline-tables-only -Weverything Shaders.metal -o Shaders.air 2>&1 || true
    # Note: -Weverything will show the planted warnings (BUG 1: unused variable)

    echo -e "${YELLOW}Linking shader library...${NC}"
    xcrun -sdk macosx metallib Shaders.air -o Shaders.metallib

    echo -e "${YELLOW}Compiling Swift...${NC}"
    swiftc -framework Metal -framework CoreGraphics -O main.swift -o buggy_renderer

    echo -e "${GREEN}Build complete${NC}"
}

run_normal() {
    echo ""
    echo -e "${YELLOW}Running buggy_renderer...${NC}"
    echo "================================================"
    ./buggy_renderer
    echo "================================================"
}

run_validate() {
    echo ""
    echo -e "${YELLOW}Running with Metal validation layers...${NC}"
    echo "================================================"
    MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 ./buggy_renderer 2>&1 | tee validation.log
    echo "================================================"

    echo ""
    echo -e "${YELLOW}Checking for validation errors...${NC}"
    if grep -qi "error\|fault\|invalid\|violation" validation.log 2>/dev/null; then
        echo -e "${RED}Validation errors found:${NC}"
        grep -i "error\|fault\|invalid\|violation" validation.log
    else
        echo -e "${GREEN}No validation errors in stderr (some may only appear in system log)${NC}"
    fi

    echo ""
    echo -e "${YELLOW}Checking system log for Metal errors...${NC}"
    log show --predicate 'subsystem == "com.apple.Metal"' --last 30s --level error 2>/dev/null | \
        grep -v "^$" | head -20 || echo "No Metal errors in system log"
}

run_profile() {
    mkdir -p ./traces/analysis

    echo ""
    echo -e "${YELLOW}Recording Metal System Trace (15s)...${NC}"
    xcrun xctrace record \
        --template 'Metal System Trace' \
        --time-limit 15s \
        --no-prompt \
        --output ./traces/capture.trace \
        --launch -- ./buggy_renderer

    echo ""
    echo -e "${YELLOW}Exporting trace data...${NC}"

    # TOC
    xcrun xctrace export --input ./traces/capture.trace --toc \
        > ./traces/analysis/toc.xml
    echo "Available schemas:"
    grep 'schema=' ./traces/analysis/toc.xml | sed 's/.*schema="\([^"]*\)".*/  - \1/'

    # Export all Metal-related tables
    for schema in metal-driver-event-intervals gpu-counter-intervals metal-gpu-intervals; do
        if grep -q "schema=\"$schema\"" ./traces/analysis/toc.xml; then
            echo "Exporting $schema..."
            xcrun xctrace export --input ./traces/capture.trace \
                --output "./traces/analysis/${schema}.xml" \
                --xpath "/trace-toc/run[@number=\"1\"]/data/table[@schema=\"$schema\"]" \
                2>/dev/null || echo "  (export failed for $schema)"
        fi
    done

    echo ""
    echo -e "${YELLOW}Analyzing trace data...${NC}"
    for xml in ./traces/analysis/*.xml; do
        [ "$(basename "$xml")" = "toc.xml" ] && continue
        echo "=== $(basename "$xml") ==="
        python3 ../../parse_trace.py "$xml" --summary 2>/dev/null || \
            python3 -c "
import xml.etree.ElementTree as ET
tree = ET.parse('$xml')
rows = tree.getroot().findall('.//row')
print(f'  Rows: {len(rows)}')
" 2>/dev/null || echo "  (parse failed)"
    done

    echo ""
    echo -e "${GREEN}Trace saved: ./traces/capture.trace${NC}"
    echo "Open in Instruments: open ./traces/capture.trace"
}

run_shader_check() {
    echo ""
    echo -e "${YELLOW}Checking shaders with -Weverything -Werror...${NC}"
    echo "================================================"
    if xcrun -sdk macosx metal -c -Weverything -Werror Shaders.metal -o /dev/null 2>&1; then
        echo -e "${GREEN}Shaders compiled cleanly${NC}"
    else
        echo -e "${RED}Shader issues found (see above)${NC}"
    fi
    echo "================================================"
}

clean() {
    echo -e "${YELLOW}Cleaning build artifacts...${NC}"
    rm -f Shaders.air Shaders.metallib buggy_renderer validation.log
    rm -rf traces/
    echo -e "${GREEN}Clean${NC}"
}

# ---- Main ----

case "${1:-}" in
    --validate)
        check_tools
        build
        run_validate
        ;;
    --profile)
        check_tools
        build
        run_profile
        ;;
    --shader-check)
        check_tools
        run_shader_check
        ;;
    --full)
        check_tools
        run_shader_check
        build
        run_normal
        run_validate
        run_profile
        echo ""
        echo -e "${GREEN}=== Full analysis complete ===${NC}"
        echo "Artifacts:"
        echo "  validation.log         — Metal validation layer output"
        echo "  traces/capture.trace   — Metal System Trace (open in Instruments)"
        echo "  traces/analysis/*.xml  — Exported GPU data"
        ;;
    --clean)
        clean
        ;;
    --help|-h)
        echo "Usage: $0 [--validate|--profile|--shader-check|--full|--clean]"
        echo ""
        echo "  (no args)       Build and run normally"
        echo "  --validate      Run with Metal validation layers"
        echo "  --profile       Profile with xctrace and export data"
        echo "  --shader-check  Check shaders with -Weverything -Werror"
        echo "  --full          All of the above"
        echo "  --clean         Remove build artifacts"
        ;;
    *)
        check_tools
        build
        run_normal
        ;;
esac
