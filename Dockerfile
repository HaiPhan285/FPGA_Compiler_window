# Multi-stage FPGA Compiler image — build/strip oss-cad-suite in builder, copy runtime files to a slim final image.

# Builder: download and prune oss-cad-suite
FROM ubuntu:22.04 AS builder
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC

RUN apt-get update && apt-get install -y --no-install-recommends \
    wget ca-certificates tar xz-utils binutils && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /opt/fpga && cd /opt/fpga && \
    wget -q https://github.com/YosysHQ/oss-cad-suite-build/releases/download/2024-04-30/oss-cad-suite-linux-x64-20240430.tgz && \
    tar -xzf oss-cad-suite-linux-x64-20240430.tgz && rm oss-cad-suite-linux-x64-20240430.tgz

# Strip symbols and remove docs/test files to reduce size before copying
RUN set -eux; \
    find /opt/fpga/oss-cad-suite -type f -executable -exec strip --strip-unneeded {} + || true; \
    rm -rf /opt/fpga/oss-cad-suite/share/doc /opt/fpga/oss-cad-suite/share/man /opt/fpga/oss-cad-suite/include || true; \
    find /opt/fpga/oss-cad-suite -name "*.a" -delete || true; \
    find /opt/fpga/oss-cad-suite -name "__pycache__" -type d -exec rm -rf {} + || true

# Final: minimal runtime
FROM ubuntu:22.04-slim
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC

# Install runtime packages and PowerShell
RUN apt-get update && apt-get install -y --no-install-recommends \
    wget curl ca-certificates libusb-1.0-0 libftdi1 libhidapi-libusb0 python3 python3-pip gnupg \
    && wget -q https://packages.microsoft.com/config/ubuntu/22.04/packages-microsoft-prod.deb \
    && dpkg -i packages-microsoft-prod.deb \
    && rm packages-microsoft-prod.deb \
    && apt-get update && apt-get install -y --no-install-recommends powershell \
    && rm -rf /var/lib/apt/lists/*

# Copy only runtime parts from builder (bins and shared libs)
COPY --from=builder /opt/fpga/oss-cad-suite/bin /opt/fpga/oss-cad-suite/bin
COPY --from=builder /opt/fpga/oss-cad-suite/lib /opt/fpga/oss-cad-suite/lib
COPY --from=builder /opt/fpga/oss-cad-suite/share/nextpnr /opt/fpga/oss-cad-suite/share/nextpnr || true

ENV PATH="/opt/fpga/oss-cad-suite/bin:/usr/local/bin:${PATH}"

WORKDIR /workspace
COPY . /workspace

RUN chmod +x /workspace/fpga.ps1 /workspace/entrypoint.sh || true
# Populate toolchain env at build time (best-effort; Write-ToolchainEnv may depend on files present)
RUN pwsh -NoProfile -ExecutionPolicy Bypass -Command ". /workspace/fpga.ps1; Write-ToolchainEnv" || true

ENTRYPOINT ["/workspace/entrypoint.sh"]
