#!/usr/bin/env bash
set -euo pipefail

export ARCHITECT="$(arch)"
export DEBIAN_FRONTEND="noninteractive"
export PIP_INSTALL="python3 -m pip install --no-cache-dir"
export UV_PIP_INSTALL="uv pip install"


### Dependency Versions
# PyTorch: Default to torch 2.10.0, can be overridden by --torch-version
TORCH_VERSION="2.10.0"
TORCHVISION_VERSION="0.25.0"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --cann-version)
            CANN_VERSION="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--cann-version <9.1.0|9.2.0>]"
            exit 1
            ;;
    esac
done

case "${CANN_VERSION}" in
    "9.1.0")
        TORCH_NPU_URL="https://gitcode.com/Ascend/pytorch/releases/download/v26.1.0-pytorch2.10.0/torch_npu-2.10.0.post4-cp312-cp312-manylinux_2_28_${ARCHITECT}.whl"
        ;;
    # 9.2.0 目前只有 beta 镜像：9.2.0-beta.1-<hw>-ubuntu22.04-py3.12
    # 对应 torch_npu release 为 v26.2.0-beta.1-pytorch2.10.0
    "9.2.0")
        TORCH_NPU_URL="https://gitcode.com/Ascend/pytorch/releases/download/v26.2.0-beta.1-pytorch2.10.0/torch_npu-2.10.0.post5-cp312-cp312-manylinux_2_28_${ARCHITECT}.whl"
        ;;
    *)
        echo "Unsupported CANN version: ${CANN_VERSION}"
        echo "Supported versions: 9.1.0, 9.2.0"
        exit 1
        ;;
esac

apt update -y && \
apt upgrade -y && \
apt install -y \
    locales \
    ca-certificates \
    build-essential \
    cmake \
    ccache \
    pkg-config \
    zlib1g-dev \
    wget \
    curl \
    zip \
    unzip

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
${PIP_INSTALL} ${TORCH_NPU_URL}

### CANN 9.2.0 兼容处理
## torch_npu 26.2.0-beta.1 里自带的 acl 头 graph/ge_error_codes.h 仍然把 ge::GRAPH_* 常量
## 定义在自己文件里，而 CANN 9.2.0 已经把这批常量挪到了 graph/error_codes.h。两条 include
## 链（tiling/tiling_api.h 和 torch_npu 的 OpCommand.h）在同一个编译单元里相遇就会报
## redefinition。
## 注意：不能把 CANN 的同名头整份拷过来 —— 那个文件内部是 #include "error_codes.h"
## （相对路径），搬到 torch_npu 的 graph/ 目录下就找不到头了。正确做法是只删掉重复的
## 常量定义，并让这个文件引用 CANN 的新头。
if [[ "${CANN_VERSION}" == "9.2.0" ]]; then
    torch_npu_root="$(python3 -c 'import os, torch_npu; print(os.path.dirname(torch_npu.__file__))' 2>/dev/null || true)"
    if [[ -z "${torch_npu_root}" ]]; then
        torch_npu_root="$(python3 -c 'import os, site; print(os.path.join(site.getsitepackages()[0], "torch_npu"))')"
    fi
    stale_header="${torch_npu_root}/include/third_party/acl/inc/graph/ge_error_codes.h"
    if [[ -f "${stale_header}" ]]; then
        cp -n "${stale_header}" "${stale_header}.torch-npu.orig"
        # 1) 删掉与 CANN graph/error_codes.h 重复的 GRAPH_* 常量定义
        sed -i -E '/^[[:space:]]*const[[:space:]]+graphStatus[[:space:]]+GRAPH_[A-Za-z0-9_]+[[:space:]]*=/d' "${stale_header}"
        # 2) 让旧头引用 CANN 的新头（尖括号走 -I，避免相对路径找不到）
        sed -i '1i #include <graph/error_codes.h>' "${stale_header}"
        echo "INFO: patched ${stale_header} for CANN ${CANN_VERSION} (remaining duplicate consts: $(grep -c -E 'const[[:space:]]+graphStatus[[:space:]]+GRAPH_' "${stale_header}" || true))"
    else
        echo "WARNING: ${stale_header} not found, skip CANN ${CANN_VERSION} acl header compat patch"
    fi
fi
