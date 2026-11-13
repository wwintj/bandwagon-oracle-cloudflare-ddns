#!/usr/bin/env bash
# =============================================================================
# cf-ddns.sh —— VPS 公网 IP 变化时，自动把 Cloudflare 上【所有域名】中
#               指向旧 IP 的 A/AAAA 记录批量改成新 IP。
#
# 思路：
#   1. 每次运行获取本机公网 IP，与上次保存的 IP 比较；没变化直接退出（不调 CF API）。
#   2. 变化了：遍历 Token 能访问的所有 Zone → 找出内容 == 旧IP 的记录 → PATCH 为新 IP。
#      （只改 content，proxied/TTL/备注等保持不变；指向别的服务器的记录不受影响）
#   3. 全部成功才保存新 IP；有失败则下次运行自动重试。
#
# 用法：
#   cf-ddns.sh                 正常运行（由 systemd timer / cron 定时调用）
#   cf-ddns.sh --check         检查 Token 权限，并列出当前指向本机 IP 的记录
#   cf-ddns.sh --force         忽略缓存，强制执行一次同步
#   cf-ddns.sh --old-ip X.X.X.X 手动指定旧 IP（IP 已经变了才装脚本时用）
# 依赖：bash curl jq
# =============================================================================
set -uo pipefail

CONF="${CF_DDNS_CONF:-/etc/cf-ddns/cf-ddns.conf}"
# shellcheck disable=SC1090
[[ -f "$CONF" ]] && source "$CONF"

CF_API_TOKEN="${CF_API_TOKEN:-}"
STATE_DIR="${STATE_DIR:-/var/lib/cf-ddns}"
ENABLE_IPV4="${ENABLE_IPV4:-1}"
ENABLE_IPV6="${ENABLE_IPV6:-0}"
ZONES="${ZONES:-}"                     # 只处理这些域名(空格分隔)，留空=全部
EXTRA_RECORDS="${EXTRA_RECORDS:-}"     # 无论旧值是什么都强制指向本机的记录
EXCLUDE_RECORDS="${EXCLUDE_RECORDS:-}" # 永远不改的记录
TG_BOT_TOKEN="${TG_BOT_TOKEN:-}"
TG_CHAT_ID="${TG_CHAT_ID:-}"
API="https://api.cloudflare.com/client/v4"

FORCE=0; CHECK=0; OLD_IP_OVERRIDE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=1 ;;
    --check) CHECK=1 ;;
    --old-ip) OLD_IP_OVERRIDE="${2:-}"; FORCE=1; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
  shift
done

log()  { echo "$(date '+%F %T') $*"; }
die()  { log "ERROR: $*"; exit 1; }

for bin in curl jq; do command -v "$bin" >/dev/null || die "缺少依赖: $bin"; done
[[ -n "$CF_API_TOKEN" ]] || die "请在 $CONF 中设置 CF_API_TOKEN"

mkdir -p "$STATE_DIR"
exec 9>"$STATE_DIR/.lock"
command -v flock >/dev/null && { flock -n 9 || exit 0; }   # 防止并发运行

# ---------------------------------------------------------------- CF API ----
# cf METHOD PATH [JSON]  —— 成功时输出响应体，失败返回非 0
cf() {
  local method=$1 path=$2 data=${3:-} resp
  resp=$(curl -sS --max-time 20 -X "$method" "$API$path" \
          -H "Authorization: Bearer $CF_API_TOKEN" \
          -H "Content-Type: application/json" \
          ${data:+--data "$data"}) || return 1
  if [[ "$(jq -r '.success' <<<"$resp" 2>/dev/null)" != "true" ]]; then
    log "CF API 错误 [$method $path]: $(jq -c '.errors' <<<"$resp" 2>/dev/null || echo "$resp")"
    return 1
  fi
  printf '%s' "$resp"
}

# 输出: "zone_id zone_name" 每行一个
list_zones() {
  local page=1 total resp q
  if [[ -n "$ZONES" ]]; then
    for q in $ZONES; do
      resp=$(cf GET "/zones?name=$q") || return 1
      jq -r '.result[] | "\(.id) \(.name)"' <<<"$resp"
    done
    return 0
  fi
  while :; do
    resp=$(cf GET "/zones?per_page=50&page=$page") || return 1
    jq -r '.result[] | "\(.id) \(.name)"' <<<"$resp"
    total=$(jq -r '.result_info.total_pages // 1' <<<"$resp")
    (( page >= total )) && break
    page=$((page + 1))
  done
}

# list_records ZONE_ID TYPE  输出: "record_id name content"
list_records() {
  local zid=$1 type=$2 page=1 total resp
  while :; do
    resp=$(cf GET "/zones/$zid/dns_records?type=$type&per_page=100&page=$page") || return 1
    jq -r '.result[] | "\(.id) \(.name) \(.content)"' <<<"$resp"
    total=$(jq -r '.result_info.total_pages // 1' <<<"$resp")
    (( page >= total )) && break
    page=$((page + 1))
  done
}

