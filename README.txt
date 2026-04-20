Nexys A7 100T Windows OpenXC7 project

Overview

This repository is organized for multiple FPGA projects.

Each project should live in its own folder under `src\`:

```text
src\
  project1\
    project1.sv
    helper_module.sv

  project2\
    project2.sv
    helper_module.sv
```

Each project should also have its own constraints file in `constraints\`:

```text
constraints\
  project1_openxc7.xdc
  project2_openxc7.xdc
```

Build behavior

- The build script reads only the folder of the selected design file.
- If you build `src\project1\project1.sv`, it will only include RTL files from `src\project1\`.
- This avoids conflicts between unrelated projects in different folders.
- The build script looks for constraints in this order:
  - `src\<project>\<design>_openxc7.xdc`
  - `src\<project>\<design>.xdc`
  - `constraints\<design>_openxc7.xdc`
  - `constraints\<design>.xdc`
  - `constraints\nexys_a7_100t_openxc7.xdc`
  - `constraints\nexys_a7_100t_master.xdc`

Current example

- RTL: `src\your_design.sv`
- Constraints: `constraints\your_design_openxc7.xdc`
- Top module: `your_design`

How to build

```powershell
# Generate or refresh the local toolchain environment.
.\fpga.bat setup

# Build the default design: src\your_design.sv
.\fpga.bat build

# Build a specific project explicitly.
.\fpga.bat build "src\project1\project1.sv" project1 "constraints\project1_openxc7.xdc"

# Program the generated bitstream.
.\fpga.bat program "build\your_design.bit"
```

Step-by-step setup

1. Clone or copy this repository.

2. Optional: copy `toolchain.local.example.json` to `toolchain.local.json` if you want to override tool paths or let the script download your own prepacked OpenXC7 bundle.

```powershell
# Optional: create a local toolchain config you can edit.
Copy-Item .\toolchain.local.example.json .\toolchain.local.json

# Edit the config if you want custom tool paths or a bundle download URL.
notepad .\toolchain.local.json
```

3. Run setup:

```powershell
# Reuse installed tools when present, otherwise download managed ones when configured.
.\fpga.bat setup
```

4. What setup does automatically:
   - reuses an existing OSS CAD Suite install if found
   - otherwise downloads the latest Windows OSS CAD Suite release into `.toolchain\oss-cad-suite`
   - reuses existing local `nextpnr-xilinx`, Project X-Ray, and `xc7frames2bit` installs if found
   - writes `.toolchain\env.bat` for build and program commands

5. What setup cannot infer by itself:
   - a Windows `nextpnr-xilinx` binary if you do not already have one
   - a Project X-Ray / `xc7frames2bit` bundle if you do not already have one

6. If those tools are missing, use one of these:
   - point `toolchain.local.json` at your existing installs
   - set `toolchainBundle.downloadUrl` in `toolchain.local.json` to a zip file that contains your prepacked `nextpnr-xilinx` and Project X-Ray tools

7. Keep the chip database file available locally at:
   - `tools\xc7a100t.bin`
   - this file is larger than GitHub's normal 100 MB file limit, so it is not included in the GitHub repository by default

8. If you want to program with `openFPGALoader` on native Windows, install the correct USB driver with Zadig.
   Usually:
   - open Zadig as Administrator
   - enable `Options > List All Devices`
   - select the Digilent / FTDI JTAG device
   - install `WinUSB`

9. Replug the board after driver installation.

10. Test Yosys directly:

```powershell
# Check whether the Windows Yosys executable can start.
& "C:\fpga-tools\oss-cad-suite\bin\yosys.exe" -V
```

11. Test programming cable detection:

```powershell
# Check whether openFPGALoader can see the USB JTAG cable.
cmd /c "call C:\fpga-tools\oss-cad-suite\environment.bat && openFPGALoader --scan-usb"
```

12. Build:

```powershell
# Build the default design.
.\fpga.bat build
```

13. Program:

```powershell
# Program the generated bitstream to the board.
.\fpga.bat program "build\your_design.bit"
```

Important notes

- If `yosys.exe` is blocked by Windows Application Control, this repository cannot fix that. You must allow the executable or build on another machine.
- If `openFPGALoader` cannot open the FTDI device, that is usually a Windows driver issue, not a Verilog issue.
- The build script validates common HDL mistakes before synthesis:
  - file/module name mismatch for single-module files
  - duplicate module names
  - missing top module
  - files with no module declaration
- `fpga.bat build` and `fpga.bat program` always run setup first, so users do not need to call `setup` again unless they change toolchain configuration.
