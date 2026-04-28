# FPGA Compiler for Native Windows

Open-source build flow for **Digilent Nexys A7-100T** on Windows without Vivado and without WSL.

## Quick Start

```powershell
git clone https://github.com/HaiPhan285/FPGA_Compiler_window.git
cd FPGA_Compiler_window

.\fpga.bat setup
.\fpga.bat build
```

Build one project directly:

```powershell
.\fpga.bat build -Project blink_led
```

## Requirements

- **Yosys** for synthesis.
- **nextpnr-xilinx** plus a matching `chipdb-xc7a100t.bin` for place-and-route.
- **prjxray** tools (`fasm2frames`, `xc7frames2bit`) plus `prjxray-db` for `.bit` generation.
- **openFPGALoader** for flashing.
- **MSYS2** is the recommended native Windows package/build environment.

The scripts do not call Vivado, WSL, Ubuntu, or Bash. They discover native `.exe` tools from:

- `.toolchain\tools\bin`
- `C:\msys64\mingw64\bin`
- `C:\msys64\usr\bin`
- your normal `PATH`

Install common MSYS2 packages:

```powershell
.\setup.ps1 -InstallPackages
```

`nextpnr-xilinx` and `prjxray` are not part of the normal OSS CAD Suite Windows package. Put native openXC7/MSYS2-built binaries in `.toolchain\tools\bin` or on `PATH`.

## Commands

```powershell
.\fpga.bat setup
.\fpga.bat build
.\fpga.bat build -Project blink_led
.\fpga.bat build -All
.\fpga.bat flash
.\fpga.bat flash -Project blink_led
.\fpga.bat flash -Bitstream build\blink_led\blink_led.bit
```

## Project Structure

```
FPGA_Compiler_window/
├── fpga.bat           # Windows command wrapper
├── setup.ps1          # Native Windows environment check
├── build.ps1          # Native Windows build flow
├── build.sh           # Legacy Bash wrapper
├── setup.sh           # Legacy Bash setup check
└── app/
    └── blink_led/     # Example project
        ├── top.v      # Verilog source
        └── constraints.xdc
```

## Creating Your Own Project

1. Create a folder in `app/`:
```powershell
mkdir app/my_project
```

2. Add files:
```
app/my_project/
├── top.v (or top.sv for SystemVerilog)
└── constraints.xdc
```

3. Run build:
```powershell
.\fpga.bat build -Project my_project
```

## Project File Format

### Verilog (top.v)
```verilog
module top (
    input clk,
    output led
);
    // Your design
endmodule
```

### Constraints (constraints.xdc)
```tcl
set_property -dict {PACKAGE_PIN E3 IOSTANDARD LVCMOS33} [get_ports {clk}]
set_property -dict {PACKAGE_PIN H17 IOSTANDARD LVCMOS33} [get_ports {led}]
```

## Build Outputs

After building, outputs are in `build/` folder:
- `project_name.json` - Synthesis output
- `project_name.fasm` - Place & Route output (requires nextpnr-xilinx)
- `project_name.frames` - Frame data (requires prjxray)
- `project_name.bit` - Bitstream (requires prjxray)

When `.bit` generation succeeds, the bitstream is also copied into the project folder under `app/`.

## Flashing to Hardware

Use openFPGALoader to flash bitstreams:

```powershell
.\fpga.bat flash
.\fpga.bat flash -Project blink_led
.\fpga.bat flash -Bitstream build\blink_led\blink_led.bit
```

`flash -Project <name>` uses that project's `.bit` file from `app\<name>\<name>.bit` first, then `build\<name>\<name>.bit`. Plain `flash` uses the newest `.bit` file under `app\` or `build\` when `-Bitstream` is omitted. If no `.bit` file exists, rerun the build and confirm it reaches `[OK] Bitstream complete`.

For the lightest clone-and-run flow, commit or publish prebuilt bitstreams under each project folder:

```text
app/
└── blink_led/
    ├── top.v
    ├── constraints.xdc
    └── blink_led.bit
```

Then another user can clone the repo and flash a project without installing the full synthesis/place-and-route toolchain:

```powershell
.\fpga.bat flash -Project blink_led
```

## Troubleshooting

**"yosys: command not found"**
- Run `.\setup.ps1 -InstallPackages`, or add native `yosys.exe` to `PATH`.

**"nextpnr-xilinx: command not found"**
- Synthesis can still run without it.
- For full Nexys A7 bitstreams, build/install native openXC7 `nextpnr-xilinx.exe`.

**"chipdb-xc7a100t.bin not found"**
- Generate or install the nextpnr-xilinx Artix-7 chip database.
- Put it under `.toolchain\tools\share\nextpnr\xilinx\`.

**".bit generation skipped"**
- Install native `fasm2frames.exe`, `xc7frames2bit.exe`, and `prjxray-db`.
- Set `PRJXRAY_DB_DIR` or place the database in `.toolchain\prjxray-db`.

**Build failed**
- Check constraints file syntax
- Verify module name is `top`
- Check Verilog for syntax errors

## References

- [Yosys](https://github.com/YosysHQ/yosys)
- [nextpnr-xilinx](https://github.com/openXC7/nextpnr-xilinx)
- [Project X-Ray](https://github.com/openXC7/prjxray)
- [Nexys A7-100T](https://digilent.com/reference/programmable-logic/nexys-a7/reference-manual)

