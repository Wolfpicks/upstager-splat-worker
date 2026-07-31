FROM nvidia/cuda:12.1.0-devel-ubuntu22.04

# COLMAP + system deps (includes GLX support for headless GPU SIFT)
# GLOMAP deps: need cmake ≥3.28 for FetchContent auto-build of COLMAP + PoseLib
RUN apt-get update && apt-get install -y --no-install-recommends \
    colmap ffmpeg curl wget \
    python3-pip python3-dev python3-venv \
    git build-essential ninja-build \
    libgl1 libgl1-mesa-glx libegl1-mesa libglib2.0-0 \
    libsm6 libxext6 libxrender-dev \
    mesa-utils x11-utils xvfb \
    libboost-filesystem-dev libboost-program-options-dev libboost-graph-dev \
    libceres-dev libeigen3-dev libfreeimage-dev \
    && rm -rf /var/lib/apt/lists/*

# cmake ≥3.28 required for GLOMAP FetchContent (Ubuntu 22.04 ships 3.22)
RUN wget -q https://github.com/Kitware/CMake/releases/download/v3.30.1/cmake-3.30.1.tar.gz && \
    tar xf cmake-3.30.1.tar.gz && cd cmake-3.30.1 && \
    ./bootstrap --parallel=$(nproc) && make -j$(nproc) && make install && \
    cd .. && rm -rf cmake-3.30.1*

# GLOMAP — global SfM mapper (10-50x faster than COLMAP incremental, robust on low-texture indoors)
# Builds as standalone binary; FetchContent auto-downloads COLMAP + PoseLib at cmake time
RUN git clone --depth 1 https://github.com/colmap/glomap.git /opt/glomap && \
    cmake -S /opt/glomap -B /opt/glomap/build -GNinja -DCMAKE_BUILD_TYPE=Release && \
    ninja -C /opt/glomap/build && ninja -C /opt/glomap/build install && \
    rm -rf /opt/glomap

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

# nerfstudio + gsplat + pipeline deps (pinned)
RUN pip3 install --no-cache-dir \
    nerfstudio==1.1.5 gsplat==1.4.0 \
    opencv-python-headless==4.9.0.80 \
    scikit-image==0.23.2 \
    plyfile==1.0.3 \
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