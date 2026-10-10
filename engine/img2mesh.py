"""img2mesh: turn a single image into a textured 3D model (.glb) with TRELLIS.2.

Run through the `img2mesh` launcher, which sets up the environment.

`img2mesh --serve` keeps the models loaded and takes jobs as JSON lines on
stdin, answering with JSON lines on stdout (this is what the omamesh app uses):

  in:  {"cmd": "generate", "id": "1", "image": "/abs/photo.jpg", "out": "/abs/dir",
        "quality": "standard", "seed": 42, "faces": 500000, "texture": 2048}
       {"cmd": "cancel", "id": "1"}
       {"cmd": "quit"}
  out: {"event": "loading"} {"event": "ready"}
       {"event": "progress", "id": "1", "stage": "Texture", "step": 3, "total": 12}
       {"event": "done", "id": "1", "glb": "/abs/dir/photo.glb", "seconds": 41.2, "vram": 9.8}
       {"event": "error", "id": "1", "message": "..."}  {"event": "cancelled", "id": "1"}
       {"event": "fatal", "message": "..."}
"""
import argparse
import contextlib
import json
import os
import queue
import sys
import threading
import time
import traceback
from pathlib import Path

# Code and data can live apart (see bin/img2mesh): the TRELLIS.2 source, the
# models folder and the environment sit in IMG2MESH_HOME.
ROOT = Path(os.environ.get("IMG2MESH_HOME") or Path(__file__).resolve().parent)
TRELLIS = ROOT / "TRELLIS.2"
# Which GPU the engine was set up for: "cuda" (NVIDIA) or "rocm" (AMD). Written
# by install.sh; engines set up before AMD support have no file and are CUDA.
_accel = ROOT / "accelerator"
ACCELERATOR = _accel.read_text().strip() if _accel.exists() else "cuda"

os.environ.setdefault("OPENCV_IO_ENABLE_OPENEXR", "1")
if ACCELERATOR == "rocm":
    # No xformers on ROCm; flash-attn runs through its Triton backend instead.
    os.environ.setdefault("ATTN_BACKEND", "flash_attn")
    os.environ.setdefault("FLASH_ATTENTION_TRITON_AMD_ENABLE", "TRUE")
    os.environ.setdefault("TORCH_ROCM_AOTRITON_ENABLE_EXPERIMENTAL", "1")
    # expandable_segments stays off: with it, emptying torch's cache doesn't
    # hand memory back to HIP, so CuMesh (which allocates outside torch) runs
    # out while building the mesh.
else:
    os.environ.setdefault("PYTORCH_CUDA_ALLOC_CONF", "expandable_segments:True")
    os.environ.setdefault("ATTN_BACKEND", "xformers")
MODEL_REPO = "microsoft/TRELLIS.2-4B"
# RMBG-2.0 (the upstream default) is gated and non-commercial; BiRefNet is MIT.
REMBG_MODEL = "ZhengPeng7/BiRefNet"
# Everything the pipeline loads, for --download: (repo, files or None for all).
WEIGHTS = [
    (MODEL_REPO, None),
    ("microsoft/TRELLIS-image-large", ["ckpts/ss_dec_conv3d_16l8_fp16.*"]),
    (REMBG_MODEL, None),
    ("facebook/dinov3-vitl16-pretrain-lvd1689m", None),  # gated: accept Meta's licence
]

QUALITY = {"draft": "512", "standard": "1024_cascade", "high": "1536_cascade"}
# The models each quality samples with. Anything else stays on disk: holding
# all eight in RAM (~16 GB) is what pushed a 30 GB machine into swap.
_CASCADE = ["sparse_structure_flow_model", "sparse_structure_decoder",
            "shape_slat_flow_model_512", "shape_slat_flow_model_1024", "shape_slat_decoder",
            "tex_slat_flow_model_1024", "tex_slat_decoder"]
