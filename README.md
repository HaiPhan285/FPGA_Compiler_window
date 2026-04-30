
# FPGA Compiler for Native Windows

Open-source build flow for **Digilent Nexys A7-100T** on Windows without Vivado and without WSL.

---

## 🚀 Quick Start (3 Commands)

**Friend's exact commands (copy & paste):**

```powershell
git clone https://github.com/HaiPhan285/FPGA_Compiler_window.git
cd FPGA_Compiler_window
docker-compose run fpga-compiler fpga.bat build -Project lab2
docker-compose run fpga-compiler fpga.bat flash -Project lab2
```

**Requirements:** Docker Desktop installed  
**Time:** ~5-6 minutes (first time) ⚡⚡⚡⚡⚡

---

## ⏱️ Timeline for Friends

| Step | Time |
|------|------|
| Clone repo | 1 min |
| Docker image pulls | 2 min |
| Build project | 2 min |
| Flash to board | 30 sec |
| **TOTAL FIRST TIME** | **~5-6 min** ⚡⚡⚡⚡⚡ |
| **TOTAL NEXT BUILD** | **~2.5 min** ⚡⚡⚡⚡⚡ |

No setup needed! Image auto-pulls from Docker Hub!

---

## 📋 Commands Reference (Docker)

| Command | What it does | Time |
|---------|-------------|------|
| `docker-compose run fpga-compiler fpga.bat build -Project lab2` | Build a project | 2 min |
| `docker-compose run fpga-compiler fpga.bat flash -Project lab2` | Flash to board | 30 sec |
| `docker-compose run fpga-compiler fpga.bat list` | List all projects | 1 sec |

## 📁 Project Structure

```
FPGA_Compiler_window/
├── fpga.bat                 # Windows launcher
├── fpga.ps1                 # Main script
├── publish-to-release.ps1   # Tool for publishing to GitHub Release
├── README.md                # This file
├── toolchain.json           # Configuration
│
├── app/                     # Your projects
│   ├── lab/                (prebuilt example)
│   └── lab2/               (build from source)
│       ├── top.v
│       └── constraints.xdc
│
├── build/                   # Build outputs
│   └── lab2/
│       ├── lab2.json
│       ├── lab2.fasm
│       ├── lab2.bit
│       └── lab2.log
│
└── .toolchain/              # Cached tools
    └── tools\openxc7\
```

---

## 🎓 Create Your Own Project

### Step 1: Create Project Folder

```powershell
mkdir app\my_design
```

### Step 2: Add Verilog File (`top.v`)

Create `app\my_design\top.v`:
```verilog
module top (
    input clk,
    output led
);
    // Your design here
    assign led = clk;  // Example
endmodule
```

### Step 3: Add Constraints File (`constraints.xdc`)

Create `app\my_design\constraints.xdc`:
```tcl
set_property -dict {PACKAGE_PIN E3 IOSTANDARD LVCMOS33} [get_ports {clk}]
set_property -dict {PACKAGE_PIN H17 IOSTANDARD LVCMOS33} [get_ports {led}]
```

### Step 4: Build & Flash

```powershell
docker-compose run fpga-compiler fpga.bat build -Project my_design
docker-compose run fpga-compiler fpga.bat flash -Project my_design
```

---

## 🔄 Adding More Projects

Once you have the repo cloned, add new projects anytime:

```powershell
# 1. Create project folder
mkdir app\their_project

# 2. Add top.v and constraints.xdc

# 3. Build with Docker
docker-compose run fpga-compiler fpga.bat build -Project their_project

# 4. Flash to board
docker-compose run fpga-compiler fpga.bat flash -Project their_project
```

List all projects:
```powershell
docker-compose run fpga-compiler fpga.bat list
```

---

## ❌ Troubleshooting

### Docker not installed
- Download: https://www.docker.com/products/docker-desktop
- Install and restart

### "Image pull failed" / "No image found"
```powershell
# Build the image locally (one-time, 10 min)
docker build -t fpga-compiler .

# Then retry
docker-compose run fpga-compiler fpga.bat build -Project lab2
```

### Build fails / "module not found"
- Check `app/lab2/top.v` syntax
- Module name must be `top`
- Check constraints file: `app/lab2/constraints.xdc`

### ".bit generation failed"
- Check Verilog syntax errors
- Module name must be `top`
- Check log file: `build/lab2/lab2.log`

---

## 🔧 Tools Used

- **Yosys** - Synthesis (Verilog → JSON)
- **nextpnr-xilinx** - Place & Route (JSON → FASM)
- **fasm2frames** - Frame generation (FASM → Frames)
- **xc7frames2bit** - Bitstream (Frames → BIT)
- **openFPGALoader** - Flashing to board
- **MSYS2** - Package manager for Yosys/openFPGALoader

---

## 📚 References

- [Yosys](https://github.com/YosysHQ/yosys)
- [nextpnr-xilinx](https://github.com/openXC7/nextpnr-xilinx)
- [Project X-Ray](https://github.com/openXC7/prjxray)
- [openFPGALoader](https://github.com/trabucayre/openFPGALoader)
- [Nexys A7-100T Manual](https://digilent.com/reference/programmable-logic/nexys-a7/reference-manual)

