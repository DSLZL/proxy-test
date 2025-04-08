#!/bin/bash
set -euo pipefail

check_dependencies() {
    local deps=("jq" "curl" "base64" "bc" "nc")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            echo "错误: 缺少依赖 $dep" >&2
            exit 1
        fi
    done
}

measure_latency() {
    local host=$1
    local port=$2
    local start end

    start=$(date +%s%3N)
    if timeout 5 nc -zvw3 "$host" "$port" >/dev/null 2>&1; then
        end=$(date +%s%3N)
        echo "scale=2; ($end - $start)/1000" | bc
    else
        echo "超时"
    fi
}

parse_proxies() {
    local sub_url=$1

    local tmp_dir
    tmp_dir=$(mktemp -d || { echo "无法创建临时目录" >&2; exit 1; })
    trap 'rm -rf "$tmp_dir"' EXIT

    curl -sL "$sub_url" | base64 -d > "$tmp_dir/nodes.txt" || {
        echo "订阅内容解码失败" >&2
        exit 1
    }

    while IFS= read -r line; do
        case $line in
            vmess://*)
                payload=$(echo "$line" | awk -F'vmess://' '{print $2}' | cut -d'#' -f1 | sed 's/\=*$//')
                json=$(echo "$payload" | base64 -d 2>/dev/null || echo "{}")
                name=$(jq -r '.ps // empty' <<< "$json" | tr -cd '[:alnum:]_-' | cut -c1-32)
                server=$(jq -r '.add // empty' <<< "$json")
                port=$(jq -r '.port // 0' <<< "$json")
                ;;
            
            vless://*|trojan://*)
                server_info=$(echo "$line" | awk -F'[@#]' '{print $2}')
                server=$(awk -F: '{print $1}' <<< "$server_info")
                port=$(awk -F: '{print $2}' <<< "$server_info" | cut -d'/' -f1)
                name=$(echo "$line" | awk -F'#' '{print $2}' | tr -cd '[:alnum:]_-' | cut -c1-32)
                ;;
            
            ss://*)
                decoded_part=$(echo "$line" | sed 's/ss:\/\///;s/#.*//')
                # 关键修复点：括号和空格修正
                padding=$(( (4 - (${#decoded_part} % 4)) % 4 ))
                decoded=$(echo "${decoded_part}$(printf '=%.0s' $(seq 1 $padding))" | base64 -d 2>/dev/null || echo "")
                
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

        [[ -z "$name" ]] && name="未命名_$(md5sum <<< "$line" | cut -c1-6)"
        [[ "$port" =~ ^[0-9]+$ ]] || port=0
        [[ "$server" =~ ^[a-zA-Z0-9.-]+$ ]] || server=""

        if [[ -z "$server" || "$port" -eq 0 ]]; then
            echo "[错误] 无效节点: ${name}" >&2
            continue
        fi

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

main() {
    check_dependencies
    if [[ $# -lt 1 ]]; then
        echo "用法: $0 <订阅链接>" >&2
        exit 1
    fi
    parse_proxies "$1"
}

main "$@"