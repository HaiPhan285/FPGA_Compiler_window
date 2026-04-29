# FPGA Compiler for Native Windows

Open-source build flow for **Digilent Nexys A7-100T** on Windows without Vivado and without WSL.

## Setup

For a fresh clone:

```powershell
git clone https://github.com/HaiPhan285/FPGA_Compiler_window.git
cd FPGA_Compiler_window
.\fpga.bat setup
.\fpga.bat doctor
```

That's it. `setup` downloads a pre-built Windows toolchain bundle and prepares it for builds and flashing. No other dependencies required.

After setup, run:

```powershell
.\fpga.bat doctor
```

If everything is ready, `doctor` reports `Status : ready`.

### Optional Setup Modes

```powershell
.\fpga.bat setup -InstallPackages
.\fpga.bat setup -DownloadFullToolchain
.\fpga.bat install
```

- **`-InstallPackages`**: Install MSYS2 packages (git, Python, build tools, Yosys, etc.). Only use this if you want to compile tools from source. Requires MSYS2 to be installed.
- **`-DownloadFullToolchain`**: Force a fresh toolchain bundle download instead of using the local cache.
- **`install`**: Alias for `setup`.

### What's Included

By default, the toolchain bundle provides:
- **yosys** for synthesis
- **nextpnr-xilinx** for place-and-route
- **fasm2frames** and **xc7frames2bit** for bitstream generation
- **prjxray-db** for Artix-7 chip database
- **openFPGALoader** for flashing to hardware

The bundle is stored in `%LOCALAPPDATA%\fpga-tools-cache` for reuse across projects.

## Publishing The Bundle

To make `git clone` + `.\fpga.bat install` work for new users, publish the Windows toolchain bundle once to this repo's `toolchain-bundle` release.

Options:
- Run the GitHub Actions workflow `.github/workflows/publish-toolchain-bundle.yml` on a self-hosted Windows runner that already has the full toolchain installed.
- Or run `.\fpga.bat package -Force -SkipSetup` on a prepared Windows machine and upload `dist\nexys-a7-100t-toolchain-windows.zip` to the `toolchain-bundle` GitHub release.

## Commands

```powershell
.\fpga.bat setup
.\fpga.bat install
.\fpga.bat setup -InstallPackages
.\fpga.bat setup -DownloadFullToolchain
.\fpga.bat doctor
.\fpga.bat package
.\fpga.bat list
.\fpga.bat build
.\fpga.bat build -Project lab2
.\fpga.bat build -All
.\fpga.bat flash
.\fpga.bat flash -Project lab
.\fpga.bat flash -Bitstream build\lab\lab.bit
```

## Build Your First Project

If setup is complete and `doctor` shows `Status : ready`, build a project with:

```powershell
.\fpga.bat build -Project lab2
```

That command runs synthesis, place-and-route, and bitstream generation. When it finishes successfully, you should see:

```text
[OK] Bitstream complete: ...
```

If you want to build without typing a project name:

```powershell
.\fpga.bat build
```

That works when the repo has only one buildable project. If there are multiple projects, the script shows a numbered list and asks you to choose one.

## Project Structure

```
FPGA_Compiler_window/
├── fpga.bat           # Simple Windows launcher
├── fpga.ps1           # Single PowerShell entrypoint
└── app/
    ├── lab/           # Prebuilt bitstream example
    └── lab2/          # Source-only example
        ├── add.v
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

`setup` now expects to finish with the full bitstream build toolchain. If the download or install fails, setup exits with an error instead of leaving the user in a partial build environment.

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
- `project_name.json` - Synthesis output (requires **yosys**)
- `project_name.fasm` - Place & Route output (requires **nextpnr-xilinx** + chipdb)
- `project_name.frames` - Frame data (requires **fasm2frames**)
- `project_name.bit` - Bitstream (requires **xc7frames2bit** + prjxray-db)

When `.bit` generation succeeds, the bitstream is also copied into the project folder under `app/`.

### Tool Requirements

- **Synthesis only** (`yosys`): Generates `.json` file
- **Place-and-route** (`nextpnr-xilinx`, chipdb): Generates `.fasm` file  
- **Bitstream generation** (`fasm2frames`, `xc7frames2bit`, prjxray-db): Generates `.bit` file
- **Flashing** (`openFPGALoader`): Programs the board

The default bundle includes all of these. MSYS2 is not required for builds—it is only used if you run `setup -InstallPackages` to compile packages from source.

## Flashing to Hardware

Use openFPGALoader to flash bitstreams:

```powershell
.\fpga.bat flash
.\fpga.bat flash -Project lab
.\fpga.bat flash -Bitstream build\lab\lab.bit
```

`flash -Project <name>` uses that project's `.bit` file from `app\<name>\<name>.bit` first, then `build\<name>\<name>.bit`. Plain `flash` uses the newest `.bit` file under `app\` or `build\` when `-Bitstream` is omitted. If no `.bit` file exists, rerun the build and confirm it reaches `[OK] Bitstream complete`.

For the lightest clone-and-run flow, commit or publish prebuilt bitstreams under each project folder:

```text
app/
└── lab/
    ├── top.v
    ├── constraints.xdc
    └── lab.bit
```

Then another user can clone the repo and flash a project without installing the full synthesis/place-and-route toolchain:

```powershell
.\fpga.bat flash -Project lab
```

## Troubleshooting

**"GitHub release not found for HaiPhan285/FPGA_Compiler_window"**
- The toolchain bundle has not been published as a GitHub release asset yet.
- **Option 1:** Wait for the maintainer to publish the `toolchain-bundle` release.
- **Option 2:** Configure a local or direct download bundle in `toolchain.json`:
  - Set `toolchainBundle.root` to a local unpacked openXC7 bundle folder, or
  - Set `toolchainBundle.downloadUrl` to a direct `.zip` download URL (if available)
- Then run `.\fpga.bat setup` again.

**"yosys: command not found"**
- The toolchain bundle should have included Yosys. Check that `setup` completed successfully.
- If the bundle download failed, run `.\fpga.bat setup -DownloadFullToolchain` to retry.
- Alternatively, if you installed MSYS2 with `-InstallPackages`, ensure `yosys.exe` is on PATH: `Get-Command yosys`.

**"nextpnr-xilinx: command not found"**
- For full Nexys A7 bitstreams, install native openXC7 tools or run `.\fpga.bat setup -DownloadFullToolchain`.
- `setup` and `build` now stop with a setup error instead of silently skipping `.bit` generation.

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

## Diagnostics

Run this to verify whether a machine is fully ready to build:

```powershell
.\fpga.bat doctor
```

It reports missing tools, confirms whether bitstream generation is ready, and gives the next recommended command.

## References

- [Yosys](https://github.com/YosysHQ/yosys)
- [nextpnr-xilinx](https://github.com/openXC7/nextpnr-xilinx)
- [Project X-Ray](https://github.com/openXC7/prjxray)
- [Nexys A7-100T](https://digilent.com/reference/programmable-logic/nexys-a7/reference-manual)

