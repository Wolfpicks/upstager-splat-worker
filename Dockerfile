FROM runpod/pytorch:2.2.0-py3.10-cuda12.1.1-devel-ubuntu22.04
ENV TORCH_CUDA_ARCH_LIST="8.6"
RUN apt-get update && apt-get install -y --no-install-recommends \
    colmap ffmpeg curl libgl1 libglib2.0-0 libsm6 libxext6 libxrender-dev \
    xvfb mesa-utils x11-utils \
    && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir --ignore-installed blinker nerfstudio==1.1.4 gsplat==1.2.0 typing-extensions
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
WORKDIR /workspace
ENTRYPOINT ["/bin/bash", "/entrypoint.sh"]