MODELS = {
    "draft": ["sparse_structure_flow_model", "sparse_structure_decoder",
              "shape_slat_flow_model_512", "shape_slat_decoder",
              "tex_slat_flow_model_512", "tex_slat_decoder"],
    "standard": _CASCADE,
    "high": _CASCADE,
}
# VRAM left free for each quality's working memory; models are kept on the GPU
# only while they fit beside it, the rest wait in RAM between stages.
HEADROOM_GB = {"draft": 2.0, "standard": 3.5, "high": 4.5}
# Under ROCm, MIOpen's convolutions give the background remover (BiRefNet)
# 3.9 GB of working memory at its 1024x1024 input, so every quality leaves
# at least this much free there.
ROCM_MIN_HEADROOM_GB = 4.5
# Decoding and mesh building need more than that headroom, more so if something
# else is using the GPU. The samplers are finished by then, so they are dropped
# (the next job reads them back from disk in a few seconds); at 1024+, or when
# the GPU is short, the rest wait in RAM while CuMesh works.
PARK_BEFORE_MESH = {"standard", "high"}
MESH_FREE_GB = 5.0
# High's 1536 shape decoder doesn't fit beside ROCm's allocator on a 16 GB
# Radeon (its biggest layer wants one 3.2 GB block that fragmentation never
# leaves free); 24 GB cards have room to spare.
ROCM_HIGH_MIN_VRAM_GB = 20
STAGES = {
    "Sampling sparse structure": "Shape layout",
    "Sampling shape SLat": "Shape detail",
    "Sampling texture SLat": "Texture",
}


class Cancelled(Exception):
    pass


class QualityUnavailable(Exception):
    pass


def headroom_gb(quality):
    if ACCELERATOR == "rocm":
        return max(HEADROOM_GB[quality], ROCM_MIN_HEADROOM_GB)
    return HEADROOM_GB[quality]


def unavailable(quality):
    """Why this GPU can't make `quality`, or None if it can."""
    import torch

    if ACCELERATOR != "rocm" or quality != "high":
        return None
    vram_gb = torch.cuda.mem_get_info()[1] / 2**30
    if vram_gb >= ROCM_HIGH_MIN_VRAM_GB:
        return None
    return (f"High quality needs a Radeon with {ROCM_HIGH_MIN_VRAM_GB} GB or more of video "
            f"memory; this one has {vram_gb:.0f} GB. Standard works on it.")


def local_model_dir() -> Path:
    """A model folder whose pipeline.json uses the ungated background remover."""
    from huggingface_hub import snapshot_download

    snapshot = Path(snapshot_download(MODEL_REPO))
    target = ROOT / "models" / "TRELLIS.2-4B"
    target.mkdir(parents=True, exist_ok=True)
    ckpts = target / "ckpts"
    if not ckpts.exists():
        ckpts.symlink_to(snapshot / "ckpts")
    config = json.loads((snapshot / "pipeline.json").read_text())
    config["args"]["rembg_model"]["args"]["model_name"] = REMBG_MODEL
    (target / "pipeline.json").write_text(json.dumps(config, indent=4))
    return target


def load_pipeline(on_step, quality):
    """Load TRELLIS.2 and route its sampler progress through on_step(stage, step, total)."""
    sys.path.insert(0, str(TRELLIS))
    from trellis2.pipelines import Trellis2ImageTo3DPipeline
    from trellis2.pipelines.samplers import flow_euler

    def reporting_tqdm(items, desc="", disable=False, **_):
        items = list(items)
        stage = STAGES.get(desc, desc)
        for step, item in enumerate(items):
            on_step(stage, step, len(items))
            yield item
        on_step(stage, len(items), len(items))

    flow_euler.tqdm = reporting_tqdm
    model_dir = local_model_dir()
    # Load just the samplers and helpers here; use_quality() brings in the models.
    Trellis2ImageTo3DPipeline.model_names_to_load = []
    pipeline = Trellis2ImageTo3DPipeline.from_pretrained(str(model_dir))
    pipeline.low_vram = True  # per model: pinned ones never leave the GPU
    pipeline.cuda()
    pipeline.model_dir = model_dir
    pipeline.quality = None

    decode_latent = pipeline.decode_latent

    def reporting_decode(*args, **kwargs):
        on_step("Decoding", 0, 0)
        _drop_samplers(pipeline)
        return decode_latent(*args, **kwargs)

    pipeline.decode_latent = reporting_decode

    # Hole filling runs inside decode_latent, in CuMesh, which allocates outside
    # PyTorch: as for mesh building, hand it what the decoders and torch's cache
    # hold when the GPU is short.
    from trellis2.representations.mesh.base import Mesh
    fill_holes = Mesh.fill_holes

    def roomy_fill_holes(self, *args, **kwargs):
        import torch
        if torch.cuda.mem_get_info()[0] < MESH_FREE_GB * 2**30:
            _park(pipeline)
        torch.cuda.empty_cache()
        return fill_holes(self, *args, **kwargs)

    Mesh.fill_holes = roomy_fill_holes
    # A saved quality this GPU can't make still starts the engine; jobs at that
    # quality are refused one by one (see generate).
    use_quality(pipeline, "standard" if unavailable(quality) else quality)
    return pipeline


