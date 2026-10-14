#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../reality-web443-setup.sh
source "$ROOT/reality-web443-setup.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
contains() { [[ "$1" == *"$2"* ]] || fail "未找到预期内容: $2"; }
not_contains() { [[ "$1" != *"$2"* ]] || fail "包含不应出现的内容: $2"; }

valid_port 443 || fail "443 应为合法端口"
valid_port 2053 || fail "2053 应为合法端口"
valid_port 65535 || fail "65535 应为合法端口"
for port in 0 65536 abc '443;echo bad'; do
  if valid_port "$port"; then fail "端口应无效: $port"; fi
done
valid_ipv4 198.51.100.5 || fail "合法 IPv4 被拒绝"
for ip in '198.51.100.999' '198.51.100.5;touch /tmp/bad' '::1' ''; do
  if valid_ipv4 "$ip"; then fail "非法 IPv4 被接受: $ip"; fi
done

default_tips="$(print_panel_tips op.example.com 8443 198.51.100.5 443)"
contains "$default_tips" 'Port:    443'
contains "$default_tips" 'https://op.example.com'
not_contains "$default_tips" 'https://op.example.com:443'

custom_tips="$(print_panel_tips op.example.com 8443 198.51.100.5 2053)"
contains "$custom_tips" 'Port:    2053'
contains "$custom_tips" 'https://op.example.com:2053'

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
write_nat_unit "$tmp" 198.51.100.5 2053 8443 op.example.com
unit="$(cat "$tmp")"
contains "$unit" '--dport 2053 -j REDIRECT --to-ports 8443'
not_contains "$unit" '--dport 443'
write_nat_unit "$tmp" 198.51.100.5 443 9443 op.example.com
unit="$(cat "$tmp")"
contains "$unit" '--dport 443 -j REDIRECT --to-ports 9443'
not_contains "$unit" '--dport 2053'

echo "PASS: 端口校验、IPv4 校验、443/2053 输出和 NAT unit 生成"
