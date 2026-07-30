FROM runpod/pytorch:2.4.0-py3.11-cuda12.4.1-devel-ubuntu22.04
RUN apt-get update && apt-get install -y --no-install-recommends \
    colmap ffmpeg curl libgl1 libglib2.0-0 libsm6 libxext6 libxrender-dev \
    xvfb mesa-utils x11-utils x11-utils \
    && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir --ignore-installed blinker nerfstudio gsplat typing-extensions
COPY entrypoint.sh /entrypoint.sh
# Pre-compile gsplat CUDA extensions to avoid OOM during training
RUN python3 -c "import gsplat; gsplat.cuda._check_env()" 2>/dev/null || python3 -c "from gsplat.cuda._backend import _C" 2>/dev/null || python3 -c "__import__("gsplat")" 2>/dev/null || true
RUN chmod +x /entrypoint.sh
WORKDIR /workspace
ENTRYPOINT ["/bin/bash", "/entrypoint.sh"]