def _pin(model):
    """Keep a model on the GPU: the pipeline's offloading calls .cpu() on it after each use."""
    model.cuda()
    model.cpu = lambda *_, **__: model


def _unpin(model):
    model.__dict__.pop("cpu", None)
    model.cpu()


def _pinned(model):
    return "cpu" in model.__dict__


def _module(model):
    return getattr(model, "model", model)  # the background/feature wrappers hold .model


def _size_bytes(model):
    return sum(p.numel() * p.element_size() for p in _module(model).parameters())


@contextlib.contextmanager
def _no_init():
    """Skip torch's weight initialisers: the checkpoint overwrites every weight,
    and filling a 1.3B model with random numbers on the CPU takes ~8 s."""
    import torch

    names = ["uniform_", "normal_", "trunc_normal_", "constant_", "zeros_", "ones_",
             "xavier_uniform_", "xavier_normal_", "kaiming_uniform_", "kaiming_normal_"]
    saved = {n: getattr(torch.nn.init, n) for n in names}
    for n in names:
        setattr(torch.nn.init, n, lambda tensor, *_, **__: tensor)
    try:
        yield
    finally:
        for n, fn in saved.items():
            setattr(torch.nn.init, n, fn)


def _weights(source):
    """(config.json, model.safetensors) for a local path or an HF 'repo/name/path'."""
    if Path(f"{source}.json").exists():
        return Path(f"{source}.json"), Path(f"{source}.safetensors")
    from huggingface_hub import hf_hub_download

    repo, name = "/".join(source.split("/")[:2]), "/".join(source.split("/")[2:])
    return (Path(hf_hub_download(repo, f"{name}.json")),
            Path(hf_hub_download(repo, f"{name}.safetensors")))


def _load_model(config_file, weights_file, device):
    """trellis2.models.from_pretrained, built empty on `device` and filled from disk."""
    import torch
    from safetensors.torch import load_file
    from trellis2 import models

    config = json.loads(config_file.read_text())
    with _no_init(), torch.device(device):
        model = getattr(models, config["name"])(**config["args"])
    # Copying (not assigning) keeps each parameter in the dtype the model chose.
    missing, _ = model.load_state_dict(load_file(weights_file), strict=False)
    buffers = {name for name, _ in model.named_buffers()}  # computed when built, e.g. rope_phases
    missing = [name for name in missing if name not in buffers]
    if missing:
        print(f"img2mesh: {config_file.stem} has no weights for {len(missing)} tensors, "
              f"e.g. {missing[0]}", file=sys.stderr)
    return model.eval()


def _trim_ram():
    """Hand freed heap back to the system; glibc otherwise keeps it after big loads."""
    import ctypes
    import gc

    gc.collect()
    try:
        ctypes.CDLL("libc.so.6").malloc_trim(0)
    except OSError:
        pass


