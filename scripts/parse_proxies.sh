#!/bin/bash
set -euo pipefail

# 依赖检查函数
check_dependencies() {
    local deps=("jq" "curl" "base64" "bc" "nc")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            echo "错误: 缺少依赖 $dep"
            exit 1
        fi
    done
}

# 延迟测试函数（兼容容器环境）
measure_latency() {
    local host=$1
    local port=$2
    local start end

    # 使用 nc 命令测试 TCP 连通性
    start=$(date +%s%3N)
    if timeout 5 nc -zvw3 "$host" "$port" >/dev/null 2>&1; then
        end=$(date +%s%3N)
        echo "scale=2; ($end - $start)/1000" | bc
    else
        echo "超时"
    fi
}

# 主解析函数
parse_proxies() {
    local sub_url=$1

    # 创建临时工作目录
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'rm -rf "$tmp_dir"' EXIT

    # 获取订阅内容
    curl -sL "$sub_url" | base64 -d > "$tmp_dir/nodes.txt"

    # 解析节点
    while read -r line; do
        case $line in
            vmess://*)
                # 提取并处理 VMess 配置
                payload=$(echo "$line" | awk -F'vmess://' '{print $2}' | cut -d'#' -f1 | sed 's/\=*$//')
                json=$(echo "$payload" | base64 -d 2>/dev/null || echo "{}")
                name=$(jq -r '.ps // empty' <<< "$json" | tr -cd '[:alnum:]_-' | cut -c1-32)
                server=$(jq -r '.add // empty' <<< "$json")
                port=$(jq -r '.port // 0' <<< "$json")
                ;;
            
            vless://*|trojan://*)
                # 解析 VLESS/Trojan
                server_info=$(echo "$line" | awk -F'[@#]' '{print $2}')
                server=$(awk -F: '{print $1}' <<< "$server_info")
                port=$(awk -F: '{print $2}' <<< "$server_info" | cut -d'/' -f1)
                name=$(echo "$line" | awk -F'#' '{print $2}' | tr -cd '[:alnum:]_-' | cut -c1-32)
                ;;
            
            ss://*)
                # 处理 Shadowsocks 特殊编码
                decoded_part=$(echo "$line" | sed 's/ss:\/\///;s/#.*//')
                padding=$(( (4 - (${#decoded_part} % 4)) %4 )
                decoded=$(echo "$decoded_part" | sed "s/$/$(printf '=%.0s' $(seq 1 $padding))/" | base64 -d 2>/dev/null)
                
                method=$(cut -d: -f1 <<< "$decoded")
                password=$(cut -d: -f2- <<< "$decoded" | cut -d@ -f1)
                server_port=$(cut -d@ -f2 <<< "$decoded")
                server=$(cut -d: -f1 <<< "$server_port")
                port=$(cut -d: -f2 <<< "$server_port")
                name=$(echo "$line" | awk -F'#' '{print $2}' | tr -cd '[:alnum:]_-' | cut -c1-32)
                ;;
            *)
                continue
                ;;
        esac

        # 数据验证
        [[ -z "$name" ]] && name="未命名_$(md5sum <<< "$line" | cut -c1-6)"
        [[ "$port" =~ ^[0-9]+$ ]] || port=0
        [[ "$server" =~ ^[a-zA-Z0-9.-]+$ ]] || server=""

        # 跳过无效条目
        if [[ -z "$server" || "$port" -eq 0 ]]; then
            echo "[错误] 无效节点: ${name}" >&2
            continue
        fi

        # 测试延迟（最多重试2次）
        latency="超时"
        for _ in {1..2}; do
            result=$(measure_latency "$server" "$port")
            if [[ "$result" != "超时" ]]; then
                latency="$result"
                break
            fi
        done

        echo "${name} | 延迟: ${latency}s"
    done < <(grep -E 'vmess://|vless://|trojan://|ss://' "$tmp_dir/nodes.txt")
}

# 主执行流程
main() {
    check_dependencies
    if [[ $# -lt 1 ]]; then
        echo "用法: $0 <订阅链接>"
        exit 1
    fi
    parse_proxies "$1"
}

main "$@"