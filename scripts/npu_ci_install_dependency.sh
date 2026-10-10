#!/usr/bin/env bash
#
# 算子编译环境的依赖安装脚本。
#
# 与上游版本的区别（改动处都标了 <改>）：
#   1) 同时支持 apt(ubuntu) 与 dnf/yum(openEuler)，按镜像里有什么自动选
#   2) 只支持 CANN 9.3.0：官方 gitcode 上没有 26.3.0 的 release，
#      所以 torch_npu 从华为源按版本安装（不需要再拼 wheel URL）
#   3) 补上 python3-devel（编 torch_memory_saver 的 C++ 扩展要 Python.h）；
#      zip/unzip 也从这里统一装，后面的 Pack up packages 步骤直接用
#   4) torchvision / torchaudio 按 torch 版本配套安装（原来写死 0.25.0 /
#      ${TORCH_VERSION}，换 torch 2.12.0 后 torchaudio 2.12.0 根本不存在）
#
set -euo pipefail

export ARCHITECT="$(arch)"
export DEBIAN_FRONTEND="noninteractive"
export PIP_INSTALL="python3 -m pip install --no-cache-dir"
export UV_PIP_INSTALL="uv pip install"

# openEuler 的 python 有 PEP668 保护，pip / uv 都需要绕过
export PIP_BREAK_SYSTEM_PACKAGES=1
export UV_BREAK_SYSTEM_PACKAGES=1

PY_TAG="cp$(python3 -c 'import sys; print(f"{sys.version_info.major}{sys.version_info.minor}")')"

### Dependency Versions
# <改> 默认跟着 workflow matrix 里的 torch 版本走
TORCH_VERSION="2.12.0"
TORCHVISION_VERSION=""
TORCHAUDIO_VERSION=""
TORCH_NPU_VERSION=""
# 先置空，误传或漏传 --cann-version 时才会走到下面那句友好的提示，
# 而不是被 set -u 抛 "CANN_VERSION: unbound variable"
CANN_VERSION=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --cann-version)
            CANN_VERSION="$2"
            shift 2
            ;;
        # <改> 新增两个可选参数
        --torch-version)
            TORCH_VERSION="$2"
            shift 2
            ;;
        --torch-npu-version)
            TORCH_NPU_VERSION="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--cann-version <9.3.0>] [--torch-version <2.12.0>] [--torch-npu-version <2.12.0.post2>]"
            exit 1
            ;;
    esac
done

### torchvision / torchaudio 与 torch 严格配对，这里只列已经确认过的组合
case "${TORCH_VERSION}" in
    "2.10.0")
        TORCHVISION_VERSION="0.25.0"
        TORCHAUDIO_VERSION="2.10.0"
        ;;
    "2.12.0")
        TORCHVISION_VERSION="0.27.0"   # torchvision 0.27.0 requires torch==2.12.0
        TORCHAUDIO_VERSION=""          # torchaudio 最新只到 2.11.0，没有 2.12.0
        ;;
    *)
        echo "[warn] 没为 torch ${TORCH_VERSION} 配好 torchvision/torchaudio，将跳过这两个包"
        ;;
esac

# <改> 只支持自建的 CANN 9.3.0 镜像，所以不用再按版本拼 torch_npu 的 wheel URL
if [[ "${CANN_VERSION}" != "9.3.0" ]]; then
    echo "Unsupported CANN version: ${CANN_VERSION}"
    echo "Supported versions: 9.3.0"
    exit 1
fi

# CANN 9.3.0 是 weekly，gitcode 上没有对应的 PTA release，所以用华为源上的
# 2.12.0.post2（官方兼容矩阵里标的是 CANN 9.1.X，用在 9.3.0 上要真机冒烟验证）
TORCH_NPU_VERSION="${TORCH_NPU_VERSION:-2.12.0.post2}"

echo "==================================================================="
echo "CANN       : ${CANN_VERSION}"
echo "torch      : ${TORCH_VERSION} (vision=${TORCHVISION_VERSION:-skip} audio=${TORCHAUDIO_VERSION:-skip})"
echo "torch_npu  : ${TORCH_NPU_VERSION}"
echo "python tag : ${PY_TAG}   arch: ${ARCHITECT}"
echo "==================================================================="

### --------------------------------------------------------------------
### 系统依赖：按包管理器分支
### --------------------------------------------------------------------
if command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
    PKG_MGR="$(command -v dnf 2>/dev/null || command -v yum)"
    echo "Using package manager: ${PKG_MGR}"
    ${PKG_MGR} makecache
    # <改> python3-devel 提供 Python.h；zip/unzip 供后面的打包步骤使用
    ${PKG_MGR} install -y \
        zip \
        unzip \
        which \
        findutils \
        tar \
        xz \
        git \
        ca-certificates \
        python3-devel \
        numactl-devel \
        sqlite-devel
    ${PKG_MGR} clean all || true
    rm -rf /var/cache/yum
elif command -v apt-get >/dev/null 2>&1; then
    echo "Using package manager: apt-get"
    apt-get update -y
    apt-get upgrade -y
    apt-get install -y \
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
        unzip \
        python3-dev
else
    echo "Error: 没找到 dnf/yum/apt-get"
    exit 1
fi

## Setup（locale-gen 只有 debian 系有）
if command -v locale-gen >/dev/null 2>&1; then
    locale-gen en_US.UTF-8
fi
command -v update-ca-certificates >/dev/null 2>&1 && update-ca-certificates
export LANG=${LANG:-en_US.UTF-8}
export LANGUAGE=${LANGUAGE:-en_US:en}
export LC_ALL=${LC_ALL:-en_US.UTF-8}

### --------------------------------------------------------------------
### Python 依赖
### --------------------------------------------------------------------
${PIP_INSTALL} --upgrade pip setuptools wheel
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

### --------------------------------------------------------------------
### PyTorch
### --------------------------------------------------------------------
TORCH_PKGS=("torch==${TORCH_VERSION}")
[[ -n "${TORCHVISION_VERSION}" ]] && TORCH_PKGS+=("torchvision==${TORCHVISION_VERSION}")
[[ -n "${TORCHAUDIO_VERSION}" ]]  && TORCH_PKGS+=("torchaudio==${TORCHAUDIO_VERSION}")

${UV_PIP_INSTALL} \
    "${TORCH_PKGS[@]}" \
    --index-url ${TORCH_CACHE_URL:="https://download.pytorch.org/whl/cpu"} \
    --extra-index-url ${PYPI_CACHE_URL:="https://pypi.org/simple/"}

### torch_npu
# GitCode 不支持 UV 下载，所以这里始终用 pip
${PIP_INSTALL} "torch-npu==${TORCH_NPU_VERSION}" \
    --extra-index-url https://ascend.devcloud.huaweicloud.com/pypi/simple/

### --------------------------------------------------------------------
### 自检：编算子前先确认这几个 import 都是通的
### --------------------------------------------------------------------
python3 - <<'PY'
import torch, torch_npu, pybind11
print("torch     :", torch.__version__)
print("torch_npu :", torch_npu.__version__)
print("pybind11  :", pybind11.__version__, pybind11.get_include())
PY
