#!/usr/bin/env bash
set -euo pipefail

export ARCHITECT="$(arch)"
export DEBIAN_FRONTEND="noninteractive"
export PIP_INSTALL="python3 -m pip install --no-cache-dir"
export UV_PIP_INSTALL="uv pip install"


### Dependency Versions
# PyTorch: Default to torch 2.8.0, can be overridden by --torch-version
TORCH_VERSION="2.12.0"
TORCHVISION_VERSION="0.27.0" 

while [[ $# -gt 0 ]]; do
    case "$1" in
        --cann-version)
            CANN_VERSION="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--cann-version <9.3.0>]"
            exit 1
            ;;
    esac
done

# 只支持自建的 CANN 9.3.0 镜像
if [[ "${CANN_VERSION}" != "9.3.0" ]]; then
    echo "Unsupported CANN version: ${CANN_VERSION}"
    echo "Supported versions: 9.3.0"
    exit 1
fi


TORCH_NPU_VERSION="${TORCH_NPU_VERSION:-2.12.0.post2}"

### Install required dependencies
## APT packages
dnf makecache
dnf install -y \
    glibc-all-langpacks \
    ca-certificates \
    gcc \
    gcc-c++ \
    make \
    cmake \
    pkgconf \
    zlib-devel \
    wget \
    curl \
    zip \
    unzip \
    python3-devel

## Setup
locale-gen en_US.UTF-8
update-ca-certificates
export LANG=en_US.UTF-8
export LANGUAGE=en_US:en
export LC_ALL=en_US.UTF-8

## Python packages
${PIP_INSTALL} --upgrade pip
${PIP_INSTALL} uv
export UV_NO_CACHE=true
export UV_SYSTEM_PYTHON=true
export UV_INDEX_STRATEGY=unsafe-best-match
${UV_PIP_INSTALL} \
    pybind11 \
    pyyaml \
    decorator \
    scipy \
    attrs \
    psutil


### Install pytorch
## torch
${UV_PIP_INSTALL} \
    torch==${TORCH_VERSION} \
    torchvision==${TORCHVISION_VERSION} \
    torchaudio==${TORCH_VERSION} \
    --index-url ${TORCH_CACHE_URL:="https://download.pytorch.org/whl/cpu"} \
    --extra-index-url ${PYPI_CACHE_URL:="https://pypi.org/simple/"}
## torch_npu
# GitCode does not allow UV downloads.
${PIP_INSTALL} ${TORCH_NPU_URL}
