# Hysteria 2 小白一键安装脚本

面向个人 Linux VPS：下载后按一次 Enter，即可完成 Hysteria 2 安装、优先申请可信证书、生成随机密码和客户端配置。

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

- UDP `443`，Hysteria 的默认 HTTP/3 端口；
- 自动生成独立的认证密码和 Salamander 混淆密码；
- 优先申请 Let's Encrypt 短期公网 IP 证书，无需域名；
- 证书申请失败时自动回退到“自签名证书 + SHA-256 指纹固定”；
- 使用 Hysteria 默认的 BBR 拥塞控制，不填写容易适得其反的虚假带宽；这里不是修改 Linux 内核 BBR；
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

该 TUN 文件可直接用于 Windows 和 Linux。macOS 要求接口名采用 `utun数字`，请把其中的 `tun.name` 改成例如 `utun123`。

对于 v2rayN、NekoBox、Clash Meta 等第三方客户端，优先导入 `url.txt` 中的链接。可信 IP/域名证书模式使用正常系统信任链，兼容性最好。

如果安装结果显示使用了自签名证书：

- 不要删除分享链接或 YAML 中的 `pinSHA256`；
- 某些 v2rayN 版本导入链接时可能丢失证书指纹，建议使用生成的 YAML，或在客户端中确认已保留该字段；
- `insecure: true` 只是兼容自签名握手，真正限制服务器身份的是证书指纹。

### 外部证书兼容性

官方 Hysteria 客户端从 `2.11.0` 起默认启用 Chrome QUIC 指纹模拟。当前官方文档说明，该默认握手不支持 Ed25519 服务端证书；建议使用 ECDSA 或 RSA 证书。脚本默认申请 ECDSA 证书，自签名回退使用 RSA，均符合这一要求。

v2.0.6 起，导入外部证书和执行诊断时会检查叶证书的公钥算法，发现 Ed25519 时给出兼容性提醒。这项提醒不代表证书本身无效；导入仍须通过信任链、SAN、有效期及私钥匹配检查。遇到这类握手失败时，优先重新导入 ECDSA/RSA 证书，并保持原有证书验证设置。第三方客户端需按其实际内核核对兼容性。

