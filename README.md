# REALITY 443 + 网站 HTTPS 复用脚本

这是一个交互式 Bash 脚本，用来把已有网站服务复用到 REALITY 节点的 443 端口上。

典型场景：

- REALITY/VLESS 节点已经占用公网 `443`
- 网站程序运行在本机 HTTP 端口，例如 OpenList 的 `5244`
- 希望浏览器访问 `https://你的域名` 时也走 `443`

脚本会自动完成：

- 安装 Nginx、Certbot、iptables 等基础工具
- 为输入的域名申请 Let's Encrypt 证书
- 创建本机 HTTPS 回落反代，例如 `127.0.0.1:8443 -> 127.0.0.1:5244`
- 安装证书续期后自动重载 Nginx 的 hook
- 可选创建 NAT 兼容转发，适合面板里暂时仍使用 `域名:443` 作为 REALITY 回落目标的情况

## 使用方法

在服务器上复制下面这一行运行：

```bash
wget -O reality-web443-setup.sh https://raw.githubusercontent.com/pixingzoudaiyuexing/reality-web443-setup/main/reality-web443-setup.sh && bash reality-web443-setup.sh
```

如果旧 Debian 系统提示 `bullseye-backports Release file` 之类的 APT 源错误，请重新运行上面这条命令拉取最新版脚本。新版脚本会自动备份并禁用失效的 backports 源。

按提示输入：

- 网站域名，例如 `op.i4ktv.top`
- 后端网页 HTTP 端口，例如 OpenList 是 `5244`
- 内部 HTTPS 回落端口，例如 `8443`
- 服务器公网 IP
- 是否添加 NAT 兼容转发
- 是否运行 Certbot 自动续期模拟测试

## 面板里的推荐设置

如果你的 REALITY 面板支持设置回落目标，推荐使用“干净回落”：

```text
Server Name (SNI): 你的域名
Server Address:    127.0.0.1
Server Port:       内部HTTPS回落端口，例如 8443
Proxy Protocol:    0
```

外部客户端连接信息保持不变：

```text
Address: 服务器公网IP或域名
Port:    443
```

## NAT 兼容转发是什么意思

如果面板里 REALITY 的回落目标仍然是：

```text
Server Address: 你的域名
Server Port:    443
```

那么节点回落网站流量时可能会访问自己，导致超时。脚本里的 NAT 兼容转发会把服务器本机访问 `公网IP:443` 的流量转到内部 HTTPS 回落端口，例如 `127.0.0.1:8443`。

如果你已经在面板里改成 `127.0.0.1:8443`，就不需要开启 NAT 兼容转发。

## 证书续期

脚本使用 Certbot 申请证书，并启用系统自带的 `certbot.timer`。证书续期成功后会自动 reload Nginx。

只要域名仍解析到服务器，并且 TCP `80` 端口能被 Let's Encrypt 访问，证书就可以自动续期。
