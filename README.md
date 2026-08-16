# Hysteria 2 小白一键安装脚本

面向个人 Linux VPS：下载后按一次 Enter，即可完成 Hysteria 2 安装、可信证书、随机密码和客户端配置。

## 一键安装

使用 `root` 登录 VPS，粘贴下面一行并按 Enter：

```bash
curl -fL https://raw.githubusercontent.com/LIU-31415/hysteria2-onekey/master/hysteria.sh -o hysteria.sh && sudo bash hysteria.sh --install
```

整行粘贴后只需按一次 Enter，后续不再询问配置。若需要自定义端口、密码或证书，再执行下面的菜单命令：

```bash
sudo bash hysteria.sh
```

默认配置：

- UDP `443`，Hysteria 官方推荐的默认端口；
- 自动生成独立的认证密码和 Salamander 混淆密码；
- 优先申请 Let's Encrypt 短期公网 IP 证书，无需域名；
- 证书申请失败时自动回退到“自签名证书 + SHA-256 指纹固定”；
- 使用内核默认的 BBR 拥塞控制，不填写容易适得其反的虚假带宽；
- 开启协议嗅探，改善 TUN 场景中的域名处理；
- 自动生成 SOCKS5、原生 TUN 和标准 `hysteria2://` 分享链接。

## 安装前只需确认

- VPS 使用带 `systemd` 和 OpenSSL 1.1.1+、仍在官方支持期内的系统；推荐 Debian 12+、Ubuntu 22.04 LTS+、Rocky/Alma/RHEL 8+、CentOS Stream 9+ 或当前受支持的 Fedora，不要使用已停止维护的 CentOS 7；
- VPS 有可从公网直接访问的 IPv4 或 IPv6；
- 云平台安全组放行 `UDP 443`；
- 为自动申请/续期证书，再放行 `TCP 443`。如果 TCP 443 已被其他程序占用，脚本会改用 `TCP 80` 并在结果中提示。

脚本不会读取、添加或删除任何本机防火墙规则，也无法替你修改云厂商安全组。请自行放行所需端口；大多数“服务正常但客户端超时”都与云安全组、本机防火墙或上游 UDP 限制有关。

## 客户端文件

安装完成后生成：

```text
/root/hy/url.txt             标准分享链接
/root/hy/hy-client.yaml      官方客户端 SOCKS5 配置
/root/hy/hy-client-tun.yaml  官方客户端原生 TUN 配置
```

原生 TUN 配置会自动把服务器公网 IP 加入 `ipv4Exclude` 或 `ipv6Exclude`，避免连接服务器本身的流量再次进入 TUN，形成代理回环。

对于 v2rayN、NekoBox、Clash Meta 等第三方客户端，优先导入 `url.txt` 中的链接。可信 IP/域名证书模式使用正常系统信任链，兼容性最好。

如果安装结果显示使用了自签名证书：

- 不要删除分享链接或 YAML 中的 `pinSHA256`；
- 某些 v2rayN 版本导入链接时可能丢失证书指纹，建议使用生成的 YAML，或在客户端中确认已保留该字段；
- `insecure: true` 只是兼容自签名握手，真正限制服务器身份的是证书指纹。

## 管理命令

安装后可随时运行：

```bash
hy2
```

菜单功能：

1. 一键安装/重装；
2. 自定义安装/修改端口、密码和证书；
3. 查看配置和分享链接；
4. 重新生成客户端配置；
5. 启停、重启、查看日志；
6. 一键诊断；
7. 更新 Hysteria 内核；
8. 安全卸载。

脚本不提供从远程 `master` 分支直接覆盖本机管理脚本的自更新入口，避免未经独立签名验证的远程代码以 `root` 权限安装。需要升级脚本时，请从可信来源重新下载并人工核对变更。

非交互命令：

```bash
hy2 --diagnose
hy2 --reinstall
hy2 --uninstall
hy2 --version
```

## TUN 连不上时

先在 VPS 执行：

```bash
hy2 --diagnose
```

然后按顺序检查：

1. 云安全组是否放行安装结果显示的 UDP 端口；
2. 普通代理模式能否连接；
3. 客户端是否以管理员权限启动 TUN；
4. 客户端导入后，`SNI`、`obfs-password`、`insecure` 和 `pinSHA256` 是否被保留；
5. 原生 TUN 配置是否包含服务器 IP 的 `ipv4Exclude`/`ipv6Exclude`；
6. 当前网络是否直接封锁或严重限速 UDP/QUIC。

服务日志：

```bash
journalctl -u hysteria-server.service -n 100 --no-pager
```

## 自定义安装

菜单 `2` 支持：

- 单 UDP 端口；
- 公网 IP ACME、域名 ACME、现有系统可信证书和自签名证书；
- 自定义认证密码与混淆密码。

为保持简单、安全且完全不操作防火墙，脚本只支持单 UDP 端口，默认使用 `443`。

## 安全与残留范围

- 修改配置前创建事务快照；服务启动失败或按 `Ctrl+C` 时自动回滚；
- 重装或修改配置不会隐式升级已可用的内核，内核更新必须由菜单 `7` 明确触发；
- 首次运行前已存在的外部 Hysteria 内核不会在卸载时被误删；没有本脚本状态文件时拒绝执行卸载；
- 检测到未被本脚本记录的现有配置、服务或客户端目录时拒绝覆盖；卸载时保留目录里的未知文件；
- 配置先写临时文件，再原子替换；仅保留最近 3 份配置备份；
- 私钥不会被改成全局可读，现有证书会复制到专用目录；
- 安装、修改、回滚和卸载均不会调用 UFW、firewalld、iptables 或 nftables；
- 不使用模糊的 `/etc/crontab` 文本删除；ACME 续期由 acme.sh 自己管理；
- 卸载必须输入 `UNINSTALL`，不会删除其他 ACME 证书，也不会修改云平台安全组。

## Windows 开发检查

项目是 Linux Bash 脚本。Windows 本机没有 Bash/ShellCheck 时，推荐使用 WSL：

先在 Windows PowerShell 运行仓库自带的基础检查：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\static-check.ps1
```

完整语法、ShellCheck 和单元测试使用 WSL：

```powershell
wsl --install -d Ubuntu
```

重启并进入 Ubuntu 后：

```bash
sudo apt update
sudo apt install -y shellcheck
cd /mnt/c/你的项目路径
bash -n hysteria.sh tests/test.sh
shellcheck --severity=warning hysteria.sh tests/test.sh
bash tests/test.sh
```

仓库中的 GitHub Actions 也会在 Ubuntu 上自动执行上述语法检查、ShellCheck 和单元测试。Windows 编辑器请保留 `.sh` 的 LF 换行；仓库已通过 `.gitattributes` 强制此规则。

## 设计依据

- [Hysteria 2 完整服务端配置](https://v2.hysteria.network/docs/advanced/Full-Server-Config/)
- [Hysteria 2 完整客户端配置](https://v2.hysteria.network/docs/advanced/Full-Client-Config/)
- [Hysteria 2 URI 规范](https://v2.hysteria.network/docs/developers/URI-Scheme/)
- [Let's Encrypt：IP 地址证书正式可用](https://letsencrypt.org/2026/01/15/6day-and-ip-general-availability.html)

## 当前验证状态

已提供 Bash 语法、ShellCheck 和纯函数/配置生成测试。真实 VPS 上的证书签发、systemd、客户端导入及 TUN 连通性必须在实际 Linux 服务器与客户端网络中验证。

完整实机步骤见 [TESTING.md](TESTING.md)。