def use_quality(pipeline, quality):
    """Hold exactly the models `quality` needs, on the GPU as far as they fit.

    Models are pinned one at a time as they load, so RAM never holds the set.
    """
    if pipeline.quality == quality:
        return
    import gc
    import torch

    wanted = MODELS[quality]
    for name in [n for n in pipeline.models if n not in wanted]:
        del pipeline.models[name]
    gc.collect()
    torch.cuda.empty_cache()

    helpers = [pipeline.image_cond_model, pipeline.rembg_model]
    kept = [m for m in [*pipeline.models.values(), *helpers] if _pinned(m)]
    budget = (torch.cuda.mem_get_info()[0] + sum(map(_size_bytes, kept))
              - headroom_gb(quality) * 2**30)
    paths = pipeline._pretrained_args["models"]
    for name in [*wanted, None, None]:
        if name is None:
            model = helpers.pop(0)
        elif name in pipeline.models:
            model = pipeline.models[name]
        else:
            local = pipeline.model_dir / paths[name]
            config, weights = _weights(str(local) if Path(f"{local}.json").exists() else paths[name])
            # The file size is the model's size: build it where it will live.
            device = "cuda" if weights.stat().st_size <= budget else "cpu"
            model = pipeline.models[name] = _load_model(config, weights, device)
        size = _size_bytes(model)
        if size <= budget:
            if not _pinned(model):
                _pin(model)
            budget -= size
        elif _pinned(model):
            _unpin(model)
        elif next(_module(model).parameters()).is_cuda:
            model.cpu()  # built on the GPU but no longer fits beside the others
    pipeline.quality = quality
    _trim_ram()


def _drop_samplers(pipeline):
    import gc
    import torch

    for name in [n for n in pipeline.models if "flow_model" in n]:
        del pipeline.models[name]
    pipeline.quality = None  # the next job's use_quality() loads them again
    gc.collect()
    torch.cuda.empty_cache()
    _trim_ram()


def _park(pipeline):
    for model in [*pipeline.models.values(), pipeline.image_cond_model, pipeline.rembg_model]:
        if _pinned(model):
            _unpin(model)
    pipeline.quality = None


def resident(pipeline):
    """Where the models are, for logs: (GB pinned on the GPU, GB waiting in RAM)."""
    everything = [*pipeline.models.values(), pipeline.image_cond_model, pipeline.rembg_model]
    on_gpu = sum(_size_bytes(m) for m in everything if _pinned(m))
    return on_gpu / 2**30, (sum(map(_size_bytes, everything)) - on_gpu) / 2**30


# Separate bits of the cut-out smaller than this share of the main object are
# specks (dust, spray, stray pixels); left in, each becomes a floating fragment.
SPECK_SHARE = 0.01


def cut_out(pipeline, image):
    """The photo as RGBA with its background removed, minus any specks."""
    import numpy as np
    from PIL import Image
    from scipy import ndimage

    if image.mode != "RGBA" or image.getextrema()[3][0] == 255:
        # The same steps as the pipeline's own preprocess_image.
        image = image.convert("RGB")
        scale = min(1, 1024 / max(image.size))
        if scale < 1:
            image = image.resize((int(image.width * scale), int(image.height * scale)),
                                 Image.Resampling.LANCZOS)
        pipeline.rembg_model.to(pipeline.device)
        image = pipeline.rembg_model(image)
        pipeline.rembg_model.cpu()  # a no-op while pinned

    rgba = np.array(image.convert("RGBA"))
    labels, count = ndimage.label(rgba[..., 3] > 0, structure=np.ones((3, 3)))
    if count > 1:
        sizes = np.bincount(labels.ravel())
        sizes[0] = 0
        keep = sizes >= sizes.max() * SPECK_SHARE
        rgba[..., 3][~keep[labels]] = 0
    return Image.fromarray(rgba)


