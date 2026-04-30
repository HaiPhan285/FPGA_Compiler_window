# FPGA Compiler for Nexys A7-100T - Docker Container
# Quick start: docker-compose run fpga-compiler fpga.bat build -Project lab2
# Includes: Yosys, openFPGALoader. Downloads nextpnr-xilinx & Project X-Ray DB on first run.

FROM mcr.microsoft.com/powershell:7.4-ubuntu-22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC

# Install all required dependencies
RUN apt-get update && apt-get install -y \
    curl wget git build-essential \
    python3 python3-dev python3-pip \
    yosys \
    cmake libusb-1.0-0-dev libftdi-dev libftdi1 libhidapi-dev pkg-config libudev-dev \
    ca-certificates gnupg lsb-release apt-transport-https \
    && rm -rf /var/lib/apt/lists/*

# Pre-create toolchain directory for volume mounting
RUN mkdir -p /workspace/.toolchain/tools

# Copy project files
COPY fpga.bat /workspace/
COPY fpga.ps1 /workspace/
COPY toolchain.json /workspace/
COPY app /workspace/app

WORKDIR /workspace

RUN chmod +x /workspace/fpga.bat /workspace/fpga.ps1 || true

ENTRYPOINT ["/usr/bin/pwsh"]