# ---------------------------------------------------------------- 获取 IP ---
valid_ip() {
  local fam=$1 ip=$2
  if [[ $fam == 4 ]]; then
    [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
  else
    [[ $ip == *:* && $ip =~ ^[0-9a-fA-F:]+$ ]]
  fi
}

get_ip() {
  local fam=$1 url out ip urls
  if [[ $fam == 4 ]]; then
    urls="https://1.1.1.1/cdn-cgi/trace https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me/ip"
  else
    urls="https://[2606:4700:4700::1111]/cdn-cgi/trace https://api64.ipify.org https://ipv6.icanhazip.com"
  fi
  for url in $urls; do
    out=$(curl -"$fam" -sS --max-time 6 "$url" 2>/dev/null) || continue
    if [[ $out == *"ip="* ]]; then
      ip=$(sed -n 's/^ip=//p' <<<"$out")
    else
      ip=$(tr -d '[:space:]' <<<"$out")
    fi
    valid_ip "$fam" "$ip" && { echo "$ip"; return 0; }
  done
  return 1
}

# ---------------------------------------------------------------- 通知 -------
notify() {
  [[ -n "$TG_BOT_TOKEN" && -n "$TG_CHAT_ID" ]] || return 0
  curl -sS --max-time 10 "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
    --data-urlencode "chat_id=$TG_CHAT_ID" \
    --data-urlencode "text=$1" >/dev/null || log "Telegram 通知发送失败"
}

# ---------------------------------------------------------------- 主逻辑 -----
# sync_family 4|6
sync_family() {
  local fam=$1 type state new old zones records zid zname rid rname rcontent
  local fail=0 changed="" n_changed=0 n_current=0 body
  [[ $fam == 4 ]] && type=A || type=AAAA
  state="$STATE_DIR/last_ipv$fam"

  new=$(get_ip "$fam") || { log "获取公网 IPv$fam 失败"; return 1; }
  old=$(cat "$state" 2>/dev/null || true)
  if [[ -n "$OLD_IP_OVERRIDE" ]] && valid_ip "$fam" "$OLD_IP_OVERRIDE"; then
    old=$OLD_IP_OVERRIDE
  fi

  if [[ "$new" == "$old" && $FORCE == 0 && $CHECK == 0 ]]; then
    return 0   # 没变化，安静退出
  fi
  [[ $CHECK == 0 ]] && log "IPv$fam 变化: ${old:-<首次运行>} -> $new"
  [[ $CHECK == 1 ]] && log "当前公网 IPv$fam: $new"

  zones=$(list_zones) || { log "获取 Zone 列表失败"; return 1; }
  [[ -n "$zones" ]] || { log "Token 下没有可访问的 Zone"; return 1; }

  while read -r zid zname; do
    [[ -n "$zid" ]] || continue
    records=$(list_records "$zid" "$type") || { log "读取 $zname 记录失败"; fail=1; continue; }
    while read -r rid rname rcontent; do
      [[ -n "$rid" ]] || continue
      if [[ "$rcontent" == "$new" ]]; then
        n_current=$((n_current + 1))
        [[ $CHECK == 1 ]] && log "  ✔ $rname ($type) -> $rcontent"
        continue
      fi
      [[ " $EXCLUDE_RECORDS " == *" $rname "* ]] && continue
      if [[ -n "$old" && "$rcontent" == "$old" ]] || [[ " $EXTRA_RECORDS " == *" $rname "* ]]; then
        if [[ $CHECK == 1 ]]; then
          log "  ✘ $rname ($type) -> $rcontent  (将被更新为 $new)"
          continue
        fi
        body=$(jq -nc --arg ip "$new" '{content:$ip}')
        if cf PATCH "/zones/$zid/dns_records/$rid" "$body" >/dev/null; then
          log "  已更新 $rname ($type): $rcontent -> $new"
          changed+="$rname"$'\n'; n_changed=$((n_changed + 1))
        else
          log "  更新失败 $rname"
          fail=1
        fi
      fi
    done <<<"$records"
  done <<<"$zones"

  if [[ $CHECK == 1 ]]; then
    log "共 $n_current 条 $type 记录已指向本机 IP"
    return $fail
  fi

  if [[ $fail == 1 ]]; then
    log "部分记录更新失败，保留旧状态，下次运行重试"
    [[ $n_changed -gt 0 ]] && notify "⚠️ VPS IP 变化 ${old} -> ${new}，已更新 ${n_changed} 条，但有失败，稍后重试"
    return 1
  fi

  echo "$new" > "$state"
  if [[ -z "$old" ]]; then
    log "首次运行：已记录当前 IP ${new}；共 $((n_current + n_changed)) 条 ${type} 记录指向本机，以后 IP 变动将自动更新它们"
  else
    log "完成：更新 $n_changed 条记录，当前共 $((n_current + n_changed)) 条 $type 记录指向本机"
    notify "✅ VPS IPv$fam 已变化
${old} -> ${new}
Cloudflare 已更新 ${n_changed} 条记录：
${changed}"
  fi
}

if [[ $CHECK == 1 ]]; then
  cf GET "/user/tokens/verify" >/dev/null || die "Token 无效"
  log "Token 有效"
fi

rc=0
[[ "$ENABLE_IPV4" == 1 ]] && { sync_family 4 || rc=1; }
[[ "$ENABLE_IPV6" == 1 ]] && { sync_family 6 || rc=1; }
exit $rc
