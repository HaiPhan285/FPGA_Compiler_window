# FPGA Compiler for Nexys A7-100T

Open-source FPGA toolchain for the Nexys A7-100T board using Yosys, nextpnr, and OpenXC7.

## ⚡ Quick Start (3 Steps)

### 1. Clone Repository
```batch
git clone https://github.com/HaiPhan285/FPGA_Compiler_window
cd FPGA_Compiler_window
```

### 2. Download & Setup Toolchain
```batch
# Option A: Auto-download (if internet is stable)
fpga.bat setup

# Option B: Manual download (for reliable/offline setup)
# 1. Download: https://github.com/YosysHQ/oss-cad-suite-releases/releases
# 2. Extract to: .toolchain\tools\oss-cad-suite
# 3. Run: fpga.bat setup
```

The setup script will:
- Check for required tools (yosys, nextpnr-xilinx)
- Auto-download OSS CAD Suite if tools missing
- Configure your toolchain environment

### 3. Build Your Design
```batch
fpga.bat build src\my_design.sv
```

Your bitstream is ready at `build\my_design.bit` 🎉

## Project Structure

```
.
├── src/              # Your Verilog/SystemVerilog files
├── constraints/      # XDC constraint files
├── build/            # Build outputs (generated)
├── build.ps1         # Build script
├── setup.ps1         # Toolchain configuration script
└── fpga.bat          # Main CLI entry point
```

## Adding Your Design

1. **Place RTL files** in `src/` (`.v` or `.sv` files)
2. **Create constraints** file (e.g., `src/my_design.xdc`)
3. **Run build:**
   ```batch
   fpga.bat build
   ```

The build script auto-detects:
- The top module (first module in your RTL)
- The constraints file (same name as design)

## Troubleshooting

### Error: "Missing required tools: yosys, nextpnr-xilinx"

This should NOT happen anymore. The setup script automatically downloads OSS CAD Suite when run.

**If it still occurs:**
1. Ensure you have internet connection
2. Try again: `fpga.bat setup`
3. If download fails, manually download from: https://github.com/YosysHQ/oss-cad-suite/releases

### Error: "Design file not found"

Place a `.v` or `.sv` file in the `src/` directory, or specify it explicitly:
```batch
fpga.bat build src\my_design.sv
```

### Build fails at nextpnr

Usually means missing constraints or database files. Check:
- XDC constraints file exists and is valid
- All required files are in `src/` and `constraints/` directories

## Build Steps

The `fpga.bat build` command runs:

1. **Yosys** - Synthesizes Verilog to JSON
2. **nextpnr-xilinx** - Place and route on Xilinx 7 series
3. **fasm2frames** - Converts routing to frame format
4. **xc7frames2bit** - Generates final bitstream (`.bit`)

## License

Educational use. Based on Yosys, nextpnr, and OpenXC7 open-source projects.
