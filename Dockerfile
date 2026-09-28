# Dockerfile for cross-building r8152 for the ARM64 QNAP TS-216/TS-416 family.
#
# The image itself is x86_64 and the aarch64 module is CROSS-compiled. This is
# deliberate rather than a multi-arch/qemu build:
#   - QDK's qbuild is arch-agnostic shell and runs natively here.
#   - QNAP cross-compiled this kernel the same way; their arm64 config records
#     CONFIG_CC_VERSION_TEXT="gcc (Debian 4.9.2-10) 4.9.2", a Debian x86 host.
#   - The kernel tree has to be built from source for arm64 (see build_kernel.sh),
#     which under emulation would be roughly an order of magnitude slower.
FROM ubuntu:20.04

# Avoid interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install build dependencies
RUN apt-get update && apt-get install -y \
    build-essential \
    gcc-aarch64-linux-gnu \
    libelf-dev \
    bc \
    wget \
    curl \
    bzip2 \
    xz-utils \
    flex \
    bison \
    libssl-dev \
    libncurses5-dev \
    git \
    unzip \
    kmod \
    cpio \
    rsync \
    python3 \
    python3-pip \
    file \
    jq \
    dos2unix \
    sudo \
    && rm -rf /var/lib/apt/lists/*

# Install QDK (QNAP Development Kit)
RUN git clone https://github.com/qnap-dev/QDK.git /opt/QDK && \
    cd /opt/QDK && \
    chmod +x InstallToUbuntu.sh && \
    yes | ./InstallToUbuntu.sh install

# Set working directory
WORKDIR /build

# Target platform. Supplied by build.sh from versions.yml (the single source of
# truth); the defaults here only keep a bare `docker build .` working.
ARG TARGET_MODEL=TS-X16
ARG KERNEL_SERIES=5.10
ARG KERNEL_CONFIG_FILE=linux-5.10-arm64.config
ARG KERNEL_VERSION=5.10.60
ARG KERNEL_ARCH=arm64
ARG CROSS_COMPILE_PREFIX=aarch64-linux-gnu-

# The driver source is downloaded at runtime by build_driver.sh. Keeping it out of
# this image lets Actions reuse the expensive prepared-kernel layer.
ENV ARCH=${KERNEL_ARCH}
ENV CROSS_COMPILE=${CROSS_COMPILE_PREFIX}
ENV KERNEL_VERSION=${KERNEL_VERSION}
ENV KERNEL_SRC=/build/kernel/linux-source
ENV KERNEL_CONFIG=/build/kernel/target.config
ENV PATH="/opt/QDK:${PATH}"

RUN mkdir -p /build/driver /build/qpkg /build/output /build/kernel

# QNAP's kernel source, plus the target model's GPL kernel config. The tree
# arrives pre-built for x86_64; build_kernel.sh rebuilds it for arm64.
COPY GPL_QTS/src/linux-${KERNEL_SERIES} /build/kernel/linux-source
COPY GPL_QTS/kernel_cfg/${TARGET_MODEL}/${KERNEL_CONFIG_FILE} /build/kernel/target.config

# Configure and build the kernel tree for arm64. Cached as an image layer, so the
# cost is paid once rather than on every driver compile.
COPY build_kernel.sh /build/
RUN chmod +x /build/build_kernel.sh && /build/build_kernel.sh

# Copy build scripts
COPY build_driver.sh /build/
COPY build_qpkg.sh /build/

# Make scripts executable
RUN chmod +x /build/*.sh

# Default command
CMD ["/bin/bash"]
