#!/bin/sh
# shellcheck disable=SC2039

PID_FILE="/root/mihomo/mihomo.pid"
VERSION_FILE="/root/mihomo/version"
BINARY_FILE="/root/mihomo/mihomo"
CUSTOM_FILE="/root/mihomo/custom.yaml"
SUBSCRIBE_FILE="/root/mihomo/subscribe.yaml"
CONFIG_FILE="/root/mihomo/config/config.yaml"
CRON_LOG_FILE="/root/mihomo/cron.log"

# ======================================
# 进程管理函数
# ======================================

get_pid() {
    if [ -f "$PID_FILE" ]; then
        cat "$PID_FILE"
    fi
}

is_running() {
    PID="$(get_pid)"
    if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
        return 0
    fi
    return 1
}

do_start() {
    if is_running; then
        echo "Mihomo 已在运行中 (PID: $(get_pid))，无需重复启动。"
        return 0
    fi

    echo "启动 Mihomo..."
    "$BINARY_FILE" -d /root/mihomo/config &
    MIHOMO_PID=$!
    echo "$MIHOMO_PID" > "$PID_FILE"
    echo "Mihomo 已启动 (PID: $MIHOMO_PID)。"
}

do_stop() {
    if ! is_running; then
        echo "Mihomo 未在运行。"
        rm -f "$PID_FILE"
        return 0
    fi

    PID="$(get_pid)"
    echo "正在终止 Mihomo 进程 (PID: $PID)..."
    kill -TERM "$PID" 2>/dev/null

    # 等待进程退出，最多 10 秒
    i=0
    while kill -0 "$PID" 2>/dev/null; do
        if [ "$i" -ge 10 ]; then
            echo "进程未在 10 秒内退出，强制终止..."
            kill -KILL "$PID" 2>/dev/null
            break
        fi
        sleep 1
        i=$((i + 1))
    done

    rm -f "$PID_FILE"
    echo "Mihomo 已停止。"
}

do_restart() {
    echo "正在重启 Mihomo..."
    do_stop
    do_start
}

do_reload() {
    echo "正在重载配置..."
    curl --unix-socket /root/mihomo/config/mihomo.sock -X PUT "http://localhost/configs" -d '{"force": true}'
    echo "已重载配置"
}

# ======================================
# 订阅更新函数
# ======================================

update_subscribe() {
    # 1. 获取订阅文件
    if [ -z "$SUBSCRIBE_URL" ]; then
        echo "警告: 未设置 SUBSCRIBE_URL 环境变量，将使用空白订阅文件。"
        if [ ! -f "$SUBSCRIBE_FILE" ]; then
            touch "$SUBSCRIBE_FILE"
            echo "已创建空白 subscribe.yaml。"
        fi
    else
        echo "正在从订阅地址下载配置..."

        DOWNLOAD_FAILED=false
        ERROR_MSG=$(wget -O "$SUBSCRIBE_FILE" -q --timeout=10 "$SUBSCRIBE_URL" 2>&1) || DOWNLOAD_FAILED=true

        if [ "$DOWNLOAD_FAILED" = "true" ] || [ ! -s "$SUBSCRIBE_FILE" ]; then
            echo "错误: 下载配置文件失败！"
            echo "详细信息: $ERROR_MSG"
            echo "请检查 SUBSCRIBE_URL 是否有效，以及网络连接是否正常。"
            return 1
        fi

        echo "订阅文件下载成功！"
    fi

    # 2. 合并 custom.yaml（若有有效内容）
    CUSTOM_VALID=false
    KEYS=$(yq eval 'map(keys)' "$CUSTOM_FILE" 2>/dev/null)
    if [ -n "$KEYS" ] && [ "$KEYS" != "[]" ]; then
        CUSTOM_VALID=true
    fi

    if [ "$CUSTOM_VALID" = "true" ]; then
        echo "检测到 custom.yaml 有效，正在合并配置..."
        yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' \
            "$SUBSCRIBE_FILE" "$CUSTOM_FILE" > "$CONFIG_FILE"
    else
        cp "$SUBSCRIBE_FILE" "$CONFIG_FILE"
    fi

    # 3. 应用固化配置
    echo "正在应用固化配置..."
    yq eval -i '.allow-lan = true'                          "$CONFIG_FILE"
    yq eval -i '.bind-address = "*"'                        "$CONFIG_FILE"
    yq eval -i '.external-controller = "0.0.0.0:9090"'      "$CONFIG_FILE"
    yq eval -i '.port = 7890'                               "$CONFIG_FILE"
    yq eval -i '.socks-port = 7891'                         "$CONFIG_FILE"
    yq eval -i '.mixed-port = 7892'                         "$CONFIG_FILE"
    yq eval -i '.redir-port = 7893'                         "$CONFIG_FILE"
    yq eval -i '.tproxy-port = 7894'                        "$CONFIG_FILE"
    yq eval -i '.external-controller-unix = "mihomo.sock"'  "$CONFIG_FILE"

    echo "配置文件已生成：${CONFIG_FILE}"
}

update_and_reload() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ========== 定时更新任务开始 =========="

    if update_subscribe; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] 订阅更新成功，准备重载配置..."
        sleep 2  # 等待文件写入完成
        do_reload
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] 订阅更新失败，跳过配置重载。"
    fi

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ========== 定时更新任务结束 =========="
}

update_geo() {
    curl --unix-socket /root/mihomo/config/mihomo.sock -X POST "http://localhost/upgrade/geo" -d '{"path": "", "payload": ""}'
}

# ======================================
# 定时任务管理
# ======================================

