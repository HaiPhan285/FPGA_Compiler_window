# FPGA Compiler for Nexys A7-100T - Docker Container
# Instant setup: docker run -v %cd%:/workspace fpga-compiler fpga.bat build -Project lab2

FROM mcr.microsoft.com/windows/servercore:ltsc2022

# Install MSYS2 and dependencies
RUN powershell -Command \
    $ProgressPreference = 'SilentlyContinue'; \
    Invoke-WebRequest -Uri https://github.com/msys2/msys2-installer/releases/download/2024-01-13/msys2-x86_64-20240113.exe -OutFile msys2-installer.exe; \
    .\msys2-installer.exe in -accept-messages -y; \
    Remove-Item msys2-installer.exe; \
    echo "MSYS2 installed"

# Add MSYS2 to PATH
RUN setx /M PATH "C:\msys64\mingw64\bin;C:\msys64\usr\bin;%PATH%"

# Install Yosys, openFPGALoader via MSYS2
RUN C:\msys64\usr\bin\bash.exe -lc "pacman -S --noconfirm mingw-w64-x86_64-yosys mingw-w64-x86_64-openfpgaloader" || exit /b 0

# Copy toolchain (built from publish-to-release.ps1 output)
COPY .toolchain /workspace/.toolchain

# Copy FPGA scripts
COPY fpga.bat /workspace/
COPY fpga.ps1 /workspace/
COPY toolchain.json /workspace/
COPY app /workspace/app

WORKDIR /workspace

# Enable PowerShell execution
RUN powershell -Command Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Force

ENTRYPOINT ["powershell", "-Command"]
