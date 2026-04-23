FROM alpine:latest

VOLUME ["/root/mihomo"]

ARG TARGETARCH
ARG TARGETPLATFORM

ENV ARCH=${TARGETARCH}
ENV PLATFORM=${TARGETPLATFORM}

WORKDIR /root

COPY ./entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh", ""]

CMD ["tail", "-f", "/dev/null"]
