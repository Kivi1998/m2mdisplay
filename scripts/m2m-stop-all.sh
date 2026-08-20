#!/bin/bash
# 通过雷雳桥接控制端口请求两端正常退出，不能用 pkill 强杀，否则发送端的
# 虚拟显示器和接收端的隐藏光标可能来不及清理。

set -u

MODE="${1:-all}"
PEER_HOST="${M2M_PEER_HOST:-10.10.10.2}"
CONTROL_PORT="${M2M_CONTROL_PORT:-51233}"
QUIT_COMMAND="M2M_DISPLAY_QUIT_V1"

if [[ "$MODE" != "all" && "$MODE" != "--peer-only" ]]; then
    echo "用法：$0 [--peer-only]" >&2
    exit 2
fi

send_quit_request() {
    local host="$1"
    local response
    response="$(/usr/bin/printf '%s\n' "$QUIT_COMMAND" | /usr/bin/nc -w 3 "$host" "$CONTROL_PORT" 2>/dev/null)"
    [[ "$response" == "OK" ]]
}

FAILED=0
if ! send_quit_request "$PEER_HOST"; then
    echo "提示：另一端未运行或未响应（$PEER_HOST:$CONTROL_PORT）" >&2
    FAILED=1
fi

if [[ "$MODE" == "all" ]]; then
    if ! send_quit_request 127.0.0.1; then
        echo "提示：本机 M2M Display 未运行" >&2
        FAILED=1
    fi
fi

if [[ $FAILED -eq 0 ]]; then
    echo "两端正常退出请求已发送"
fi
exit "$FAILED"
