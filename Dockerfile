# FPGA Compiler for Nexys A7-100T - Complete Self-Contained Toolchain
# This image contains Yosys, nextpnr-xilinx, prjxray, and openFPGALoader.
FROM mcr.microsoft.com/powershell:7.4-ubuntu-22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC

# Install system dependencies
RUN apt-get update && apt-get install -y \
    curl wget git libusb-1.0-0 libftdi1 libhidapi-libusb0 \
    python3 python3-pip python3-dev python3-venv \
    build-essential cmake libboost-all-dev libeigen3-dev \
    pkg-config \
    && rm -rf /var/lib/apt/lists/*

# Install OSS CAD Suite (provides Yosys and other core tools)
RUN mkdir -p /opt/fpga && \
    cd /opt/fpga && \
    wget -q https://github.com/YosysHQ/oss-cad-suite-build/releases/download/2024-04-30/oss-cad-suite-linux-x64-20240430.tgz && \
    tar -xzf oss-cad-suite-linux-x64-20240430.tgz && \
    rm oss-cad-suite-linux-x64-20240430.tgz

ENV PATH="/opt/fpga/oss-cad-suite/bin:/usr/local/bin:${PATH}"
ENV XRAY_DB_DIR="/opt/fpga/prjxray-db"
ENV PYTHONPATH="/opt/fpga/prjxray:/opt/fpga/prjxray/third_party/fasm:${PYTHONPATH}"

# Clone Project X-Ray DB and Tools (recursive for submodules)
RUN git clone --depth 1 https://github.com/f4pga/prjxray-db.git /opt/fpga/prjxray-db && \
    git clone --recursive https://github.com/f4pga/prjxray.git /opt/fpga/prjxray && \
    pip3 install \
        textx \
        PyYAML \
        simplejson \
        intervaltree \
        antlr4-python3-runtime==4.9.2 \
        fpdf2 \
        ply && \
    pip3 install /opt/fpga/prjxray && \
    pip3 install /opt/fpga/prjxray/third_party/fasm

# Build Project X-Ray tools (xc7frames2bit etc)
RUN cd /opt/fpga/prjxray && \
    mkdir -p build && cd build && \
    cmake -DCMAKE_INSTALL_PREFIX=/usr/local .. && \
    make -j$(nproc) && \
    make install && \
    # Create shims for python tools
    echo '#!/usr/bin/env python3' > /usr/local/bin/fasm2frames && \
    echo 'import sys; import os; sys.path.insert(0, "/opt/fpga/prjxray"); sys.path.insert(0, "/opt/fpga/prjxray/third_party/fasm"); from utils.fasm2frames import main; main()' >> /usr/local/bin/fasm2frames && \
    chmod +x /usr/local/bin/fasm2frames

# Build nextpnr-xilinx
RUN git clone --recursive https://github.com/openXC7/nextpnr-xilinx.git /opt/fpga/nextpnr-xilinx && \
    cd /opt/fpga/nextpnr-xilinx && \
    mkdir build && cd build && \
    cmake -DARCH=xilinx -DPRJXRAY_DB_DIR=/opt/fpga/prjxray-db -DCMAKE_INSTALL_PREFIX=/usr/local .. && \
    make -j$(nproc) && \
    make install

# Generate ChipDB for Artix-7 100T (Required for nextpnr-xilinx)
# This uses the python scripts in nextpnr-xilinx/xilinx/python/
RUN cd /opt/fpga/nextpnr-xilinx/xilinx/python && \
    python3 bbaexport.py --device xc7a100tcsg324-1 --xray /opt/fpga/prjxray-db/artix7 --bba xc7a100t.bba && \
    /opt/fpga/nextpnr-xilinx/build/bbasm -l xc7a100t.bba xc7a100t.bin && \
    mkdir -p /usr/local/share/nextpnr/xilinx && \
    cp xc7a100t.bin /usr/local/share/nextpnr/xilinx/chipdb-xc7a100t.bin


WORKDIR /workspace
COPY . /workspace

RUN chmod +x /workspace/fpga.ps1 /workspace/entrypoint.sh || true

ENTRYPOINT ["/workspace/entrypoint.sh"]
