FROM dromni/nerfstudio:1.1.5

# Install curl (nerfstudio image already has ffmpeg, Python, COLMAP, gsplat)
USER root
RUN apt-get update && apt-get install -y --no-install-recommends curl && \
    rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

USER 1000
WORKDIR /workspace
ENTRYPOINT ["/bin/bash", "/entrypoint.sh"]