依据：[官方客户端 QUIC 参数与证书兼容说明](https://v2.hysteria.network/docs/advanced/Full-Client-Config/#quic-parameters)。

## 管理命令

安装后可随时运行：

```bash
hy2
```

菜单功能：

1. 一键安装；已有安装从 GitHub 更新管理脚本，不修改服务配置；
2. 自定义安装/修改端口、密码和证书；
3. 查看配置和分享链接；
4. 重新生成客户端配置；
5. 启停、重启、查看日志；
6. 一键诊断；
7. 更新 Hysteria 内核；
8. 安全卸载；
9. 从 GitHub 更新管理脚本。

从 v2.0.7 起，已安装节点可选择菜单 `1`、`9`，或执行 `sudo hy2 --update-script`，从本仓库 `master` 分支更新管理脚本。更新检查 HTTPS 下载、Bash 语法和版本号，仅接受更高版本，并通过原子替换刷新 `/usr/bin/hy2`；下载、校验或替换失败时保留旧脚本。节点配置、密码、证书和内核保持不变，服务不会重启。菜单更新完成后退出，再运行 `hy2` 使用新版。

更新功能只在明确选择上述入口时联网，不会在每次启动时自动替换脚本。它信任本 GitHub 仓库及 HTTPS 传输；语法和版本检查不等同于代码签名认证。安装或更新 Hysteria 内核、安装 acme.sh 时，脚本会下载并执行对应项目的官方安装器。

v2.0.6 及更早版本需要先使用页面顶部的一键安装命令刷新一次管理脚本，才能获得联网更新入口。

非交互命令：

```bash
hy2 --diagnose
hy2 --update-script
hy2 --reinstall
hy2 --uninstall
hy2 --version
```

重复执行 `bash hysteria.sh --install` 只将当前下载的脚本安装为管理命令并保留现有配置；它不会再次下载 GitHub 版本。联网更新使用菜单 `1`、`9` 或 `--update-script`。只有明确执行 `--reinstall` 才会轮换认证密码、混淆密码和客户端配置。

### 内核与客户端更新

`2.9.2` 是脚本要求的最低安全版本，不是固定安装版本，也不表示已经更新到最新稳定版。首次安装没有现有内核时，以及选择菜单 `7` 时，脚本调用官方安装器安装当前发布渠道版本；已有安装或修改配置时保留达到安全下限的内核。

截至 **2026-10-03**，官方最新稳定版为 **2.12.3**。若正在使用 `2.11.0`，建议优先更新：该版本引入的小 MTU 路径下 BBR 崩溃问题已在 `2.12.0` 修复。`2.12.3` 还修复了 HTTP 代理传输和端口跳跃规则的问题；具体适用范围见[官方变更记录](https://v2.hysteria.network/docs/Changelog/)。

已有节点按以下顺序更新：

1. 在 VPS 执行 `hysteria version` 和 `hy2 --diagnose`，确认服务器内核版本、服务和证书状态；单独查看客户端的实际内核版本。
2. 运行 `hy2` 并选择菜单 `7`。更新会创建事务快照并重启服务，连接会短暂中断；内核安装、服务重启或运行状态检查失败时，脚本尝试恢复原内核与服务，回滚不完整时保留快照并提示人工恢复路径。
3. 更新后再次查看版本和诊断结果，再从客户端验证普通代理、UDP 应用及 TUN。服务运行检查只能确认 VPS 本机状态，客户端连通性需实际验证。
4. 官方原生客户端使用官方稳定版更新；v2rayN、NekoBox、Clash Meta 等第三方客户端按各自发布说明更新实际使用的内核。

Chrome QUIC 指纹模拟属于官方客户端的能力。更新服务器不会替第三方客户端启用这一能力，也不会更新客户端内核。客户端更新后应核对导入的 `SNI`、混淆密码及证书验证参数。

## 从旧版升级

v1 与 v2 的安装目录相同（`/etc/hysteria`、`/root/hy`），但 v2 使用独立的安装状态文件做安全校验，**在旧版残留未清理时不会接管**。升级步骤：

1. 先卸载旧版：运行旧版菜单选择卸载（旧版会清理自己创建的 iptables 规则）；
2. 确认 `/etc/hysteria`、`/root/hy`、`/usr/bin/hy2` 已清空；
3. 再按上方「一键安装」执行。

v1 内置的「更新脚本」菜单无法用于升级：它要求下载脚本以 `#!/bin/bash` 开头，而 v2 使用 `#!/usr/bin/env bash`，会被误判为无效文件。请直接下载新版本并人工核对。

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
- 公网 IP ACME、域名 ACME、一次性导入现有系统可信证书和自签名证书；
- 自定义认证密码与混淆密码。

为保持简单、安全且完全不操作防火墙，脚本只支持单 UDP 端口，默认使用 `443`。

## 安全与残留范围

- 修改配置前创建事务快照；服务启动失败或按 `Ctrl+C` 时自动回滚；回滚不完整时保留快照并显示人工恢复路径；
- 重装或修改配置不会隐式升级达到安全下限的内核；低于 `2.9.2` 时拒绝继续，内核更新由菜单 `7` 明确触发；
- 首次运行前已存在的外部 Hysteria 内核不会在卸载时被误删；没有本脚本状态文件时拒绝执行卸载；
- 检测到未被本脚本记录的现有配置、服务或客户端目录时拒绝覆盖；卸载时保留目录里的未知文件；
- 配置先写临时文件，再原子替换；仅保留最近 3 份配置备份；
- 私钥不会被改成全局可读；现有证书会复制到专用目录，但不会跟随源文件自动续期，更新后需要重新导入；
- 安装、修改、回滚和卸载均不会调用 UFW、firewalld、iptables 或 nftables；
- 不使用模糊的 `/etc/crontab` 文本删除；ACME 续期由 acme.sh 自己管理，诊断会检查证书订单、定时任务和 cron 服务；
- 单独记录 ACME 证书订单所有权；旧状态或外部订单默认保留；卸载必须输入 `UNINSTALL`，也不会修改云平台安全组。

## Windows 开发检查

项目是 Linux Bash 脚本。Windows 本机没有 Bash/ShellCheck 时，推荐使用 WSL：

先在 Windows PowerShell 运行仓库自带的基础检查：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\static-check.ps1
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
- [Hysteria 2 正式版本与安全更新](https://github.com/HyNetworks/hysteria/releases)
- [acme.sh 官方项目与续期说明](https://github.com/acmesh-official/acme.sh)
- [Let's Encrypt：IP 地址证书正式可用](https://letsencrypt.org/2026/01/15/6day-and-ip-general-availability.html)

## 当前验证状态

已提供 Bash 语法、ShellCheck 和纯函数/配置生成测试。真实 VPS 上的证书签发、systemd、客户端导入及 TUN 连通性必须在实际 Linux 服务器与客户端网络中验证。

完整实机步骤见 [TESTING.md](TESTING.md)。