def generate(pipeline, image_path: Path, out_dir: Path, quality="standard", seed=42,
             faces=500_000, texture=2048, keep_background=False, video=False,
             on_stage=lambda stage: None):
    """Run one image through the pipeline; returns (glb_path, seconds, peak_vram_gb)."""
    import torch
    from PIL import Image
    import o_voxel

    reason = unavailable(quality)
    if reason:
        raise QualityUnavailable(reason)
    if pipeline.quality != quality:
        on_stage("Loading models")
        use_quality(pipeline, quality)
    out_dir.mkdir(parents=True, exist_ok=True)
    stem = image_path.stem if seed == 42 else f"{image_path.stem}-seed{seed}"
    glb_path = out_dir / f"{stem}.glb"

    start = time.time()
    torch.cuda.reset_peak_memory_stats()
    image = Image.open(image_path)
    if not keep_background:
        on_stage("Removing background")
        # With transparency present, preprocess_image only crops and centres.
        image = pipeline.preprocess_image(cut_out(pipeline, image))
    mesh = pipeline.run(image, seed=seed, pipeline_type=QUALITY[quality],
                        preprocess_image=False)[0]
    mesh.simplify(16_777_216)  # nvdiffrast limit

    if video:
        on_stage("Rendering turntable")
        import cv2
        import imageio
        from trellis2.renderers import EnvMap
        from trellis2.utils import render_utils

        hdri = cv2.imread(str(TRELLIS / "assets/hdri/forest.exr"), cv2.IMREAD_UNCHANGED)
        envmap = EnvMap(torch.tensor(cv2.cvtColor(hdri, cv2.COLOR_BGR2RGB),
                                     dtype=torch.float32, device="cuda"))
        frames = render_utils.make_pbr_vis_frames(render_utils.render_video(mesh, envmap=envmap))
        imageio.mimsave(out_dir / f"{stem}.mp4", frames, fps=15)

    on_stage("Building mesh")
    if quality in PARK_BEFORE_MESH or torch.cuda.mem_get_info()[0] < MESH_FREE_GB * 2**30:
        _park(pipeline)
    # CuMesh allocates outside PyTorch, so hand back what torch has cached.
    torch.cuda.empty_cache()
    glb =o_voxel.postprocess.to_glb(
        vertices=mesh.vertices,
        faces=mesh.faces,
        attr_volume=mesh.attrs,
        coords=mesh.coords,
        attr_layout=mesh.layout,
        voxel_size=mesh.voxel_size,
        aabb=[[-0.5, -0.5, -0.5], [0.5, 0.5, 0.5]],
        decimation_target=faces,
        texture_size=texture,
        remesh=True,
        remesh_band=1,
        remesh_project=0,
        verbose=False,
    )
    # PNG textures: WebP (EXT_texture_webp) is not readable by every viewer.
    glb.export(glb_path)
    del mesh, glb
    torch.cuda.empty_cache()
    return glb_path, time.time() - start, torch.cuda.max_memory_allocated() / 2**30


def download():
    """Fetch every model into the Hugging Face cache; safe to re-run, it resumes."""
    from huggingface_hub import snapshot_download

    os.environ.setdefault("HF_HUB_DISABLE_XET", "1")  # Xet stalls on big files
    for repo, patterns in WEIGHTS:
        print(f"Downloading {repo}…", flush=True)
        snapshot_download(repo, allow_patterns=patterns)
    print("All models downloaded.", flush=True)


def serve(quality):
    # Libraries print freely to stdout; keep the real stdout for protocol lines only.
    proto = os.fdopen(os.dup(1), "w", buffering=1)
    os.dup2(2, 1)
    sys.stdout = sys.stderr
    lock = threading.Lock()

    def emit(event, **fields):
        with lock:
            proto.write(json.dumps({"event": event, **fields}) + "\n")

    jobs = queue.Queue()
    cancelled = set()

    def read_commands():
        for line in sys.stdin:
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                continue
            if msg.get("cmd") == "cancel":
                cancelled.add(str(msg.get("id")))
            else:
                jobs.put(msg)
        # stdin closed: the app quit or died. Don't finish the current job and
        # hold the GPU for nobody.
        proto.flush()
        os._exit(0)

    threading.Thread(target=read_commands, daemon=True).start()
    current = {"id": None}

    def on_step(stage, step, total):
        job_id = current["id"]
        if job_id in cancelled:
            raise Cancelled()
        emit("progress", id=job_id, stage=stage, step=step, total=total)

    emit("loading")
    try:
        pipeline = load_pipeline(on_step, quality)
    except Exception as e:
        traceback.print_exc()
        emit("fatal", message=f"{type(e).__name__}: {e}")
        return 1
    emit("ready")

    while True:
        msg = jobs.get()
        if msg.get("cmd") == "quit":
            return 0
        if msg.get("cmd") != "generate":
            continue
        job_id = str(msg.get("id"))
        if job_id in cancelled:
            emit("cancelled", id=job_id)
            continue
        current["id"] = job_id
        try:
            image = Path(msg["image"])
            glb, seconds, vram = generate(
                pipeline, image, Path(msg.get("out") or image.parent),
                quality=msg.get("quality", "standard"), seed=int(msg.get("seed", 42)),
                faces=int(msg.get("faces", 500_000)), texture=int(msg.get("texture", 2048)),
                on_stage=lambda stage: on_step(stage, 0, 0),
            )
            emit("done", id=job_id, glb=str(glb), seconds=round(seconds, 1), vram=round(vram, 1))
        except Cancelled:
            emit("cancelled", id=job_id)
        except QualityUnavailable as e:
            emit("error", id=job_id, message=str(e))
        except Exception as e:
            traceback.print_exc()
            emit("error", id=job_id, message=f"{type(e).__name__}: {e}")
        finally:
            current["id"] = None
            cancelled.discard(job_id)
            import torch
            torch.cuda.empty_cache()
            _trim_ram()


