# Third-party software and licences

Omamesh's own code — the app and the engine scripts — is MIT licensed
(see [LICENSE](LICENSE)). It stands on a lot of other people's work, listed
here with the licence each one comes under.

**None of the software below is bundled with Omamesh.** The app package
contains only Omamesh's own code. `omamesh-setup` downloads everything else
from its original source, onto your computer, the first time you run it.

## Read this before commercial use

TRELLIS.2 bakes each model's textures with NVIDIA's **nvdiffrast**, and uses
part of NVIDIA's **nvdiffrec** for its materials. CuMesh, which builds the
mesh, includes **cubvh**, whose BVH code comes from NVIDIA's instant-ngp. All
three come under NVIDIA Source Code Licences that allow use
*"non-commercially"*, defined as *"for research or evaluation purposes only"*
(nvdiffrast adds *"and not for any direct or indirect monetary gain"*). The
same applies to their AMD ports. Everything else in the engine allows
commercial use.

So, as set up, Omamesh is for **non-commercial use**. If you want to use it,
or models made with it, to earn money, read those three licences first and
decide for yourself; this page is not legal advice.

The image encoder, Meta's **DINOv3**, comes under Meta's DINOv3 Licence,
which you read and accept on Hugging Face during setup.

## The model and its parts

| Component | By | Licence | Used for |
|---|---|---|---|
| [TRELLIS.2](https://github.com/microsoft/TRELLIS.2) (including O-Voxel) | Microsoft | MIT | The image-to-3D pipeline |
| [TRELLIS.2-4B](https://huggingface.co/microsoft/TRELLIS.2-4B) weights | Microsoft | MIT | The model itself |
| [TRELLIS-image-large](https://huggingface.co/microsoft/TRELLIS-image-large) (sparse-structure decoder only) | Microsoft | MIT | Part of the TRELLIS.2 pipeline |
| [DINOv3 ViT-L/16](https://huggingface.co/facebook/dinov3-vitl16-pretrain-lvd1689m) | Meta | DINOv3 Licence (accepted on Hugging Face) | Reading the photo |
| [BiRefNet](https://huggingface.co/ZhengPeng7/BiRefNet) | Peng Zheng et al. | MIT | Removing the background |
| [nvdiffrast](https://github.com/NVlabs/nvdiffrast) | NVIDIA | NVIDIA Source Code Licence (1-Way Commercial) — **non-commercial use only** | Baking textures |
| [nvdiffrec](https://github.com/NVlabs/nvdiffrec) (renderutils, via [this fork](https://github.com/JeffreyXiang/nvdiffrec)) | NVIDIA | NVIDIA Source Code Licence for nvdiffrec — **non-commercial use only** | Materials |
| [CuMesh](https://github.com/JeffreyXiang/CuMesh) | Jianfeng Xiang | MIT | Building and simplifying meshes |
| [cubvh](https://github.com/JeffreyXiang/cubvh) (inside CuMesh) | Jiaxiang Tang (kiui); BVH code from NVIDIA's instant-ngp | MIT, plus the NVIDIA Source Code Licence for instant-ngp for NVIDIA's code — **non-commercial use only** | Ray and distance queries on meshes |
| [xatlas](https://github.com/jpcy/xatlas) (inside CuMesh) | Jonathan Young | MIT | Unwrapping meshes for textures |
| [FlexGEMM](https://github.com/JeffreyXiang/FlexGEMM) | Jianfeng Xiang | MIT | Sparse convolutions |
| [Eigen](https://gitlab.com/libeigen/eigen) | Eigen authors | MPL-2.0 | Maths library inside O-Voxel |

### On AMD graphics cards

Setup swaps the GPU parts above for community HIP ports, and xformers for
flash-attention. TRELLIS.2's own O-Voxel and Eigen are used as they are:

| Component | By | Licence | Used for |
|---|---|---|---|
| [nvdiffrast-hip](https://github.com/Cardboard-box-a/nvdiffrast-hip) | NVIDIA; HIP port by Cardboard-box-a | NVIDIA Source Code Licence (1-Way Commercial) — **non-commercial use only** | Baking textures |
| [nvdiffrec renderutils](https://github.com/Cardboard-box-a/nvdiffrec) | NVIDIA; HIP port by Cardboard-box-a | NVIDIA Source Code Licence for nvdiffrec — **non-commercial use only** | Materials |
| [CuMesh](https://github.com/Cardboard-box-a/CuMesh) (with cubvh and xatlas, as above) | Jianfeng Xiang; HIP port by Cardboard-box-a | MIT; cubvh's NVIDIA code **non-commercial only** | Building and simplifying meshes |
| [FlexGEMM-rocm](https://github.com/Cardboard-box-a/FlexGEMM-rocm) | Jianfeng Xiang; HIP port by Cardboard-box-a | MIT | Sparse convolutions |
| [flash-attention](https://github.com/Dao-AILab/flash-attention) 2.8.3 (Triton backend) | Tri Dao et al. | BSD-3-Clause | Attention |
| PyTorch 2.11 for ROCm and the ROCm 7.13 SDK, from [AMD's package index](https://repo.amd.com/rocm/whl/) | Meta / AMD | BSD-3-Clause (PyTorch); ROCm components are open source, mostly MIT with some Apache-2.0 and NCSA ([list](https://rocm.docs.amd.com/en/latest/about/license.html)); each one's licence file comes inside the wheels | GPU runtime and the HIP compiler |

## The engine's toolchain

`omamesh-setup` builds a private environment with
[micromamba](https://github.com/mamba-org/micromamba-releases) (BSD-3-Clause)
from [conda-forge](https://conda-forge.org). The main pieces:

| Package | Licence |
|---|---|
| Python 3.11 | Python Software Foundation Licence |
| NVIDIA CUDA Toolkit 12.8 | NVIDIA CUDA Toolkit End User Licence Agreement |
| GCC 13 compilers and runtime | GPL-3.0 with the GCC Runtime Library Exception |
| CMake | BSD-3-Clause |
| Ninja | Apache-2.0 |
| Git | GPL-2.0-or-later and LGPL-2.1-or-later |
| libjpeg-turbo | IJG, BSD-3-Clause and Zlib |
| OpenSSL | Apache-2.0 |

They pull in further conda-forge libraries; after setup,
`~/.local/share/omamesh/engine/tools/bin/micromamba list -p ~/.local/share/omamesh/engine/env`
lists every one; each package's licence is recorded in the environment's
`conda-meta` folder and on its conda-forge page.

## Python packages

Installed by `omamesh-setup` from PyPI and the PyTorch package index, at the
versions pinned in `engine/requirements.lock`:

| Package | Version | Licence |
|---|---|---|
| absl-py | 2.5.0 | Apache-2.0 |
| aiofiles | 24.1.0 | Apache Software License |
| annotated-doc | 0.0.5 | MIT |
| annotated-types | 0.8.0 | MIT |
| anyio | 4.15.1 | MIT |
| brotli | 1.2.0 | MIT |
| certifi | 2026.7.22 | Mozilla Public License 2.0 (MPL 2.0) |
| charset-normalizer | 3.5.2 | MIT |
| click | 8.5.0 | BSD-3-Clause |
| cuda-bindings | 12.9.7 | NVIDIA proprietary |
| cuda-pathfinder | 1.6.0 | Apache-2.0 |
| cuda-toolkit | 12.8.1 | NVIDIA proprietary |
| easydict | 1.13 | GNU Lesser General Public License v3 (LGPLv3) |
| einops | 0.8.2 | MIT License |
| fastapi | 0.143.0 | MIT |
| ffmpy | 1.0.0 | MIT |
| filelock | 3.32.3 | MIT |
| fsspec | 2026.7.0 | BSD-3-Clause |
| glcontext | 3.1.0 | MIT License |
| gradio | 6.0.1 | Apache-2.0 |
| gradio_client | 2.0.0 | Apache-2.0 |
| groovy | 0.1.2 | MIT License |
| grpcio | 1.84.0 | Apache-2.0 |
| h11 | 0.16.0 | MIT License |
| hf-xet | 1.7.0 | Apache-2.0 |
| httpcore | 1.0.9 | BSD-3-Clause |
| httpx | 0.28.1 | BSD License |
| huggingface_hub | 0.36.2 | Apache Software License |
| idna | 3.20 | BSD-3-Clause |
| ImageIO | 2.38.1 | BSD-2-Clause |
| imageio-ffmpeg | 0.6.0 | BSD License |
| Jinja2 | 3.1.6 | BSD License |
| kornia | 0.8.3 | Apache Software License |
| kornia_rs | 0.2.0 | Apache Software License |
| lpips | 0.1.4 | BSD License |
| Markdown | 3.11 | BSD-3-Clause |
| markdown-it-py | 4.2.0 | MIT License |
| MarkupSafe | 3.0.3 | BSD-3-Clause |
| mdurl | 0.1.2 | MIT License |
| moderngl | 5.13.0 | MIT License |
| mpmath | 1.3.0 | BSD License |
| networkx | 3.6.1 | BSD-3-Clause |
| ninja | 1.13.2 | Apache-2.0 |
| numpy | 2.4.6 | BSD-3-Clause AND 0BSD AND MIT AND Zlib AND CC0-1.0 |
| nvidia-cublas-cu12 | 12.8.4.1 | NVIDIA proprietary |
| nvidia-cuda-cupti-cu12 | 12.8.90 | NVIDIA proprietary |
| nvidia-cuda-nvrtc-cu12 | 12.8.93 | NVIDIA proprietary |
| nvidia-cuda-runtime-cu12 | 12.8.90 | NVIDIA proprietary |
| nvidia-cudnn-cu12 | 9.19.0.56 | NVIDIA proprietary |
| nvidia-cufft-cu12 | 11.3.3.83 | NVIDIA proprietary |
| nvidia-cufile-cu12 | 1.13.1.3 | NVIDIA proprietary |
| nvidia-curand-cu12 | 10.3.9.90 | NVIDIA proprietary |
| nvidia-cusolver-cu12 | 11.7.3.90 | NVIDIA proprietary |
| nvidia-cusparse-cu12 | 12.5.8.93 | NVIDIA proprietary |
| nvidia-cusparselt-cu12 | 0.7.1 | NVIDIA proprietary |
| nvidia-nccl-cu12 | 2.28.9 | NVIDIA proprietary |
| nvidia-nvjitlink-cu12 | 12.8.93 | NVIDIA proprietary |
| nvidia-nvshmem-cu12 | 3.4.5 | NVIDIA proprietary |
| nvidia-nvtx-cu12 | 12.8.90 | NVIDIA proprietary |
| opencv-python-headless | 5.0.0.93 | Apache Software License |
| opentelemetry-api | 1.45.1 | Apache-2.0 |
| orjson | 3.13.0 | MPL-2.0 AND (Apache-2.0 OR MIT) |
| pandas | 2.3.3 | BSD License |
| pillow | 12.3.0 | MIT-CMU |
| plyfile | 1.1.5 | GNU General Public License v3 or later (GPLv3+) |
| protobuf | 7.36.2 | 3-Clause BSD License |
| pydantic | 2.12.4 | MIT |
| pydantic_core | 2.41.5 | MIT |
| pydub | 0.25.1 | MIT License |
| Pygments | 2.21.0 | BSD-2-Clause |
| python-dateutil | 2.9.0.post0 | BSD License; Apache Software License |
| python-multipart | 0.0.32 | Apache-2.0 |
| pytz | 2026.5 | MIT License |
| PyYAML | 6.0.3 | MIT License |
| regex | 2026.9.29 | Apache-2.0 AND CNRI-Python |
| requests | 2.34.2 | Apache Software License |
| rich | 15.0.0 | MIT License |
| safehttpx | 0.1.7 | MIT License |
| safetensors | 0.8.0 | Apache Software License |
| scipy | 1.17.1 | BSD License |
| semantic-version | 2.10.0 | BSD License |
| shellingham | 1.5.4 | ISC License (ISCL) |
| six | 1.17.0 | MIT License |
| starlette | 0.52.1 | BSD-3-Clause |
| sympy | 1.14.0 | BSD License |
| tensorboard | 2.21.0 | Apache Software License |
| tensorboard-data-server | 0.7.2 | Apache Software License |
| timm | 1.0.30 | Apache Software License |
| tokenizers | 0.22.2 | Apache Software License |
| tomlkit | 0.13.3 | MIT License |
| torch | 2.11.0+cu128 | BSD-3-Clause |
| torchvision | 0.26.0+cu128 | BSD |
| tqdm | 4.70.1 | MPL-2.0 AND MIT |
| transformers | 4.57.6 | Apache Software License |
| trimesh | 5.1.1 | MIT License |
| triton | 3.6.0 | MIT License |
| typer | 0.27.3 | MIT |
| typing-inspection | 0.4.4 | MIT |
| typing_extensions | 4.16.0 | PSF-2.0 |
| tzdata | 2026.5 | Apache-2.0 |
| urllib3 | 2.8.0 | MIT |
| utils3d | 0.0.2 | MIT License |
| uvicorn | 0.54.0 | BSD-3-Clause |
| Werkzeug | 3.1.9 | BSD-3-Clause |
| xformers | 0.0.35 | BSD License |
| zstandard | 0.25.0 | BSD-3-Clause |

## The desktop app

Installed by pacman from your distribution, not bundled:

| Component | Licence |
|---|---|
| [Qt 6](https://www.qt.io) (Base, Declarative, Image Formats) | LGPL-3.0 |
| [Qt Quick 3D](https://doc.qt.io/qt-6/qtquick3d-index.html) | GPL-3.0 |
| xdg-desktop-portal | LGPL-2.1-or-later |
| [Blender](https://www.blender.org) (optional; run as a separate program to export) | GPL-2.0-or-later |

Because the app uses Qt Quick 3D, the built `omamesh` program is distributed
under the terms of the GPL-3.0; its source, here, remains available under the
MIT licence, which is compatible with it.

The viewer's studio lighting (`src/studio.hdr`) is generated by Omamesh
itself, not taken from a third party.

The screenshot in the README shows models made from two of TRELLIS.2's own
example images (MIT).
