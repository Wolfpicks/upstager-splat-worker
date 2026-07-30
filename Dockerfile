FROM nvidia/cuda:12.1.0-devel-ubuntu22.04

# COLMAP + system deps
RUN apt-get update && apt-get install -y --no-install-recommends \
    colmap ffmpeg curl wget \
    python3-pip python3-dev python3-venv \
    git build-essential ninja-build cmake \
    libgl1 libgl1-mesa-glx libglib2.0-0 \
    libsm6 libxext6 libxrender-dev \
    mesa-utils x11-utils xvfb \
    && rm -rf /var/lib/apt/lists/*

# CUDA env
ENV CUDA_HOME=/usr/local/cuda-12.1
ENV PATH=/usr/local/cuda-12.1/bin:$PATH
ENV TORCH_CUDA_ARCH_LIST="8.6"
ENV TORCHDYNAMO_DISABLE=1
ENV MAX_JOBS=4

# PyTorch (pinned)
RUN pip3 install --no-cache-dir \
    torch==2.3.1 torchvision==0.18.1 \
    --index-url https://download.pytorch.org/whl/cu121

# nerfstudio + gsplat (pinned)
RUN pip3 install --no-cache-dir \
    nerfstudio==1.1.5 gsplat==1.4.0

# Verify
RUN python3 -c "import torch, gsplat; assert torch.cuda.is_available(); print(f'torch={torch.__version__} gsplat={gsplat.__version__} CUDA OK')"

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

WORKDIR /workspace
ENTRYPOINT ["/bin/bash", "/entrypoint.sh"]