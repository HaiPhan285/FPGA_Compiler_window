# FPGA Compiler for Nexys A7-100T

Open-source FPGA toolchain for the Nexys A7-100T board using Yosys, nextpnr, and OpenXC7.

## ⚡ Quick Start

### **Step 1: Clone Repository**
```batch
git clone https://github.com/HaiPhan285/FPGA_Compiler_window
cd FPGA_Compiler_window
```

### **Step 2: Download OSS CAD Suite**

**Option A: Automatic (Recommended)**
```batch
download-tools.bat
```

**Option B: Manual**
1. Visit: https://github.com/YosysHQ/oss-cad-suite-releases/releases
2. Download: `oss-cad-suite-YYYY.MM.DD-windows.zip`
3. Extract to: `.toolchain\tools\oss-cad-suite`

Folder structure must be:
```
.toolchain\tools\oss-cad-suite\
├── bin\           ← important!
├── lib\
└── ...
```

### **Step 3: Setup Toolchain**
```batch
fpga.bat setup
```

### **Step 4: Build Your Design**
```batch
fpga.bat build src\my_design.sv
```

Creates: `build\my_design.bit` ✅

### **Step 5: Program Board** (Optional)
```batch
fpga.bat program
```

---

## **What Each Command Does**

| Command | Purpose |
|---------|---------|
| `fpga.bat setup` | Setup toolchain (one-time) |
| `fpga.bat build <design.sv>` | Synthesize + Implement + Generate bitstream |
| `fpga.bat program [bitstream.bit]` | Upload to board |

---

## **Example Design**

Create `src\my_design.sv`:
```verilog
module my_design (
    input clk,
    input reset,
    output [7:0] led
);

reg [27:0] counter;

always @(posedge clk) begin
    if (reset)
        counter <= 0;
    else
        counter <= counter + 1;
end

assign led = counter[27:20];

endmodule
```

Then build:
```batch
fpga.bat build src\my_design.sv
```

---

## **Troubleshooting**

| Problem | Solution |
|---------|----------|
| `yosys not found` | Run `download-tools.bat` then `fpga.bat setup` |
| Download fails | Manual download from GitHub → Extract to `.toolchain\tools\oss-cad-suite` |
| Extraction fails | Verify folder structure has `bin\`, `lib\`, etc. |
| Build fails | Check design syntax in `src/`, place constraints in `constraints/` |
| Programming fails | Check USB cable, install Digilent JTAG drivers |

---

## **What Gets Downloaded**

- **OSS CAD Suite** (~500MB) - Contains yosys, nextpnr, openFpgaLoader, etc.
- **Location:** `.toolchain\tools\oss-cad-suite\`
- **Can reuse:** Run `setup` multiple times, won't re-download if exists

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
