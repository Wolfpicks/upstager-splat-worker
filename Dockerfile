# Bootstrap image: tiny (~600MB compressed) — pulls fast from Docker Hub
# All heavy lifting is done at pod startup via entrypoint.sh
FROM nvidia/cuda:12.1.0-runtime-ubuntu22.04

# Minimal additions: just curl for downloading files
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

WORKDIR /workspace
ENTRYPOINT ["/bin/bash", "/entrypoint.sh"]
