#!/usr/bin/env bash
# Compile TRELLIS.2's CUDA extensions for this GPU inside the engine's env/
# (in $IMG2MESH_HOME, which install.sh sets; else beside this script).
set -eo pipefail
cd "${IMG2MESH_HOME:-$(dirname "$0")}"
ROOT=$PWD
export MAMBA_ROOT_PREFIX=$ROOT/tools/mamba
eval "$("$ROOT/tools/bin/micromamba" shell hook -s bash)"
micromamba activate "$ROOT/env"
set -u
export CUDA_HOME=$CONDA_PREFIX
export CC=$CONDA_PREFIX/bin/x86_64-conda-linux-gnu-gcc
export CXX=$CONDA_PREFIX/bin/x86_64-conda-linux-gnu-g++
TORCH_CUDA_ARCH_LIST="$(python -c 'import torch;print("%d.%d"%torch.cuda.get_device_capability())')"
export TORCH_CUDA_ARCH_LIST
export MAX_JOBS=${MAX_JOBS:-2}
for pkg in ext/nvdiffrast ext/nvdiffrec ext/CuMesh ext/FlexGEMM TRELLIS.2/o-voxel; do
  echo "=== building $pkg (arch $TORCH_CUDA_ARCH_LIST)"
  python -m pip install "$ROOT/$pkg" --no-build-isolation
done
echo "=== all extensions built"
