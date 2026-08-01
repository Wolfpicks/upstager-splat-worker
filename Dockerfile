FROM nvidia/cuda:12.1.0-devel-ubuntu22.04

# COLMAP + system deps (includes GLX support for headless GPU SIFT)
RUN apt-get update && apt-get install -y --no-install-recommends \
    colmap ffmpeg curl wget \
    python3-pip python3-dev python3-venv \
    git build-essential ninja-build cmake \
    libgl1 libgl1-mesa-glx libegl1-mesa libglib2.0-0 \
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

# nerfstudio + gsplat + pipeline deps (pinned where critical)
RUN pip3 install --no-cache-dir \
    nerfstudio==1.1.5 gsplat==1.4.0 \
    opencv-python-headless \
    scikit-image \
    plyfile \
    boto3

# Verify imports (CUDA not available at build time — tested at runtime on GPU)
RUN python3 -c "import torch; print(f'torch={torch.__version__}')" && \
    python3 -c "import gsplat; print(f'gsplat={gsplat.__version__}')" && \
    python3 -c "import cv2; print(f'cv2={cv2.__version__}')" && \
    python3 -c "import skimage; print('skimage OK')" && \
    python3 -c "import plyfile; print('plyfile OK')"

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Stage-local Python scripts (sharp-frame, cleanup, QC)
COPY pipeline_scripts/ /app/pipeline_scripts/

WORKDIR /workspace
ENTRYPOINT ["/bin/bash", "/entrypoint.sh"]