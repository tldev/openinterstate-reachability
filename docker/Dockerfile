##
## Stage 1: Build pike-score from source
##
FROM rust:1.87-bookworm AS pike-score-builder

WORKDIR /build
COPY Cargo.toml Cargo.lock ./
RUN mkdir src && echo 'fn main() {}' > src/main.rs \
    && cargo build --release \
    && rm -rf src
COPY src/ src/
RUN cargo build --release --bin pike-score \
    && strip target/release/pike-score

##
## Stage 2: Build OSRM from source
##
FROM ubuntu:22.04 AS osrm-builder

ENV DEBIAN_FRONTEND=noninteractive
ENV OSRM_VERSION=5.27.1

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    git \
    libboost-all-dev \
    libbz2-dev \
    libexpat1-dev \
    liblua5.4-dev \
    libstxxl-dev \
    libtbb-dev \
    libxml2-dev \
    libzip-dev \
    pkg-config \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN git clone --branch v${OSRM_VERSION} --depth 1 \
      https://github.com/Project-OSRM/osrm-backend.git /tmp/osrm-backend \
    && mkdir /tmp/osrm-backend/build \
    && cd /tmp/osrm-backend/build \
    && cmake .. -DCMAKE_BUILD_TYPE=Release \
    && cmake --build . --target install -- -j$(nproc) \
    && cp -r /tmp/osrm-backend/profiles /opt/osrm-profiles \
    && rm -rf /tmp/osrm-backend

##
## Stage 3: Runtime image
##
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV OSRM_PROFILES=/opt/osrm-profiles

# ─── OSRM binaries + profiles from builder ────────────────────────
COPY --from=osrm-builder /usr/local/bin/osrm-* /usr/local/bin/
COPY --from=osrm-builder /usr/local/lib/libosrm* /usr/local/lib/
COPY --from=osrm-builder /opt/osrm-profiles /opt/osrm-profiles
RUN ldconfig

# ─── System packages + osmium-tool ───────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    gnupg \
    jq \
    libbz2-1.0 \
    libboost-filesystem1.74.0 \
    libboost-iostreams1.74.0 \
    libboost-program-options1.74.0 \
    libboost-thread1.74.0 \
    libexpat1 \
    liblua5.4-0 \
    libstxxl1v5 \
    libtbb12 \
    libxml2 \
    libzip4 \
    lsb-release \
    osmium-tool \
    software-properties-common \
    unzip \
    wget \
    && rm -rf /var/lib/apt/lists/*

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

# Initialize PostgreSQL cluster so scripts can just start the server
RUN pg_lsclusters | grep -q "15  main" \
    || pg_createcluster 15 main \
    && sed -i "s/#listen_addresses = 'localhost'/listen_addresses = 'localhost'/" \
      /etc/postgresql/15/main/postgresql.conf

# ─── AWS CLI v2 ───────────────────────────────────────────────────
# TODO: Hardcoded x86_64. For ARM/Graviton builds, detect arch and
# use the appropriate URL (aarch64 variant).
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

# ─── pike-score binary ────────────────────────────────────────────
COPY --from=pike-score-builder /build/target/release/pike-score /usr/local/bin/pike-score

# ─── Scripts ──────────────────────────────────────────────────────
WORKDIR /app
COPY scripts/ /app/scripts/
RUN chmod +x /app/scripts/*.sh 2>/dev/null || true

ENTRYPOINT ["/bin/bash"]
