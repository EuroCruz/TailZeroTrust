FROM golang:1.27.3-alpine3.24 AS build-env

# Install latest version of git
RUN apk add --update --no-cache git

# Let newer Tailscale releases pull the Go toolchain they require
ENV GOTOOLCHAIN=auto

# Clone latest Tailscale version and patch it with customisation, some patches
# are lifted from the PR https://github.com/tailscale/tailscale/pull/14575
ARG TS_VERSION="v1.104.2"
WORKDIR /go/src/tailscale
COPY ./tailscale-patches /tmp/tailscale-patches
RUN \
  git -c advice.detachedHead=false clone --branch "$TS_VERSION" \
    https://github.com/tailscale/tailscale.git /go/src/tailscale && \
  git -c user.name="TailZeroTrust" -c user.email="" am /tmp/tailscale-patches/*.patch

# Download dependencies and build Tailscale
RUN go mod download

ARG TARGETARCH
RUN \
  eval `CGO_ENABLED=0 GOOS=$(go env GOHOSTOS) GOARCH=$(go env GOHOSTARCH) go run ./cmd/mkversion` && \
  VERSION_LONG="$(echo $VERSION_LONG | rev | cut -d "-" -f 3- | rev)-TailZeroTrust" && \
  CGO_ENABLED=0 GOARCH=$TARGETARCH go install -ldflags="-s -w \
      -X 'tailscale.com/version.longStamp=$VERSION_LONG' \
      -X 'tailscale.com/version.shortStamp=$VERSION_SHORT' \
      -X 'tailscale.com/version.gitCommitStamp=$VERSION_GIT_HASH'" \
      -v ./cmd/tailscale ./cmd/tailscaled ./cmd/containerboot && \
  mkdir -p /out && find /go/bin -type f -exec cp {} /out/ \;

# Take only the daemon and the CLI out of the official Cloudflare WARP package,
# the package itself depends on the whole desktop GUI stack
FROM debian:bookworm-slim AS warp-env

RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl

ARG WARP_VERSION="2026.8.2115.0"
ARG TARGETARCH
RUN \
  repo=https://pkg.cloudflareclient.com && \
  index="$(curl -fsSL "$repo/dists/bookworm/main/binary-$TARGETARCH/Packages")" && \
  entry="$(echo "$index" | awk -v v="$WARP_VERSION" 'BEGIN{RS=""} index($0, "\nVersion: " v "\n")')" && \
  { [ -n "$entry" ] || { echo "cloudflare-warp $WARP_VERSION not found in $repo"; exit 1; }; } && \
  curl -fsSL -o /tmp/warp.deb "$repo/$(echo "$entry" | sed -n 's/^Filename: //p')" && \
  echo "$(echo "$entry" | sed -n 's/^SHA256: //p')  /tmp/warp.deb" | sha256sum -c - && \
  dpkg-deb -x /tmp/warp.deb /tmp/warp && \
  mkdir -p /out && cp /tmp/warp/bin/warp-svc /tmp/warp/bin/warp-cli /out/

# WARP is linked against glibc, so the runtime is Debian instead of Alpine
FROM debian:bookworm-slim

RUN \
  apt-get update && \
  apt-get install -y --no-install-recommends \
    ca-certificates curl ethtool iproute2 iptables ipcalc-ng nftables dbus \
    libdbus-1-3 libnss3 libtss2-esys-3.0.2-0 libtss2-tctildr0 libtss2-mu0 && \
  ln -s /usr/bin/ipcalc-ng /usr/local/bin/ipcalc && \
  rm -rf /var/lib/apt/lists/*

WORKDIR /tailzerotrust

COPY --from=build-env /out/* /usr/local/bin/
COPY --from=warp-env /out/* /bin/

COPY bin/* ./
RUN chmod 755 *.sh

HEALTHCHECK --interval=1m --timeout=10s --start-period=10s --start-interval=1s --retries=3 \
  CMD ["/tailzerotrust/healthcheck.sh"]

ENTRYPOINT ["/tailzerotrust/entrypoint.sh"]
