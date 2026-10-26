FROM postgres:17-bookworm

ARG TARGETARCH
ARG WALG_VERSION=v3.0.9
ARG WALG_SHA256_AMD64=d6795c663894d836ba20840bffe8970aed81bbe25d3151bd4951f6f9c362def9
ARG WALG_SHA256_ARM64=072eb4a4a119f817e1fa888c64a776b01e3453b2e0d967a67d149adb18fde652

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl tini; \
    case "${TARGETARCH:-amd64}" in \
      amd64) arch=amd64; sha="$WALG_SHA256_AMD64" ;; \
      arm64) arch=aarch64; sha="$WALG_SHA256_ARM64" ;; \
      *) echo "unsupported arch: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /usr/local/bin/wal-g \
      "https://github.com/wal-g/wal-g/releases/download/${WALG_VERSION}/wal-g-pg-22.04-${arch}"; \
    echo "${sha}  /usr/local/bin/wal-g" | sha256sum -c -; \
    chmod 0755 /usr/local/bin/wal-g; \
    apt-get purge -y --auto-remove curl; \
    rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY birdhaus.conf pg_hba.conf /etc/birdhaus/

ENV PGDATA=/var/lib/postgresql/data
EXPOSE 5432

# The container starts as root: the entrypoint prepares PGDATA and then runs
# every Postgres and WAL-G process as the postgres user.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
