#!/usr/bin/env bash
# Compile TRELLIS.2's GPU extensions for this GPU inside the engine's env/
# (in $IMG2MESH_HOME, which install.sh sets; else beside this script): CUDA
# for NVIDIA, or HIP for AMD when install.sh wrote "rocm" to ./accelerator.
set -eo pipefail
cd "${IMG2MESH_HOME:-$(dirname "$0")}"
ROOT=$PWD
export MAMBA_ROOT_PREFIX=$ROOT/tools/mamba
eval "$("$ROOT/tools/bin/micromamba" shell hook -s bash)"
micromamba activate "$ROOT/env"
set -u
export CC=$CONDA_PREFIX/bin/x86_64-conda-linux-gnu-gcc
export CXX=$CONDA_PREFIX/bin/x86_64-conda-linux-gnu-g++
export MAX_JOBS=${MAX_JOBS:-2}
if [ "$(cat "$ROOT/accelerator" 2>/dev/null)" = rocm ]; then
  # The HIP compiler and headers come from AMD's rocm-sdk-devel wheel in env/.
  SDK="$(rocm-sdk path --root)"
  export ROCM_PATH=$SDK ROCM_HOME=$SDK HIP_PATH=$SDK PATH="$SDK/bin:$PATH"
  ARCH="$(python -c 'import torch;print(torch.cuda.get_device_properties(0).gcnArchName.split(":")[0])')"
  export GPU_ARCHS=$ARCH PYTORCH_ROCM_ARCH=$ARCH BUILD_TARGET=rocm
  pkgs=(ext/nvdiffrast-hip ext/nvdiffrec-rocm ext/CuMesh-rocm ext/FlexGEMM-rocm TRELLIS.2/o-voxel)
  # o-voxel names the CUDA CuMesh and FlexGEMM as git dependencies; the HIP
  # builds above already provide them.
  nodeps=(--no-deps)
else
  export CUDA_HOME=$CONDA_PREFIX
  ARCH="$(python -c 'import torch;print("%d.%d"%torch.cuda.get_device_capability())')"
  export TORCH_CUDA_ARCH_LIST=$ARCH
  pkgs=(ext/nvdiffrast ext/nvdiffrec ext/CuMesh ext/FlexGEMM TRELLIS.2/o-voxel)
  nodeps=()
fi
for pkg in "${pkgs[@]}"; do
  echo "=== building $pkg (arch $ARCH)"
  python -m pip install "$ROOT/$pkg" --no-build-isolation "${nodeps[@]}"
done
echo "=== all extensions built"
