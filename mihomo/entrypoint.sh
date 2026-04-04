#!/bin/sh

echo "正在进行初始化设置..."

apk add --no-cache gzip ca-certificates yq iptables

echo "系统平台：${PLATFORM}"
echo "系统架构：${ARCH}"

MIHOMO_VERSION=$(wget -q -O- https://github.com/MetaCubeX/mihomo/releases/latest/download/version.txt)
echo "远程最新 Mihomo 版本是：${MIHOMO_VERSION}"

VERSION_FILE="/root/mihomo/version"
BINARY_FILE="/root/mihomo/mihomo"
CUSTOM_FILE="/root/mihomo/custom.yaml"
SUBSCRIBE_FILE="/root/mihomo/subscribe.yaml"
CONFIG_FILE="/root/mihomo/config/config.yaml"
TEMP_MERGE="/tmp/mihomo_merge.yaml"

mkdir -p /root/mihomo/config

if [ ! -f "$VERSION_FILE" ] || [ "$(cat $VERSION_FILE)" != "$MIHOMO_VERSION" ]; then
    echo "检测到版本变更或首次安装，正在下载新版本..."

    URL="https://github.com/MetaCubeX/mihomo/releases/latest/download/mihomo-linux-${ARCH}-${MIHOMO_VERSION}.gz"
    echo "从 ${URL} 下载最新版本 Mihomo"

    wget -O /root/mihomo/mihomo.gz.new --no-verbose "${URL}"
    gunzip -c /root/mihomo/mihomo.gz.new > "$BINARY_FILE.new"

    mv "$BINARY_FILE.new" "$BINARY_FILE"
    mv /root/mihomo/mihomo.gz.new "$VERSION_FILE"

    chmod +x "$BINARY_FILE"
    echo "$MIHOMO_VERSION" > "$VERSION_FILE"

    echo "更新完成。"
else
    echo "本地版本已是最新，跳过下载步骤。"
fi

if [ -f "$BINARY_FILE" ]; then
    "$BINARY_FILE" -v
else
    echo "错误：Mihomo 二进制文件不存在，请检查下载逻辑。"
    exit 1
fi

if [ ! -f "$CUSTOM_FILE" ]; then
    touch $CUSTOM_FILE
fi

echo "custom.yaml 可以对订阅文件进行个性化设置，详情请参考：https://wiki.metacubex.one/config/"

if [ -z "$SUBSCRIBE_URL" ]; then
    echo "警告: 未设置 SUBSCRIBE_URL 环境变量，跳过订阅下载。"
else
    echo "正在从订阅地址下载配置..."

    ERROR_MSG=$(wget -O "$SUBSCRIBE_FILE" -q --timeout=10 "$SUBSCRIBE_URL" 2>&1) || DOWNLOAD_FAILED=true

    if [ "$DOWNLOAD_FAILED" = "true" ] || [ ! -s "$SUBSCRIBE_FILE" ]; then
        echo "错误: 下载配置文件失败！"
        echo "详细信息: $ERROR_MSG"
        echo "请检查 SUBSCRIBE_URL 是否有效，以及网络连接是否正常。"

        exit 1
    fi

    echo "配置文件下载成功！"
fi

CUSTOM_VALID=false

KEYS=$(yq eval 'map(keys)' "$CUSTOM_FILE" 2>/dev/null)

if [ -n "$KEYS" ] && [ "$KEYS" != "[]" ]; then
    CUSTOM_VALID=true
fi

if [ "$CUSTOM_VALID" = true ]; then
    yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' "$SUBSCRIBE_FILE" "$CUSTOM_FILE" > "$CONFIG_FILE"
else
    cp "$SUBSCRIBE_FILE" "$CONFIG_FILE"
fi

echo "正在应用固化配置..."
yq eval -i '.allow-lan = true' "$CONFIG_FILE"
yq eval -i '.bind-address = "*"' "$CONFIG_FILE"
yq eval -i '.external-controller = "0.0.0.0:9090"' "$CONFIG_FILE"
yq eval -i '.port = 7890' "$CONFIG_FILE"
yq eval -i '.socks-port = 7891' "$CONFIG_FILE"
yq eval -i '.mixed-port = 7892' "$CONFIG_FILE"
yq eval -i '.redir-port = 7893' "$CONFIG_FILE"
yq eval -i '.tproxy-port = 7894' "$CONFIG_FILE"

echo "正在检查 Tun 模式所需的网络环境..."

if [ "$(cat /proc/sys/net/ipv4/ip_forward)" = "0" ]; then
    echo "开启 IPv4 转发..."
    if ! echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null; then
        echo "警告: 无法修改 ip_forward，请确保容器拥有 NET_ADMIN 权限或 --privileged 权限。"
    else
        echo "IPv4 转发已开启。"
    fi
else
    echo "IPv4 转发已开启，无需操作。"
fi

if [ -f /proc/sys/net/netfilter/nf_conntrack_max ]; then
    CURRENT_MAX=$(cat /proc/sys/net/netfilter/nf_conntrack_max)
    if [ "$CURRENT_MAX" -lt 262144 ]; then
        echo "优化 nf_conntrack_max: $CURRENT_MAX -> 262144"
        echo 262144 > /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo "无法修改 nf_conntrack_max (权限不足)"
    fi
fi

echo "网络环境检查完毕。"

echo "========================================"
echo "  Mihomo 容器已启动"
echo "  容器 IP: $(hostname -i 2>/dev/null | awk '{print $1}' || echo '未知')"
echo "========================================"

MIHOMO_PID=""

stop_mihomo() {
    if [ ! -z "$MIHOMO_PID" ]; then
        echo "收到停止信号，正在终止 Mihomo 进程 (PID: $MIHOMO_PID)..."
        kill -TERM "$MIHOMO_PID" 2>/dev/null
        wait "$MIHOMO_PID" 2>/dev/null
        echo "Mihomo 已停止。"
    fi
    exit 0
}

trap 'stop_mihomo' SIGTERM SIGINT

echo "启动 Mihomo..."
$BINARY_FILE -d /root/mihomo/config &
MIHOMO_PID=$!

wait $MIHOMO_PID

exec "$@"