def parse_args():
    p = argparse.ArgumentParser(
        prog="img2mesh",
        description="Turn photos into textured 3D models (.glb) locally with TRELLIS.2.",
    )
    p.add_argument("images", nargs="*", type=Path, help="input image(s): jpg, png, webp")
    p.add_argument("-o", "--out", type=Path, help="output folder (default: next to each image)")
    p.add_argument("-q", "--quality", choices=QUALITY, default="standard",
                   help="draft = 512 (fast), standard = 1024, high = 1536 (slow, most VRAM)")
    p.add_argument("-s", "--seed", type=int, default=42, help="change for a different take")
    p.add_argument("--faces", type=int, default=500_000, help="target face count of the mesh")
    p.add_argument("--texture", type=int, default=2048, choices=[1024, 2048, 4096],
                   help="texture size in pixels")
    p.add_argument("--video", action="store_true", help="also render a turntable .mp4")
    p.add_argument("--keep-background", action="store_true",
                   help="skip background removal (image already has transparency)")
    p.add_argument("--download", action="store_true",
                   help="download the models (~17 GB) and exit")
    p.add_argument("--serve", action="store_true",
                   help="keep models loaded and take JSON jobs on stdin (for apps)")
    return p.parse_args()


def main():
    args = parse_args()
    if args.download:
        return download()
    if args.serve:
        sys.exit(serve(args.quality))
    if not args.images:
        sys.exit("img2mesh: give at least one image (or --serve)")
    missing = [str(i) for i in args.images if not i.is_file()]
    if missing:
        sys.exit(f"img2mesh: not found: {', '.join(missing)}")
    reason = unavailable(args.quality)
    if reason:
        sys.exit(f"img2mesh: {reason}")

    started = time.time()

    def on_step(stage, step, total):
        clock = f"[{time.time() - started:5.0f}s]"
        if total:
            print(f"\r  {clock} {stage}: {step}/{total}", end="", flush=True)
        else:
            print(f"\n  {clock} {stage}…", end="", flush=True)

    print("Loading models…", flush=True)
    pipeline = load_pipeline(on_step, args.quality)
    gpu, ram = resident(pipeline)
    print(f"  models: {gpu:.1f} GB kept on the GPU, {ram:.1f} GB in RAM, "
          f"loaded in {time.time() - started:.0f}s", flush=True)
    for image_path in args.images:
        out_dir = args.out or image_path.parent
        print(f"\n{image_path.name} → {out_dir}  ({args.quality})", flush=True)
        glb, seconds, vram = generate(
            pipeline, image_path, out_dir, args.quality, args.seed, args.faces,
            args.texture, args.keep_background, args.video,
            on_stage=lambda stage: on_step(stage, 0, 0),
        )
        print(f"\n  wrote {glb} in {seconds:.0f}s, peak VRAM {vram:.1f} GB", flush=True)


if __name__ == "__main__":
    main()
