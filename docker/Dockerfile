FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV OSRM_VERSION=5.27.1

# ─── System packages ──────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    curl \
    git \
    jq \
    libboost-all-dev \
    libbz2-dev \
    libexpat1-dev \
    liblua5.4-dev \
    libstxxl-dev \
    libtbb-dev \
    libxml2-dev \
    libzip-dev \
    pkg-config \
    unzip \
    wget \
    ca-certificates \
    gnupg \
    lsb-release \
    software-properties-common \
    && rm -rf /var/lib/apt/lists/*

# ─── osmium-tool ──────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    osmium-tool \
    && rm -rf /var/lib/apt/lists/*

# ─── OSRM backend ────────────────────────────────────────────────
RUN git clone --branch v${OSRM_VERSION} --depth 1 \
      https://github.com/Project-OSRM/osrm-backend.git /tmp/osrm-backend \
    && mkdir /tmp/osrm-backend/build \
    && cd /tmp/osrm-backend/build \
    && cmake .. -DCMAKE_BUILD_TYPE=Release \
    && cmake --build . --target install -- -j$(nproc) \
    && cp -r /tmp/osrm-backend/profiles /opt/osrm-profiles \
    && rm -rf /tmp/osrm-backend

# ─── PostgreSQL 15 + PostGIS 3 ────────────────────────────────────
RUN sh -c 'echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
      > /etc/apt/sources.list.d/pgdg.list' \
    && curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
      | gpg --dearmor -o /etc/apt/trusted.gpg.d/postgresql.gpg \
    && apt-get update && apt-get install -y --no-install-recommends \
      postgresql-15 \
      postgresql-15-postgis-3 \
      postgresql-client-15 \
    && rm -rf /var/lib/apt/lists/*

# ─── AWS CLI v2 ───────────────────────────────────────────────────
RUN curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" \
      -o /tmp/awscli.zip \
    && unzip -q /tmp/awscli.zip -d /tmp \
    && /tmp/aws/install \
    && rm -rf /tmp/aws /tmp/awscli.zip

# ─── GitHub CLI ───────────────────────────────────────────────────
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] \
      https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# ─── pike-import ──────────────────────────────────────────────────
# TODO: pike-import is a Rust binary from the pike repo (tldev/pike).
# Once the build/release strategy is decided, replace this placeholder
# with one of:
#   COPY --from=pike-import-builder /app/pike-import /usr/local/bin/pike-import
#   RUN gh release download --repo tldev/pike -p 'pike-import-linux-amd64' -D /usr/local/bin && chmod +x /usr/local/bin/pike-import
# For now, scripts that call pike-import will fail with a clear error.
RUN echo '#!/bin/sh\necho "ERROR: pike-import binary not installed. See Dockerfile TODO." >&2\nexit 1' \
      > /usr/local/bin/pike-import \
    && chmod +x /usr/local/bin/pike-import

# ─── Scripts ──────────────────────────────────────────────────────
WORKDIR /app
COPY scripts/ /app/scripts/
RUN chmod +x /app/scripts/*.sh

ENTRYPOINT ["/bin/bash"]
