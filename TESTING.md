# 真实 VPS 验收清单

本清单以 Debian 12 为主要基准，建议在可重置的全新 VPS 快照上测试。下面的最后一步会卸载 Hysteria，请不要在已有重要节点上直接执行完整清单。

## 1. 安装前

- 云安全组放行 `UDP 443` 和 `TCP 443`；
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
- `/root/hy/url.txt`、`hy-client.yaml`、`hy-client-tun.yaml` 均存在且权限为 `600`；
- `/etc/hysteria/server.key` 权限不是全局可读；
- 可信证书模式下存在 acme.sh 续期条目；自签名回退模式下链接和 YAML 均包含 `pinSHA256`。
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

如果普通代理成功、只有第三方客户端 TUN 失败，重点核对客户端导入后是否保留 `SNI`、`insecure` 和 `pinSHA256`。可信 IP 证书模式不应开启 `insecure`。

## 4. 重装与失败回滚

再次运行：

```bash
sudo hy2 --reinstall
sudo hy2 --diagnose
```

验收条件：

- 已有可用内核不会被隐式升级；
- 密码和客户端文件更新；
- 服务保持运行；
- 配置备份最多保留 3 份。

回滚测试可在菜单 `2` 中选择“现有系统可信证书”，故意提供不匹配的证书/私钥。操作应失败，原服务状态、配置和客户端文件应保持不变。

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

如果安装前已经存在 `hysteria` 用户或 acme.sh，脚本会保留它们；如果由脚本首次创建且没有其他 ACME 证书，则应一并清理。云平台安全组不会自动删除，需要按需手动收回端口。
