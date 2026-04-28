#!/bin/bash
# FPGA Build Script - Compiles Verilog to bitstream

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
APP_DIR="$SCRIPT_DIR/app"

mkdir -p "$BUILD_DIR"

echo ""
echo "====== FPGA Build System ======"
echo ""

# Find projects
PROJECT_COUNT=$(find "$APP_DIR" -maxdepth 1 -type d ! -name "app" 2>/dev/null | wc -l)

if [ "$PROJECT_COUNT" -eq 0 ]; then
    echo "Error: No projects found in $APP_DIR"
    exit 1
fi

echo "Available projects:"
echo ""

select PROJECT in $(find "$APP_DIR" -maxdepth 1 -type d ! -name "app" | sort | xargs -n1 basename); do
    if [ -z "$PROJECT" ]; then
        continue
    fi
    break
done

PROJECT_PATH="$APP_DIR/$PROJECT"

if [ ! -d "$PROJECT_PATH" ]; then
    echo "Project not found: $PROJECT"
    exit 1
fi

echo ""
echo "Building: $PROJECT"
echo ""

# Find source file
SOURCE_FILE=$(find "$PROJECT_PATH" -name "top.v" -o -name "top.sv" | head -1)
CONSTRAINTS=$(find "$PROJECT_PATH" -name "*.xdc" | head -1)

if [ -z "$SOURCE_FILE" ]; then
    echo "Error: top.v or top.sv not found in $PROJECT_PATH"
    exit 1
fi

if [ -z "$CONSTRAINTS" ]; then
    echo "Error: .xdc constraints file not found in $PROJECT_PATH"
    exit 1
fi

echo "Source:      $(basename $SOURCE_FILE)"
echo "Constraints: $(basename $CONSTRAINTS)"
echo ""

# Synthesis
echo "Running synthesis..."
OUTPUT_JSON="$BUILD_DIR/${PROJECT}.json"

yosys -p "
read_verilog -sv $SOURCE_FILE
hierarchy -top top
proc
flatten
opt
write_json $OUTPUT_JSON
"

if [ $? -eq 0 ]; then
    echo "[✓] Synthesis complete: $OUTPUT_JSON"
else
    echo "[✗] Synthesis failed"
    exit 1
fi

echo ""

# Place & Route
if command -v nextpnr-xilinx &> /dev/null; then
    echo "Running place & route..."
    OUTPUT_FASM="$BUILD_DIR/${PROJECT}.fasm"
    
    nextpnr-xilinx \
        --json "$OUTPUT_JSON" \
        --xdc "$CONSTRAINTS" \
        --fasm "$OUTPUT_FASM" \
        --device xc7a100t
    
    if [ $? -eq 0 ]; then
        echo "[✓] P&R complete: $OUTPUT_FASM"
    else
        echo "[✗] Place & Route failed"
        exit 1
    fi
    
    echo ""
    echo "====== Build Complete ======"
    echo ""
    echo "Outputs:"
    echo "  JSON:  $OUTPUT_JSON"
    echo "  FASM:  $OUTPUT_FASM"
else
    echo "[✓] Synthesis only (nextpnr-xilinx not available)"
    echo ""
    echo "Output: $OUTPUT_JSON"
fi

echo ""
