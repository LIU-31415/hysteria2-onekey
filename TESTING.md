# 真实 VPS 验收清单

本清单以 Debian 12 为主要基准，建议在可重置的全新 VPS 快照上测试。下面的最后一步会卸载 Hysteria，请不要在已有重要节点上直接执行完整清单。

## 1. 安装前

- 云安全组放行 `UDP 443`，并按验证方式放行 `TCP 443` 或 `TCP 80`；已有 webroot 订单需要网站的 `TCP 80`；
- 确认系统时间正确；
- 确认系统为 Debian 12，且没有未备份的现有 Hysteria 配置；
- 记录安装前状态：

```bash
cat /etc/debian_version
timedatectl status
id hysteria 2>/dev/null || true
command -v hysteria || true
systemctl is-enabled hysteria-server.service 2>/dev/null || true
crontab -l 2>/dev/null || true
```

## 2. 全自动安装

```bash
curl -fL https://raw.githubusercontent.com/LIU-31415/hysteria2-onekey/master/hysteria.sh -o hysteria.sh
sudo bash hysteria.sh --install
sudo hy2 --diagnose
```

验收条件：

- `hysteria-server.service` 为 `active`；
- 诊断没有 `[FAIL]`；
- 诊断显示内核版本不低于安全下限 `2.9.2`；
- `/root/hy/url.txt`、`hy-client.yaml`、`hy-client-tun.yaml` 均存在且权限为 `600`；
- `/etc/hysteria/server.key` 权限不是全局可读；
- 可信证书模式下存在 acme.sh 续期条目；自签名回退模式下链接和 YAML 均包含 `pinSHA256`。
- 诊断能识别带引号路径的 acme.sh cron 条目（v2.0.2+），且 cron 服务处于运行状态。
- 被注释的任务、其他目录下的 acme.sh 或 `--home` 指向其他目录的任务不应被识别为当前证书的续期任务。
- UDP 443 已被其他服务占用时，应在创建事务、安装内核或申请证书前停止；已有节点使用自己的端口修改配置时不应被误报。
- 脚本不会修改本机防火墙；云安全组和已有本机防火墙必须由你自行放行端口。

```bash
stat -c '%a %U:%G %n' /etc/hysteria/config.yaml /etc/hysteria/server.key /root/hy/*
systemctl status hysteria-server.service --no-pager
systemctl is-active cron.service
journalctl -u hysteria-server.service -n 50 --no-pager
```

## 3. 客户端与 TUN

1. 先导入 `/root/hy/url.txt`，验证普通代理可以访问 TCP 和 UDP 目标；
2. 再以管理员权限使用 `/root/hy/hy-client-tun.yaml`；
3. 确认 TUN 配置中的 `ipv4Exclude`/`ipv6Exclude` 包含服务器公网 IP；
4. 验证网页、DNS、长连接和 UDP 应用；
5. 切换网络后再次测试，排除单一运营商封锁 UDP 的影响。

另做一次自定义地址测试：让客户端连接 IP 与脚本检测的公网 IP 不同，例如 IPv4 公网 IP 配合另一条公网 IPv6。两者都应进入对应排除列表，`hy2 --diagnose` 应能发现遗漏的连接 IP。域名模式下核对客户端实际解析结果与排除列表一致。

macOS 测试前把 `tun.name` 改成 `utun` 加数字，例如 `utun123`。

如果普通代理成功、只有第三方客户端 TUN 失败，重点核对客户端导入后是否保留 `SNI`、`insecure` 和 `pinSHA256`。可信 IP 证书模式不应开启 `insecure`。

v2.0.6 起，导入外部 Ed25519 证书及诊断时应显示客户端兼容性提醒；ECDSA/RSA 叶证书不应触发该提醒。导入证书仍须通过信任链、SAN、有效期和私钥匹配检查。官方客户端默认 Chrome QUIC 指纹模拟不支持 Ed25519 服务端证书，建议采用 ECDSA/RSA 证书完成连通性验收。

## 3.1. 内核更新

在测试 VPS 上记录 `hysteria version` 和当前服务状态，然后运行 `hy2`、选择菜单 `6`。这一步会下载官方内核并重启服务，连接会短暂中断。

验收条件：

- 更新后的内核版本可识别且达到安全下限；确认实际版本与当时官方稳定版一致，不能仅凭达到 `2.9.2` 判定为最新版本；
- 服务恢复运行，`hy2 --diagnose` 没有 `[FAIL]`；
- 客户端的普通代理、UDP 应用及 TUN 均可连接；服务器更新不会更新第三方客户端内核；
- 更新失败时检查原内核及服务是否恢复；回滚不完整时按提示保留的快照路径处理。

## 4. 重装与失败回滚

