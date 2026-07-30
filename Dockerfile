FROM runpod/pytorch:2.2.0-py3.10-cuda12.1.1-devel-ubuntu22.04
ENV TORCH_CUDA_ARCH_LIST="8.6"
RUN apt-get update && apt-get install -y --no-install-recommends \
    colmap ffmpeg curl libgl1 libglib2.0-0 libsm6 libxext6 libxrender-dev \
    xvfb mesa-utils x11-utils \
    && rm -rf /var/lib/apt/lists/*
# Upgrade torch to 2.3.1 via pip, then remove conda's old torch
RUN pip install --no-cache-dir torch==2.3.1 torchvision==0.18.1 --index-url https://download.pytorch.org/whl/cu121
RUN rm -rf /opt/conda/lib/python3.10/site-packages/torch /opt/conda/lib/python3.10/site-packages/torch-*
RUN pip install --no-cache-dir --ignore-installed blinker nerfstudio gsplat typing-extensions
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
WORKDIR /workspace
ENTRYPOINT ["/bin/bash", "/entrypoint.sh"]