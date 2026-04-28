# FPGA Compiler for Nexys A7-100T

Open-source FPGA toolchain for the Nexys A7-100T board using Yosys, nextpnr, and OpenXC7.

## Quick Start

### 1. Install OSS CAD Suite

Download and extract the OSS CAD Suite:
- **Download:** https://github.com/YosysHQ/oss-cad-suite/releases
- **Extract to:** Any directory (e.g., `C:\oss-cad-suite`)

### 2. Add to PATH

Add the OSS CAD Suite `bin` directory to your Windows PATH:
1. Press `Win + X` and select "System"
2. Click "Advanced system settings"
3. Click "Environment Variables..."
4. Under "User variables", click "New..."
5. Variable name: `PATH`
6. Variable value: `C:\oss-cad-suite\bin` (or wherever you extracted it)
7. Click OK and restart your terminal

### 3. Clone and Setup

```batch
git clone https://github.com/HaiPhan285/FPGA_Compiler_window
cd FPGA_Compiler_window
fpga.bat setup
```

### 4. Build Your Design

```batch
fpga.bat build
```

This generates `build\your_design.bit` - your FPGA bitstream.

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

**Fix:**
1. Download OSS CAD Suite
2. Add its `bin` directory to PATH
3. Restart your terminal
4. Run `fpga.bat setup` again

### Error: "Design file not found"

**Fix:** Place a `.v` or `.sv` file in the `src/` directory, or specify it:
```batch
fpga.bat build src\my_design.sv
```

### Build fails at nextpnr

This usually means:
- Missing chipdb database file
- Invalid constraints file format

Check that all `.xdc` files are in the `constraints/` folder.

## Build Steps

The `fpga.bat build` command runs:

1. **Yosys** - Synthesizes Verilog to JSON
2. **nextpnr-xilinx** - Place and route on Xilinx 7 series
3. **fasm2frames** - Converts routing to frame format
4. **xc7frames2bit** - Generates final bitstream (`.bit`)

## License

Educational use. Based on Yosys, nextpnr, and OpenXC7 open-source projects.