setup_cron() {
    local NEED_CROND=false
    local TEMP_CRONTAB="/tmp/crontab"

    # 初始化临时文件
    > "$TEMP_CRONTAB"

    # 如果已有 crontab，先读取
    if crontab -l > /dev/null 2>&1; then
        crontab -l > "$TEMP_CRONTAB" 2>/dev/null
    fi

    # 处理订阅更新定时任务
    if [ -n "$SUBSCRIBE_CRON" ]; then
        echo "检测到 SUBSCRIBE_CRON 环境变量: $SUBSCRIBE_CRON"
        echo "正在设置定时更新订阅任务..."
        NEED_CROND=true

        SCRIPT_PATH=$(readlink -f "$0")
        echo "$SUBSCRIBE_CRON $SCRIPT_PATH cron-update-subscribe >> $CRON_LOG_FILE 2>&1" >> "$TEMP_CRONTAB"

        echo "定时更新订阅任务已设置: $SUBSCRIBE_CRON"
    else
        echo "未设置 SUBSCRIBE_CRON 环境变量，跳过定时更新订阅任务设置。"
    fi

    # 处理 GEO 更新定时任务
    if [ -n "$GEO_CRON" ]; then
        echo "检测到 GEO_CRON 环境变量: $GEO_CRON"
        echo "正在设置定时更新 GEO 文件任务..."
        NEED_CROND=true

        SCRIPT_PATH=$(readlink -f "$0")
        echo "$GEO_CRON $SCRIPT_PATH cron-update-geo >> $CRON_LOG_FILE 2>&1" >> "$TEMP_CRONTAB"

        echo "定时更新 GEO 文件任务已设置: $GEO_CRON"
    else
        echo "未设置 GEO_CRON 环境变量，跳过定时更新 GEO 文件任务设置。"
    fi

    # 如果有任何定时任务需要设置
    if [ "$NEED_CROND" = true ]; then
        # 安装 crond
        if ! command -v crond > /dev/null 2>&1; then
            echo "crond 未安装，正在安装..."
            apk add --no-cache dcron > /dev/null 2>&1 || {
                echo "警告: 无法安装 crond，定时任务将不可用"
                return 1
            }
        fi

        # 加载 crontab
        crontab "$TEMP_CRONTAB" 2>/dev/null

        # 启动 crond（后台运行）
        crond -b -l 2 2>/dev/null || crond 2>/dev/null

        echo "定时任务日志文件: $CRON_LOG_FILE"
        echo "当前所有定时任务:"
        crontab -l
    fi
}

# ======================================
# 信号处理
# ======================================

handle_signal() {
    echo "收到停止信号，正在终止 Mihomo..."
    do_stop
    exit 0
}

trap 'handle_signal' TERM INT

# ======================================
# 子命令入口
# ======================================

case "$1" in
    start)
        do_start
        exit 0
        ;;
    stop)
        do_stop
        exit 0
        ;;
    restart)
        do_restart
        exit 0
        ;;
    reload)
        do_reload
        exit 0
        ;;
    update-subscribe)
        update_subscribe
        exit $?
        ;;
    update-geo)
        update_geo
        exit $?
        ;;
    cron-update-subscribe)
        # 更新订阅并重载配置
        update_and_reload
        exit $?
        ;;
    cron-update-geo)
        # 更新 GEO 文件
        update_geo
        exit $?
        ;;
    "")
        # 无参数：执行完整初始化流程（见下方）
        ;;
    *)
        echo "用法: $0 {start|stop|restart|update-subscribe|cron-update|update-geo}"
        exit 1
        ;;
esac

# ======================================
# 初始化流程（首次启动）
# ======================================

echo "正在进行初始化设置..."

apk add --no-cache gzip ca-certificates yq iptables curl

echo "系统平台：${PLATFORM}"
echo "系统架构：${ARCH}"

MIHOMO_VERSION=$(wget -q -O- https://github.com/MetaCubeX/mihomo/releases/latest/download/version.txt)
echo "远程最新 Mihomo 版本是：${MIHOMO_VERSION}"

mkdir -p /root/mihomo/config

if [ ! -f "$VERSION_FILE" ] || [ "$(cat "$VERSION_FILE")" != "$MIHOMO_VERSION" ]; then
    echo "检测到版本变更或首次安装，正在下载新版本..."

    URL="https://github.com/MetaCubeX/mihomo/releases/latest/download/mihomo-linux-${ARCH}-${MIHOMO_VERSION}.gz"
    echo "从 ${URL} 下载最新版本 Mihomo"

    wget -O /root/mihomo/mihomo.gz.new --no-verbose "${URL}"
    gunzip -c /root/mihomo/mihomo.gz.new > "${BINARY_FILE}.new"

    mv "${BINARY_FILE}.new" "$BINARY_FILE"
    rm -f /root/mihomo/mihomo.gz.new

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
    touch "$CUSTOM_FILE"
fi

echo "custom.yaml 可以对订阅文件进行个性化设置，详情请参考：https://wiki.metacubex.one/config/"

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
        echo 262144 > /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null \
            || echo "无法修改 nf_conntrack_max (权限不足)"
    fi
fi

echo "网络环境检查完毕。"

update_subscribe || exit 1

setup_cron

CONTAINER_IP=$(hostname -i 2>/dev/null | awk '{print $1}' || echo '未知')
echo "========================================"
echo "  Mihomo 容器已启动"
echo "  容器 IP: ${CONTAINER_IP}"
if [ -n "$SUBSCRIBE_CRON" ]; then
    echo "  定时更新订阅: $SUBSCRIBE_CRON"
fi
if [ -n "$GEO_CRON" ]; then
    echo "  定时更新 GEO 文件: $GEO_CRON"
fi
echo "========================================"

do_start

# 等待 Mihomo 进程退出
MIHOMO_PID="$(get_pid)"
if [ -n "$MIHOMO_PID" ]; then
    wait "$MIHOMO_PID"
fi
