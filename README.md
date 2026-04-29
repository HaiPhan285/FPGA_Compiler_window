# FPGA Compiler for Native Windows

Open-source build flow for **Digilent Nexys A7-100T** on Windows without Vivado and without WSL.

## Quick Start

```powershell
git clone https://github.com/HaiPhan285/FPGA_Compiler_window.git
cd FPGA_Compiler_window
.\fpga.bat setup
.\fpga.bat doctor
.\fpga.bat build -Project lab2
.\fpga.bat flash -Project lab2
```

That's it. One command to setup, one to build, one to flash.

## Setup

Before building, prepare the toolchain:

```powershell
.\fpga.bat setup
.\fpga.bat doctor
```

`setup` configures the toolchain from the repo-local bundle (`.toolchain\openxc7-bundle`).  
`doctor` verifies everything is ready. Look for `Status : ready`.

## Build a Project

```powershell
.\fpga.bat build -Project lab2
```

This runs:
1. **Synthesis** (yosys) → `.json`
2. **Place-and-route** (nextpnr-xilinx) → `.fasm`
3. **Bitstream generation** (fasm2frames, xc7frames2bit) → `.bit`

Outputs go to `build\lab2\` and `app\lab2\`.

## Flash to Hardware

```powershell
.\fpga.bat flash -Project lab2
```

Programs the Nexys A7-100T with the built bitstream.

## Publishing The Bundle

To make `git clone` + `.\fpga.bat install` work for new users, publish the Windows toolchain bundle once to this repo's `toolchain-bundle` release.

Options:
- Run the GitHub Actions workflow `.github/workflows/publish-toolchain-bundle.yml` on a self-hosted Windows runner that already has the full toolchain installed.
- Or run `.\fpga.bat package -Force -SkipSetup` on a prepared Windows machine and upload `dist\nexys-a7-100t-toolchain-windows.zip` to the `toolchain-bundle` GitHub release.

## Commands

| Command | Description |
|---------|-------------|
| `.\fpga.bat setup` | Initialize toolchain |
| `.\fpga.bat doctor` | Check if everything is ready |
| `.\fpga.bat build` | Build default/selected project |
| `.\fpga.bat build -Project <name>` | Build specific project |
| `.\fpga.bat build -All` | Build all projects |
| `.\fpga.bat flash` | Flash newest bitstream |
| `.\fpga.bat flash -Project <name>` | Flash project bitstream |
| `.\fpga.bat flash -Bitstream <path>` | Flash specific bitstream file |
| `.\fpga.bat list` | List available projects |

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

**"toolchain\openxc7-bundle not found"**
- The bundle is expected at `.toolchain\openxc7-bundle` in the repo root.
- **Option 1:** Extract your openXC7 bundle to that location.
- **Option 2:** Edit `toolchain.json` and set `toolchainBundle.root` to your bundle path.
- Then run `.\fpga.bat setup` again.

**"yosys: command not found"** or other missing tools
- Verify that `.\fpga.bat doctor` completes successfully.
- Check that the bundle is properly extracted in `.toolchain\openxc7-bundle`.
- Run `.\fpga.bat setup` to reinitialize the toolchain.

**"nextpnr-xilinx: command not found"**
- The bundle should include place-and-route tools.
- Make sure the bundle is not corrupted.

**"chipdb-xc7a100t.bin not found"**
- The bundle should include the chip database.
- Check that `.toolchain\openxc7-bundle\share\nextpnr\xilinx\chipdb-xc7a100t.bin` exists.

**".bit generation skipped"**
- Make sure the bundle includes `fasm2frames.exe`, `xc7frames2bit.exe`, and the prjxray database.
- Run `.\fpga.bat doctor` to check what's missing.

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

