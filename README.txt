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

Fast start

Other users should not need to edit any JSON file.

```powershell
# 1. Clone or copy this repository.

# 2. Install or refresh the cached Windows FPGA toolchain.
.\fpga.bat install

# 3. Build the default design: src\your_design.sv
.\fpga.bat build

# 4. Program the generated bitstream.
.\fpga.bat program "build\your_design.bit"
```

`install` and `setup` are the same command. `build` and `program` always run setup first, so most users can go straight to:

```powershell
.\fpga.bat build
```

What setup does automatically

- reads repo defaults from `toolchain.json`
- applies optional local overrides from `toolchain.local.json`
- prefers a published OpenXC7 bundle asset from the repo's latest GitHub release
- reuses an existing OSS CAD Suite install if found
- otherwise reuses a cached OSS CAD archive from `%LOCALAPPDATA%\fpga-tools-cache\downloads`
- otherwise downloads the latest Windows OSS CAD Suite release into the shared cache
- extracts current Windows OSS CAD Suite `.zip` or self-extracting `.exe` releases automatically
- reuses existing local `nextpnr-xilinx`, Project X-Ray, and `xc7frames2bit` installs if found
- reuses a local `tools\xc7a100t.bin`, a cached chipdb, or a published chipdb release asset when configured
- writes a small repo-local `.toolchain\env.bat` for build and program commands
- reuses the shared cache for later FPGA repositories on the same machine

Setup keeps downloaded archives under `%LOCALAPPDATA%\fpga-tools-cache\downloads`, so the first run is the heavy run and later runs are usually fast.

Optional local override

Only create `toolchain.local.json` if you want to override the repo defaults with your own paths or download sources.

```powershell
Copy-Item .\toolchain.local.example.json .\toolchain.local.json
notepad .\toolchain.local.json
```

Maintainer release flow

The simple user install path depends on the repository publishing a Windows bundle and optionally a chipdb asset in GitHub Releases.

- bundle users should download: `nexys-a7-100t-toolchain-windows.zip`
- bundle layout expected by `setup.ps1`:
  - `oss-cad-suite\...`
  - `nextpnr-xilinx.exe`
  - `src\prjxray\...`
  - `src\prjxray-db\artix7\...`
  - `build\prjxray\tools\xc7frames2bit.exe`
  - optional `tools\xc7a100t.bin`
- chipdb asset can be either `xc7a100t.bin` directly or a zip containing that file

If you already have a working Windows toolchain on one machine, package it once and upload the zip as a release asset:

```powershell
# Build a single Windows bundle zip from the currently working toolchain.
.\fpga.bat bundle

# Write to a specific archive path if you prefer.
.\fpga.bat bundle "dist\my-toolchain.zip" --force
```

If you want to program with `openFPGALoader` on native Windows, install the correct USB driver with Zadig.
Usually:
- open Zadig as Administrator
- enable `Options > List All Devices`
- select the Digilent / FTDI JTAG device
- install `WinUSB`

Replug the board after driver installation.

Quick checks

```powershell
# Check whether the configured Windows Yosys executable can start.
cmd /c "call .\.toolchain\env.bat && ""%YOSYS_EXE%"" -V"

# Check whether openFPGALoader can see the USB JTAG cable.
cmd /c "call .\.toolchain\env.bat && call ""%OSS_CAD_ENV%"" && ""%OPENFPGALOADER_EXE%"" --scan-usb"
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
