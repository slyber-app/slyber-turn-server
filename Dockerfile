FROM alpine:3.20

ARG TARGETARCH
ARG VERSION=latest
ARG VCS_REF=unknown

LABEL org.opencontainers.image.title="Slyber Turn Server" \
      org.opencontainers.image.description="High-Performance WebRTC TURN/STUN Server" \
      org.opencontainers.image.source="https://github.com/slyber-app/slyber-turn-server" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}"

RUN apk add --no-cache ca-certificates tzdata && \
    addgroup -S -g 10001 slyber_turn && \
    adduser -S -u 10001 -G slyber_turn -h /data -s /sbin/nologin slyber_turn && \
    mkdir -p /data/certs && \
    chown -R slyber_turn:slyber_turn /data

COPY bin/slyber_turn-linux-${TARGETARCH} /usr/local/bin/slyber_turn
COPY bin/SHA256SUMS /tmp/SHA256SUMS

RUN grep " slyber_turn-linux-${TARGETARCH}\$" /tmp/SHA256SUMS | awk '{print $1 "  /usr/local/bin/slyber_turn"}' | sha256sum -c - && \
    rm -f /tmp/SHA256SUMS && \
    chmod 0755 /usr/local/bin/slyber_turn

WORKDIR /data

ENV DATA_DIR="/data" \
    UDP_PORT="3478" \
    TCP_PORT="3478" \
    TLS_PORT="5349" \
    HTTP_PORT=":8080" \
    RELAY_MIN_PORT="49152" \
    RELAY_MAX_PORT="65535" \
    LOG_FORMAT="json"

EXPOSE 3478/udp 3478/tcp 5349/tcp 8080/tcp

VOLUME ["/data"]

USER slyber_turn:slyber_turn

ENTRYPOINT ["/usr/local/bin/slyber_turn"]
CMD ["server"]