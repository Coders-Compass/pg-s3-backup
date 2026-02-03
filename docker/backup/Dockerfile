FROM alpine:3.21

# Install PostgreSQL client and dependencies
# PostgreSQL 18 client is available in Alpine edge
# Versions are not pinned to allow Dependabot Alpine upgrades
# hadolint ignore=DL3018
RUN echo "https://dl-cdn.alpinelinux.org/alpine/edge/main" >> /etc/apk/repositories && \
    apk add --no-cache \
    postgresql18-client \
    curl \
    bash \
    gzip

# Install MinIO client (mc) - detect architecture
RUN ARCH=$(uname -m) && \
    case "$ARCH" in \
    x86_64) MC_ARCH="amd64" ;; \
    aarch64) MC_ARCH="arm64" ;; \
    *) echo "Unsupported architecture: $ARCH" && exit 1 ;; \
    esac && \
    curl -sSL "https://dl.min.io/client/mc/release/linux-${MC_ARCH}/mc" -o /usr/local/bin/mc && \
    chmod +x /usr/local/bin/mc

# Copy scripts
COPY scripts/ /scripts/
RUN chmod +x /scripts/*.sh

# Keep container running for scheduled jobs
CMD ["tail", "-f", "/dev/null"]
