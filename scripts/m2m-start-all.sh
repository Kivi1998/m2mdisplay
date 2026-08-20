#!/bin/bash
# 从 MacBook Pro 一键启动两端。图形界面只使用 --peer-only 启动 iMac，
# 无参数执行则先启动 iMac，再打开本机 Applications 中的正式 App。

set -u

MODE="${1:-all}"
PEER_SSH="${M2M_PEER_SSH:-kivi@10.10.10.2}"
PEER_APP="${M2M_PEER_APP:-/Applications/M2MApp.app}"
PEER_ROLE="${M2M_PEER_ROLE:-receiver}"
LOCAL_APP="${M2M_LOCAL_APP:-/Applications/M2MApp.app}"

if [[ "$MODE" != "all" && "$MODE" != "--peer-only" ]]; then
    echo "用法：$0 [--peer-only]" >&2
    exit 2
fi

if [[ "$PEER_ROLE" != "sender" && "$PEER_ROLE" != "receiver" ]]; then
    echo "错误：M2M_PEER_ROLE 只能是 sender 或 receiver" >&2
    exit 2
fi

/usr/bin/ssh -n \
    -o BatchMode=yes \
    -o ConnectTimeout=5 \
    "$PEER_SSH" \
    "test -d '$PEER_APP' && /usr/bin/open -a '$PEER_APP' --args --role '$PEER_ROLE'"
REMOTE_STATUS=$?

if [[ "$MODE" == "all" ]]; then
    if [[ ! -d "$LOCAL_APP" ]]; then
        echo "错误：本机未安装 $LOCAL_APP" >&2
        exit 1
    fi
    /usr/bin/open -a "$LOCAL_APP" --args --role sender
fi

if [[ $REMOTE_STATUS -ne 0 ]]; then
    echo "错误：无法启动 iMac 上的 M2M Display" >&2
    exit "$REMOTE_STATUS"
fi

echo "两端启动请求已发送"