先再次执行安装命令，确认它不会轮换现有密码：

```bash
sudo bash hysteria.sh --install
```

然后明确重装：

```bash
sudo hy2 --reinstall
sudo hy2 --diagnose
```

验收条件：

- 已有可用内核不会被隐式升级；
- 低于 `2.9.2` 的旧内核会被拒绝；
- 密码和客户端文件更新；
- 服务保持运行；
- 配置备份最多保留 3 份。

回滚测试可在菜单 `2` 中选择“现有系统可信证书”，故意提供不匹配的证书/私钥。操作应失败，原服务状态、配置和客户端文件应保持不变。

短期 IP 证书应确认 acme.sh 不低于 `3.1.4`。至少观察一次自动续期：证书到期时间向后延长，目标证书和私钥仍为 `root:hysteria 640`，客户端可重新握手。仅有 cron 条目或首次签发成功不足以确认续期正常。已有旧版 acme.sh 时，脚本应提示版本要求并保留该客户端；不要为了测试降级生产机器上的 ACME 客户端。

### 4.1. 已有 webroot 订单与共享 ACME

在测试 VPS 上先配置可用的 nginx HTTP-01/webroot 订单，证书和私钥部署到 Hysteria 的托管路径；另保留一张供其他服务使用的证书。记录验证目录、部署路径、短期证书参数、部署钩子和两张证书的当前状态。

验收条件：

- 旧 Hy2 状态仍写着验证端口 `443` 时，新脚本应识别订单中的 webroot，显示实际目录和 `TCP 80`；只读查看不应重写安装状态；
- nginx 监听 `TCP 80`、另一个服务监听 `TCP 443` 时，webroot 诊断应成功，不提示网站服务占用了独立验证端口；
- 诊断完成或 HTTP 请求失败后，验证目录里不应残留 `hy2-check.*` 文件；
- 修改节点 UDP 端口时复用有效证书，原验证目录、短期证书参数、部署路径和钩子不变；
- 在测试环境触发证书重新部署时，沿用原订单续期；验证路径失效时报告失败、恢复原节点配置，不自动改成自签名证书；
- 选择已经部署到其他服务路径的订单时，应拒绝接管，不改变其他服务的证书部署路径；
- 故意使 Hy2 操作失败，并在快照之后更新另一张证书：回滚应恢复 Hy2 自己的订单，保留另一张证书和共享账号的新状态；
- 卸载 Hy2 后，原有 nginx、共享验证目录、其他证书和共享续期任务仍保留。

公网验收应实际完成一次证书机构验证和证书部署，并检查 Hysteria 是否使用新证书。单元测试中的 HTTP/ACME 模拟只能验证脚本分支和参数，不能证明公网验证条件满足。

### 4.2. 证书切换与并发操作

在测试快照上将受管 ACME 节点切换到自签名证书：旧订单应先停用，切换成功后不再向节点路径部署证书；若服务启动失败，旧证书、订单和节点配置应一起恢复。停用旧订单失败时应保留原配置。外部订单仍部署到节点路径时，应在修改服务前拒绝切换，保留其他服务的订单和证书。

在一个终端打开 `hy2` 菜单，另一个终端尝试安装、更新、诊断或卸载，应提示已有管理会话且不执行操作。退出第一个菜单后，第二个终端应能正常使用；进程退出后也不应留下无法释放的锁。`hy2 --version` 和 `hy2 --help` 不受该锁影响。自动化测试使用真实 Linux `flock`，Windows Git Bash 跳过该项时不能据此判断锁已经验收。

## 5. 安全卸载

```bash
sudo hy2 --uninstall
```

输入 `UNINSTALL` 后检查：

```bash
test ! -e /etc/hysteria
test ! -e /root/hy
test ! -e /usr/bin/hy2
test ! -e /usr/local/bin/hysteria
test ! -e /etc/systemd/system/hysteria-server.service
test ! -e /etc/systemd/system/hysteria-server@.service
```

如果安装前已经存在 `hysteria` 用户、acme.sh 或同名 ACME 证书订单，脚本会保留它们；如果 acme.sh 和证书订单均由脚本首次创建且没有其他 ACME 证书，则应一并清理。云平台安全组不会自动删除，需要按需手动收回端口。

在测试快照上验证部分卸载：中断后安装状态应保留，重新运行 `--uninstall` 即使配置已经删除也能继续；安装和更新应拒绝覆盖未完成的卸载。遇到删除或 ACME 查询失败时，应报告失败并保留相关资源，不应显示“卸载完成”。

另保留其他服务的 ACME 订单，使共享客户端继续存在；在 Hy2 订单已经移除之后模拟后续清理失败，再次卸载应能完成，不因重复移除订单而停住。无论重试多少次，其他证书及续期任务都应保留。
