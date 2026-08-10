#!/usr/bin/env bash
set -Eeuo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { printf "${BLUE}==>${NC} %s\n" "$*"; }
ok() { printf "${GREEN}完成:${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}提示:${NC} %s\n" "$*"; }
die() { printf "${RED}错误:${NC} %s\n" "$*" >&2; exit 1; }

need_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    die "请使用 root 运行：bash $0"
  fi
}

prompt_required() {
  local var_name="$1"
  local message="$2"
  local value=""
  while [ -z "$value" ]; do
    read -r -p "$message: " value
  done
  printf -v "$var_name" '%s' "$value"
}

prompt_default() {
  local var_name="$1"
  local message="$2"
  local default_value="$3"
  local value=""
  read -r -p "$message [$default_value]: " value
  value="${value:-$default_value}"
  printf -v "$var_name" '%s' "$value"
}

prompt_yes_no() {
  local message="$1"
  local default_value="$2"
  local answer=""
  local suffix="[y/N，默认N]"
  [ "$default_value" = "y" ] && suffix="[Y/n，默认Y]"
  read -r -p "$message $suffix: " answer
  answer="${answer:-$default_value}"
  case "$answer" in
    y|Y|yes|YES|是|好|确认|1) return 0 ;;
    n|N|no|NO|否|不|取消|0) return 1 ;;
    *) [ "$default_value" = "y" ] && return 0 || return 1 ;;
  esac
}

valid_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

safe_unit_name() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9_' '-'
}

safe_nginx_var_name() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9_' '_'
}

detect_public_ip() {
  local ip=""
  ip="$(curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
  if [ -z "$ip" ]; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  fi
  printf '%s' "$ip"
}

install_packages() {
  log "正在安装 Nginx、Certbot 和基础工具"
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y nginx certbot python3-certbot-nginx curl ca-certificates iptables
  else
    die "当前脚本只支持使用 apt-get 的 Debian/Ubuntu 系统。"
  fi
}

check_domain_resolution() {
  local domain="$1"
  local public_ip="$2"
  local resolved=""
  resolved="$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ' || true)"
  if [ -z "$resolved" ]; then
    warn "这台服务器暂时解析不到 $domain，申请证书可能会失败。"
    return
  fi
  log "$domain 当前解析到：$resolved"
  if [ -n "$public_ip" ] && ! printf '%s\n' "$resolved" | grep -qw "$public_ip"; then
    warn "$domain 看起来没有解析到检测到的公网 IP：$public_ip。"
  fi
}

check_upstream() {
  local web_port="$1"
  if curl -fsS --max-time 5 "http://127.0.0.1:${web_port}/" >/dev/null 2>&1; then
    ok "后端网页 http://127.0.0.1:${web_port}/ 可以访问"
  else
    warn "后端网页 http://127.0.0.1:${web_port}/ 没有返回 2xx，脚本会继续执行。"
  fi
}

ensure_cert() {
  local domain="$1"
  local email="$2"
  local nginx_was_active="no"

  if [ -s "/etc/letsencrypt/live/${domain}/fullchain.pem" ] &&
     [ -s "/etc/letsencrypt/live/${domain}/privkey.pem" ]; then
    ok "$domain 的证书已经存在"
    return
  fi

  log "正在为 $domain 申请 Let's Encrypt 证书"
  if systemctl is-active --quiet nginx 2>/dev/null; then
    nginx_was_active="yes"
    systemctl stop nginx
  fi

  local certbot_args=(
    certonly
    --standalone
    --preferred-challenges http
    -d "$domain"
    --agree-tos
    --non-interactive
  )

  if [ -n "$email" ]; then
    certbot_args+=(--email "$email")
  else
    certbot_args+=(--register-unsafely-without-email)
  fi

  if ! certbot "${certbot_args[@]}"; then
    [ "$nginx_was_active" = "yes" ] && systemctl start nginx || true
    die "证书申请失败。请检查 $domain 是否解析到本服务器，并确认 TCP 80 端口已放行。"
  fi

  [ "$nginx_was_active" = "yes" ] && systemctl start nginx || true
  ok "$domain 的证书申请成功"
}

