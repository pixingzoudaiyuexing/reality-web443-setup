# REALITY + 网站 HTTPS 复用脚本（支持非 443 端口）

这是一个交互式 Bash 脚本，将已有网站服务作为 REALITY 的 HTTPS 回落站点。支持 REALITY 监听 **443 或自定义 TCP 端口**（例如 2053、2083、8443）。

典型场景：

- REALITY/VLESS 节点监听公网 `443`、`2053` 或其他合法 TCP 端口。
- 网站程序运行在本机 HTTP 端口，例如 OpenList 的 `5244`。
- 网站通过 REALITY 对指定 SNI 的回落，在相同端口提供 HTTPS 访问。

脚本会：

- 安装 Nginx、Certbot、iptables 等基础工具。
- 为输入的域名申请 Let's Encrypt 证书（**HTTP-01 仍需要公网 TCP 80 可达**）。
- 创建本机 HTTPS 回落反代，例如 `127.0.0.1:8443 -> 127.0.0.1:5244`。
- 安装证书续期后自动重载 Nginx 的 hook。
- 可选创建 NAT 兼容转发，匹配用户填写的 **REALITY 实际监听端口**，而非固定 443。
- 重复运行时更新同域名的 NAT 服务；不启用 NAT 时清理同域名以前创建的 NAT 服务。

## 一键运行

```bash
wget -O reality-web443-setup.sh https://raw.githubusercontent.com/pixingzoudaiyuexing/reality-web443-setup/main/reality-web443-setup.sh && bash reality-web443-setup.sh
```

如正在试用尚未合并的分支，将上面 URL 中的 `main` 改为对应分支名。

如果旧 Debian 系统提示 `bullseye-backports Release file` 等 APT 源错误，脚本会自动备份并禁用检测到的失效 backports 源。

按提示输入：

- 网站域名，例如 `op.example.com`
- 网页后端 HTTP 端口，例如 `5244`
- 内部 HTTPS 回落端口，例如 `8443`
- **REALITY 实际监听的公网端口，默认 `443`**
- 公网 IPv4 和证书邮箱
- 是否需要 NAT 兼容转发及证书续期测试

## 面板推荐设置（无需 NAT）

以下两种外部端口均适用；回落端口 **不应与 REALITY 监听端口相同**。

```text
Server Name (SNI): op.example.com
Server Address:    127.0.0.1
Server Port:       8443
Proxy Protocol:    0
```

| 情况 | REALITY 公网监听端口 | 客户端端口 | 浏览器访问回落网站 |
|---|---:|---:|---|
| 默认 443 | 443 | 443 | `https://op.example.com` |
| 自定义 2053 | 2053 | 2053 | `https://op.example.com:2053` |

**注意：**REALITY 节点必须实际监听对应 TCP 端口，并把指定 SNI 的 HTTPS 回落流量转到 `127.0.0.1:8443`。脚本只配置网站/Nginx/可选 NAT，不修改 REALITY/Xray/v2node 的监听端口。云厂商安全组和服务器防火墙也需放行该公网 TCP 端口。

自定义端口不等于占用了标准 HTTPS 443；若无其他 HTTPS 服务在公网 443 上监听，直接访问 `https://op.example.com` 不会自动转到 `2053`。

## NAT 兼容转发

如果面板的回落目标仍是 `op.example.com:2053`（而不是推荐的 `127.0.0.1:8443`），节点可能从服务器内部访问自身公网 IP。可选 NAT 转发会将服务器本机发往 `公网IPv4:2053` 的 TCP 流量重定向到内部 HTTPS 端口 `8443`。

- NAT 规则只影响本机发起的、目标为指定公网 IPv4 和指定 TCP 端口的连接，不负责公网入口转发。
- 如果已经在面板里配置 `127.0.0.1:8443`，通常无需启用 NAT。
- 同一域名重复执行脚本并变更端口/IP 时，会先停止旧 NAT 服务再安装新规则；选择不启用时会清理以前由本脚本为该域名创建的 NAT 服务。
- NAT 当前只支持 **IPv4**。

## 证书续期

脚本使用 Certbot standalone HTTP-01 验证首次申请证书，并启用 `certbot.timer`。请保持域名解析和公网 TCP `80` 可用，供证书申请与续期使用。REALITY 是否使用 443 **不影响** HTTP-01 的 TCP 80 要求。

## 开发验证

```bash
bash -n reality-web443-setup.sh
bash tests/test_ports.sh
```

测试仅校验参数、端口提示及生成的 NAT unit 文本，不会在服务器上安装软件或配置真实 NAT。
