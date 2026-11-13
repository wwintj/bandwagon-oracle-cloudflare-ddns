#!/usr/bin/env bash
# =============================================================================
# cf-ddns 一键安装 / 管理脚本
#   bash <(curl -fsSL https://raw.githubusercontent.com/wwintj/bandwagon-oracle-cloudflare-ddns/main/install.sh)
#
# 非交互安装（适合批量部署）：
#   bash <(curl -fsSL .../install.sh) install --token XXX --zone example.com --record vps.example.com
# 子命令：install | update | check | log | uninstall
# =============================================================================
set -euo pipefail

REPO_RAW="${CF_DDNS_REPO_RAW:-https://raw.githubusercontent.com/wwintj/bandwagon-oracle-cloudflare-ddns/main}"
BIN=/usr/local/bin/cf-ddns.sh
CONF_DIR=/etc/cf-ddns
CONF=$CONF_DIR/cf-ddns.conf
STATE_DIR=/var/lib/cf-ddns
API=https://api.cloudflare.com/client/v4

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }
die()   { red "错误: $*"; exit 1; }
ask()   { # ask 变量名 提示 [默认值]
  local __v=$1 __p=$2 __d=${3:-} __a
  if [[ -n "$__d" ]]; then read -r -p "$__p [$__d]: " __a </dev/tty || true; else read -r -p "$__p: " __a </dev/tty || true; fi
  printf -v "$__v" '%s' "${__a:-$__d}"
}

[[ $EUID -eq 0 ]] || die "请使用 root 运行（sudo -i 后再执行）"

has_systemd() { [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null; }

install_deps() {
  command -v curl >/dev/null && command -v jq >/dev/null && return 0
  yellow "安装依赖 curl jq ..."
  if   command -v apt-get >/dev/null; then apt-get update -y >/dev/null && apt-get install -y curl jq >/dev/null
  elif command -v dnf     >/dev/null; then dnf install -y curl jq >/dev/null
  elif command -v yum     >/dev/null; then yum install -y epel-release >/dev/null 2>&1 || true; yum install -y curl jq >/dev/null
  elif command -v apk     >/dev/null; then apk add --no-cache bash curl jq >/dev/null
  else die "无法自动安装依赖，请手动安装 curl 和 jq"; fi
}

fetch_main_script() {
  local here; here=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)
  if [[ -n "$here" && -f "$here/cf-ddns.sh" ]]; then
    install -m 755 "$here/cf-ddns.sh" "$BIN"
  else
    curl -fsSL "$REPO_RAW/cf-ddns.sh" -o "$BIN.tmp" || die "下载 cf-ddns.sh 失败"
    bash -n "$BIN.tmp" || die "下载的脚本不完整"
    mv "$BIN.tmp" "$BIN"; chmod 755 "$BIN"
  fi
}

cf_get() { curl -fsS --max-time 20 "$API$1" -H "Authorization: Bearer $TOKEN"; }

setup_scheduler() {
  if has_systemd; then
    cat >/etc/systemd/system/cf-ddns.service <<'EOF'
[Unit]
Description=Cloudflare DDNS updater
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/cf-ddns.sh
EOF
    cat >/etc/systemd/system/cf-ddns.timer <<'EOF'
[Unit]
Description=Run Cloudflare DDNS updater every 30s

[Timer]
OnBootSec=15s
OnUnitActiveSec=30s
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now cf-ddns.timer >/dev/null 2>&1
    systemctl restart cf-ddns.timer
  else
    # 无 systemd（如部分 OpenVZ / Alpine）：用 cron，每分钟两次
    local line1="* * * * * $BIN >>/var/log/cf-ddns.log 2>&1"
    local line2="* * * * * sleep 30; $BIN >>/var/log/cf-ddns.log 2>&1"
    local line3="@reboot sleep 15; $BIN >>/var/log/cf-ddns.log 2>&1"
    (crontab -l 2>/dev/null | grep -v cf-ddns.sh || true; echo "$line1"; echo "$line2"; echo "$line3") | crontab -
  fi
}

