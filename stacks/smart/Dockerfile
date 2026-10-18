FROM alpine:3.24.2

# renovate: datasource=github-releases depName=prometheus-community/smartctl_exporter
ARG SMARTCTL_EXPORTER_VERSION=0.14.0
ARG TARGETARCH

RUN apk add --no-cache smartmontools \
 && wget -qO- "https://github.com/prometheus-community/smartctl_exporter/releases/download/v${SMARTCTL_EXPORTER_VERSION}/smartctl_exporter-${SMARTCTL_EXPORTER_VERSION}.linux-${TARGETARCH}.tar.gz" \
  | tar -xz --strip-components=1 -C /usr/local/bin "smartctl_exporter-${SMARTCTL_EXPORTER_VERSION}.linux-${TARGETARCH}/smartctl_exporter"

EXPOSE 9633
ENTRYPOINT ["/usr/local/bin/smartctl_exporter"]
