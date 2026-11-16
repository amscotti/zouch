FROM debian:bookworm-slim AS build
ARG ZIG_VERSION=0.17.0
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl xz-utils \
    && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" \
      -o /tmp/zig.tar.xz \
    && tar -C /opt -xf /tmp/zig.tar.xz \
    && ln -s "/opt/zig-x86_64-linux-${ZIG_VERSION}/zig" /usr/local/bin/zig \
    && rm /tmp/zig.tar.xz

WORKDIR /src
COPY . .
RUN zig build -Doptimize=ReleaseSafe

FROM debian:bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl libicu72 \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --uid 10001 --home /var/lib/zouch --shell /usr/sbin/nologin zouch \
    && install -d -o zouch -g zouch /var/lib/zouch
COPY --from=build /src/zig-out/bin/zouch /usr/local/bin/zouch
USER zouch
VOLUME ["/var/lib/zouch"]
EXPOSE 5985
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s CMD curl -fsS http://127.0.0.1:5985/_up >/dev/null || exit 1
ENTRYPOINT ["zouch"]
CMD ["serve", "/var/lib/zouch", "5985", "0.0.0.0"]