write_nginx_config() {
  local domain="$1"
  local web_port="$2"
  local fallback_port="$3"
  local safe_name
  local var_suffix
  local conn_var
  safe_name="$(safe_unit_name "$domain")"
  var_suffix="$(safe_nginx_var_name "${domain}_${fallback_port}")"
  conn_var="reality_connection_upgrade_${var_suffix}"

  log "正在写入 Nginx 反向代理配置"
  if [ -L /etc/nginx/sites-enabled/default ]; then
    rm -f /etc/nginx/sites-enabled/default
    ok "已禁用 Nginx 默认站点链接"
  fi

  cat >"/etc/nginx/conf.d/reality-web443-${safe_name}.conf" <<EOF
map \$http_upgrade \$${conn_var} {
    default upgrade;
    '' close;
}

server {
    listen 127.0.0.1:${fallback_port} ssl http2;
    server_name ${domain};

    ssl_certificate /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    client_max_body_size 0;

    location / {
        proxy_pass http://127.0.0.1:${web_port};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$${conn_var};
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
EOF

  nginx -t
  systemctl enable --now nginx
  systemctl reload nginx
  ok "Nginx 已在 127.0.0.1:${fallback_port} 提供 https://${domain} 的内部 HTTPS 回落服务"
}

write_renew_hook() {
  log "正在安装证书续期后的 Nginx 自动重载脚本"
  mkdir -p /etc/letsencrypt/renewal-hooks/deploy
  cat >/etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'EOF'
#!/bin/sh
systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx
EOF
  chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
  systemctl enable --now certbot.timer >/dev/null 2>&1 || true
  ok "Certbot 自动续期定时器和 Nginx 重载脚本已准备好"
}

setup_nat_redirect() {
  local public_ip="$1"
  local fallback_port="$2"
  local domain="$3"
  local safe_name
  safe_name="$(safe_unit_name "$domain")"
  local service="/etc/systemd/system/reality-web443-${safe_name}-redirect.service"

  [ -n "$public_ip" ] || die "NAT 兼容转发需要填写服务器公网 IP。"

  log "正在创建 NAT 兼容转发服务"
  cat >"$service" <<EOF
[Unit]
Description=Redirect local REALITY fallback traffic for ${domain}
After=network-online.target nginx.service docker.service v2node.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c '/usr/sbin/iptables -t nat -C OUTPUT -p tcp -d ${public_ip} --dport 443 -j REDIRECT --to-ports ${fallback_port} 2>/dev/null || /usr/sbin/iptables -t nat -A OUTPUT -p tcp -d ${public_ip} --dport 443 -j REDIRECT --to-ports ${fallback_port}'
ExecStop=/bin/sh -c '/usr/sbin/iptables -t nat -D OUTPUT -p tcp -d ${public_ip} --dport 443 -j REDIRECT --to-ports ${fallback_port} 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
EOF

  systemd-analyze verify "$service"
  systemctl daemon-reload
  systemctl enable --now "reality-web443-${safe_name}-redirect.service"
  ok "NAT 兼容转发已启用：${public_ip}:443 -> 127.0.0.1:${fallback_port}"
}

test_local_https() {
  local domain="$1"
  local fallback_port="$2"
  log "正在测试本机 HTTPS 回落后端"
  local code
  code="$(curl -k -sS -o /dev/null -w '%{http_code}' \
    --resolve "${domain}:${fallback_port}:127.0.0.1" \
    "https://${domain}:${fallback_port}/" || true)"
  if [ -n "$code" ] && [ "$code" != "000" ]; then
    ok "本机 HTTPS 回落后端返回 HTTP $code"
  else
    warn "本机 HTTPS 回落后端测试失败。可用 journalctl -u nginx -n 100 查看 Nginx 日志。"
  fi
}

print_panel_tips() {
  local domain="$1"
  local fallback_port="$2"
  local public_ip="$3"

  cat <<EOF

============================================================
面板里的“干净回落”设置：

  Server Name (SNI): ${domain}
  Server Address:    127.0.0.1
  Server Port:       ${fallback_port}
  Proxy Protocol:    0

外部客户端/节点连接信息保持不变：

  Address: ${public_ip:-你的服务器公网IP}
  Port:    443

保存面板配置并重启节点后，浏览器打开：

  https://${domain}
============================================================

EOF
}

main() {
  need_root

  echo "REALITY 443 + 网站 HTTPS 复用部署脚本"
  echo

  local domain web_port fallback_port email public_ip
  prompt_required domain "请输入网站域名，例如 op.i4ktv.top"
  prompt_default web_port "请输入后端网页 HTTP 端口，例如 OpenList 是 5244" "5244"
  valid_port "$web_port" || die "后端网页端口无效：$web_port"
  prompt_default fallback_port "请输入内部 HTTPS 回落端口" "8443"
  valid_port "$fallback_port" || die "内部 HTTPS 回落端口无效：$fallback_port"

  if [ "$web_port" = "$fallback_port" ]; then
    die "后端网页端口和内部 HTTPS 回落端口不能相同。"
  fi

  public_ip="$(detect_public_ip)"
  prompt_default public_ip "请输入服务器公网 IP，用于检查解析和可选 NAT 兼容转发" "${public_ip:-}"
  read -r -p "请输入 Let's Encrypt 邮箱，可选，直接回车跳过: " email

  install_packages
  check_domain_resolution "$domain" "$public_ip"
  check_upstream "$web_port"
  ensure_cert "$domain" "$email"
  write_nginx_config "$domain" "$web_port" "$fallback_port"
  write_renew_hook
  test_local_https "$domain" "$fallback_port"

  print_panel_tips "$domain" "$fallback_port" "$public_ip"

  if prompt_yes_no "如果你的面板里 REALITY 的 Server Address/Port 仍然是 域名:443，是否添加 NAT 兼容转发？" "n"; then
    setup_nat_redirect "$public_ip" "$fallback_port" "$domain"
  else
    warn "未添加 NAT 兼容转发。请在面板里把 Server Address/Port 设置为 127.0.0.1:${fallback_port}。"
  fi

  if prompt_yes_no "是否现在运行一次 Certbot 自动续期模拟测试？" "y"; then
    certbot renew --dry-run --cert-name "$domain"
  fi

  ok "全部完成"
}

main "$@"
