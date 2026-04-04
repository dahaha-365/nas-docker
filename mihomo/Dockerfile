FROM alpine:latest

VOLUME ["/root/mihomo"]

# 声明使用 BuildKit 的内置变量
ARG TARGETARCH
ARG TARGETPLATFORM

# 在 RUN 指令中直接使用
RUN echo "当前构建架构是: ${TARGETARCH}" && \
    echo "当前构建平台是: ${TARGETPLATFORM}"

WORKDIR /root

RUN apk update --no-cache && apk add --no-cache curl dcron gzip ca-certificates yq

RUN mkdir -p /usr/local/mihomo && \
    VERSION=$(curl -fsSL https://github.com/MetaCubeX/mihomo/releases/latest/download/version.txt) && \
    ARCH=${TARGETARCH} && \
    [ "$TARGETARCH" = "arm" ] && ARCH="armv7" ; \
    URL="https://github.com/MetaCubeX/mihomo/releases/latest/download/mihomo-linux-${ARCH}-${VERSION}.gz" && \
    echo "下载地址: ${URL}" && \
    curl -L --progress-bar "${URL}" -o /usr/local/mihomo/mihomo.gz && \
    gunzip -c /usr/local/mihomo/mihomo.gz > /usr/local/mihomo/mihomo && \
    rm /usr/local/mihomo/mihomo.gz && \
    chmod +x /usr/local/mihomo/mihomo && \
    ls -la /usr/local/mihomo/ && \
    echo /usr/local/mihomo/mihomo -v

CMD ["tail", "-f", "/dev/null"]
