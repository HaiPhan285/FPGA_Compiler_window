# FPGA Compiler for Windows (Docker)

Open-source build flow for **Digilent Nexys A7-100T** on Windows.
No Vivado, no WSL, no messy toolchains. **Just Docker.**

---

## 🚀 Quick Start

### 1. Clone and Enter
```powershell
git clone https://github.com/HaiPhan285/FPGA_Compiler_window.git
cd FPGA_Compiler_window
```

### 2. Build the Docker Image
*Required once. Takes ~5 minutes.*
```powershell
docker-compose build
```

### 3. Build a Project
```powershell
docker-compose run fpga-compiler fpga.ps1 build -Project seven_segment
```

### 4. Flash to Board
*Note: Requires USB setup (see section below)*
```powershell
docker-compose run fpga-compiler fpga.ps1 flash -Project seven_segment
```

---

## 🔌 USB Setup for Flashing (Required for Windows)

Because the build environment runs inside a Docker container, you must explicitly pass the USB connection from Windows to the container to flash the board.

**1. Install usbipd-win**
Open PowerShell as Administrator:
```powershell
winget install dorssel.usbipd-win
```
*Restart your terminal after installation.*

**2. Connect the Board**
Plug in your Nexys A7 via USB.

**3. Bind the Device**
Find the "Digilent" device and note its `BUSID`:
```powershell
usbipd list
# Example: 2-2    0403:6010    Digilent USB Device
```
Bind the device (replace `<BUSID>` with your actual ID, e.g., `2-2`):
```powershell
usbipd bind -b <BUSID>
```

**4. Attach to WSL**
Run this command whenever you plug the board in:
```powershell
usbipd attach --wsl -b <BUSID>
```

**5. Flash**
Now run the flash command from Quick Start.

---

## ⏱️ Timeline for New Users

| Step | Time |
|------|------|
| Clone repo | 1 min |
| Docker image build | 5 min |
| **USB Setup (One-time)** | **2 min** |
| Build project | 2 min |
| Flash to board | 30 sec |
| **TOTAL FIRST TIME** | **~10 min** |

*Note: Subsequent builds take only ~2 minutes. No Ubuntu installation required.*

---

## 📋 Commands Reference

| Command | Description |
|---------|-------------|
| `docker-compose build` | Build the Docker image (First time only) |
| `docker-compose run fpga-compiler fpga.ps1 build -Project <name>` | Build a project |
| `docker-compose run fpga-compiler fpga.ps1 flash -Project <name>` | Flash to board |
| `docker-compose run fpga-compiler fpga.ps1 list` | List available projects |

## 📁 Project Structure

```
FPGA_Compiler_window/
├── Dockerfile              # Docker environment definition
├── docker-compose.yml      # Docker configuration
├── fpga.ps1                # Main script
├── README.md               # This file
│
├── app/                    # Your projects
│   ├── lab/
│   └── seven_segment/      # Example project
│
├── build/                  # Build outputs (created after build)
│   └── seven_segment/
│       ├── seven_segment.bit
│       └── ...
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
    assign led = clk;
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
docker-compose run fpga-compiler fpga.ps1 build -Project my_design
docker-compose run fpga-compiler fpga.ps1 flash -Project my_design
```

---

## ❌ Troubleshooting

### "unable to open ftdi device" during flash
- Ensure **usbipd** is installed.
- Run `usbipd list` to check the device state.
- Run `usbipd attach --wsl -b <BUSID>` again.

### Docker build fails
- Ensure Docker Desktop is running.
- Check your internet connection (downloads OSS CAD Suite).

### "Module not found" or "Syntax Error"
- Check `top.v` for syntax errors.
- Ensure the top module is named `top` or specified correctly.

---

## 🔧 Tools Used (Inside Docker)
- **Yosys** - Synthesis
- **nextpnr-xilinx** - Place & Route
- **Project X-Ray** - Bitstream generation
- **openFPGALoader** - Flashing

## 📚 References
- [Yosys](https://github.com/YosysHQ/yosys)
- [nextpnr-xilinx](https://github.com/openXC7/nextpnr-xilinx)
- [openFPGALoader](https://github.com/trabucayre/openFPGALoader)
- [usbipd-win](https://github.com/dorssel/usbipd-win)
