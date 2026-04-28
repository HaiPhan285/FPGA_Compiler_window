#!/bin/bash
# FPGA Compiler - Windows Batch Build Script

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="$SCRIPT_DIR/.toolchain/tools"
BUILD_DIR="$SCRIPT_DIR/build"

echo ""
echo "====== FPGA Compiler Setup ======"
echo ""

# Create directories
mkdir -p "$TOOLS_DIR"
mkdir -p "$BUILD_DIR"

echo "Checking for required tools..."
echo ""

# Check for required tools
MISSING_TOOLS=()

if ! command -v yosys &> /dev/null; then
    MISSING_TOOLS+=("yosys")
fi

if ! command -v nextpnr-xilinx &> /dev/null; then
    MISSING_TOOLS+=("nextpnr-xilinx")
fi

if ! command -v python3 &> /dev/null; then
    MISSING_TOOLS+=("python3")
fi

if [ ${#MISSING_TOOLS[@]} -gt 0 ]; then
    echo "[ERROR] Missing tools: ${MISSING_TOOLS[*]}"
    echo ""
    echo "Install with:"
    echo ""
    echo "  Ubuntu/Debian:"
    echo "    sudo apt-get install -y yosys python3 python3-pip"
    echo ""
    echo "  macOS:"
    echo "    brew install yosys python3"
    echo ""
    echo "  Or build from source:"
    echo "    https://github.com/YosysHQ/yosys"
    echo "    https://github.com/YosysHQ/nextpnr"
    echo ""
    exit 1
fi

echo "[✓] yosys found"
echo "[✓] python3 found"
echo ""

if command -v nextpnr-xilinx &> /dev/null; then
    echo "[✓] nextpnr-xilinx found"
else
    echo "[✗] nextpnr-xilinx not found (synthesis-only mode)"
fi

echo ""
echo "====== Setup Complete ======"
echo ""
echo "Next: ./build.sh"
echo ""
