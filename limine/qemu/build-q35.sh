#!/bin/bash
# Build Project Mu QemuQ35Pkg (DEBUG) with the Surface-like image policy
# (BlockImagesWithoutNxFlag = 1) inside Microsoft's mu_devops container.
# Output: mu_tiano_platforms/Build/QemuQ35PkgX64/DEBUG_GCC5/FV/QEMUQ35_{CODE,VARS}.fd
#   ./build-q35.sh   (log: build-q35.log; run images with ./run-q35.sh)
set -euo pipefail
cd "$(dirname "$0")"

if [[ ! -d mu_tiano_platforms ]]; then
    git clone -q --branch v15.0.2 --depth 1 https://github.com/microsoft/mu_tiano_platforms
    git -C mu_tiano_platforms apply "$PWD/mu-q35-surface-like-policy.patch"
fi

exec podman run --rm --userns=keep-id -v "$PWD/mu_tiano_platforms:/work:Z" -w /work \
    ghcr.io/microsoft/mu_devops/ubuntu-24-dev:latest bash -lc '
        set -euo pipefail
        python3 -m venv .venv && . .venv/bin/activate
        pip install -q --upgrade -r pip-requirements.txt
        B="Platforms/QemuQ35Pkg/PlatformBuild.py TOOL_CHAIN_TAG=GCC5 TARGET=DEBUG"
        stuart_setup  -c $B
        stuart_update -c $B
        stuart_build  -c $B
        ls -la Build/QemuQ35PkgX64/DEBUG_GCC5/FV/*.fd'