do_install() {
  local TOKEN="${CF_API_TOKEN:-}" ZONES_IN="${ZONES:-}" RECORDS_IN="${EXTRA_RECORDS:-}" V6="${ENABLE_IPV6:-}"
  local TG_T="${TG_BOT_TOKEN:-}" TG_C="${TG_CHAT_ID:-}" NONINTERACTIVE=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --token)  TOKEN=$2; shift ;;
      --zone)   ZONES_IN=$2; shift ;;
      --record) RECORDS_IN=$2; shift ;;
      --ipv6)   V6=1 ;;
      --tg-token) TG_T=$2; shift ;;
      --tg-chat)  TG_C=$2; shift ;;
      -y|--yes) NONINTERACTIVE=1 ;;
      *) die "未知参数 $1" ;;
    esac; shift
  done
  [[ -n "$TOKEN" ]] && NONINTERACTIVE=1

  install_deps

  # 已有配置时作为默认值
  if [[ -f "$CONF" ]]; then
    # shellcheck disable=SC1090
    local OLD_TOKEN OLD_ZONES OLD_REC OLD_V6 OLD_TGT OLD_TGC
    OLD_TOKEN=$(. "$CONF"; echo "${CF_API_TOKEN:-}"); OLD_ZONES=$(. "$CONF"; echo "${ZONES:-}")
    OLD_REC=$(. "$CONF"; echo "${EXTRA_RECORDS:-}");  OLD_V6=$(. "$CONF"; echo "${ENABLE_IPV6:-0}")
    OLD_TGT=$(. "$CONF"; echo "${TG_BOT_TOKEN:-}");   OLD_TGC=$(. "$CONF"; echo "${TG_CHAT_ID:-}")
  fi

  if [[ $NONINTERACTIVE == 0 ]]; then
    echo
    echo "Cloudflare API Token 创建：https://dash.cloudflare.com/profile/api-tokens"
    echo "  模板 \"Edit zone DNS\"，权限 Zone:Read + DNS:Edit，Zone Resources 建议选 All zones"
    if [[ -n "${OLD_TOKEN:-}" ]]; then
      ask TOKEN "API Token（回车保留现有 ${OLD_TOKEN:0:8}...）"; TOKEN=${TOKEN:-$OLD_TOKEN}
    else
      ask TOKEN "API Token"
    fi
  fi
  [[ -n "$TOKEN" ]] || die "Token 不能为空"

  [[ "$(cf_get /user/tokens/verify | jq -r .success 2>/dev/null)" == true ]] || die "Token 无效或无法连接 Cloudflare"
  green "✔ Token 有效"
  local zl; zl=$(cf_get "/zones?per_page=50" | jq -r '.result[].name' | tr '\n' ' ' || true)
  echo "  Token 可访问的域名: ${zl:-<无>}"

  local myip; myip=$(curl -4 -fsS --max-time 6 https://api.ipify.org || true)
  echo "  本机公网 IPv4: ${myip:-获取失败}"

  if [[ $NONINTERACTIVE == 0 ]]; then
    echo
    echo "只处理哪些域名？（空格分隔，留空=上面全部）"
    ask ZONES_IN "域名" "${OLD_ZONES:-$ZONES_IN}"
    echo "强制指向本机的记录（如 vps.example.com，空格分隔，可留空）"
    echo "  不填也行：IP 变化时，所有指向旧 IP 的记录都会自动更新"
    ask RECORDS_IN "记录" "${OLD_REC:-$RECORDS_IN}"
    ask V6 "同步 IPv6 (AAAA)？0=否 1=是" "${OLD_V6:-0}"
    ask TG_T "Telegram Bot Token（可留空）" "${OLD_TGT:-}"
    [[ -n "$TG_T" ]] && ask TG_C "Telegram Chat ID" "${OLD_TGC:-}"
  fi

  fetch_main_script
  mkdir -p "$CONF_DIR" "$STATE_DIR"
  umask 077
  cat >"$CONF" <<EOF
# cf-ddns 配置，修改后无需重启，下次运行自动生效
CF_API_TOKEN="$TOKEN"
ENABLE_IPV4=1
ENABLE_IPV6=${V6:-0}
ZONES="$ZONES_IN"
EXTRA_RECORDS="$RECORDS_IN"
EXCLUDE_RECORDS=""
TG_BOT_TOKEN="$TG_T"
TG_CHAT_ID="$TG_C"
EOF
  chmod 600 "$CONF"; umask 022

  echo; "$BIN" --check || yellow "检查有警告，请看上面的输出"
  "$BIN" || true      # 首次运行：记录当前 IP / 同步 EXTRA_RECORDS
  setup_scheduler
  echo
  green "✔ 安装完成，每 30 秒检测一次公网 IP"
  echo "  配置文件: $CONF"
  echo "  查看日志: $(has_systemd && echo 'journalctl -u cf-ddns -f' || echo 'tail -f /var/log/cf-ddns.log')"
  echo "  管理菜单: 重新执行一键安装命令即可"
}

do_update()    { install_deps; fetch_main_script; green "✔ 已更新 $BIN"; }
do_check()     { [[ -x $BIN ]] || die "未安装"; "$BIN" --check; }
do_log()       { if has_systemd; then journalctl -u cf-ddns --no-pager -n 50 | grep -v -e 'Starting Cloud' -e 'Succeeded' -e 'Finished Cloud'; else tail -n 50 /var/log/cf-ddns.log; fi; }
do_uninstall() {
  if has_systemd; then
    systemctl disable --now cf-ddns.timer >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/cf-ddns.service /etc/systemd/system/cf-ddns.timer
    systemctl daemon-reload
  fi
  (crontab -l 2>/dev/null | grep -v cf-ddns.sh || true) | crontab - 2>/dev/null || true
  rm -rf "$BIN" "$CONF_DIR" "$STATE_DIR" /var/log/cf-ddns.log
  green "✔ 已卸载（Cloudflare 上的 DNS 记录不受影响）"
}

menu() {
  echo "========== cf-ddns : Cloudflare DDNS =========="
  if [[ -x $BIN ]]; then
    local last; last=$(cat $STATE_DIR/last_ipv4 2>/dev/null || echo '-')
    green "状态: 已安装    上次记录 IP: $last"
  else
    yellow "状态: 未安装"
  fi
  echo " 1) 安装 / 重新配置"
  echo " 2) 更新脚本"
  echo " 3) 检查状态"
  echo " 4) 查看日志"
  echo " 5) 卸载"
  echo " 0) 退出"
  local c; ask c "请选择" "1"
  case "$c" in
    1) do_install ;; 2) do_update ;; 3) do_check ;; 4) do_log ;; 5) do_uninstall ;; *) exit 0 ;;
  esac
}

cmd=${1:-}
[[ $# -gt 0 ]] && shift
case "$cmd" in
  install)   do_install "$@" ;;
  update)    do_update ;;
  check)     do_check ;;
  log)       do_log ;;
  uninstall) do_uninstall ;;
  "")        menu ;;
  *)         die "未知命令: $cmd（可用: install update check log uninstall）" ;;
esac
