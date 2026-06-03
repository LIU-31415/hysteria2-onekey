# Hysteria 2 一键安装脚本

Hysteria 2 服务端一键安装/管理脚本，适用于 Linux VPS（Debian/Ubuntu/CentOS）。

## 快速开始

### 方式一：一键安装（推荐）

SSH 登录 VPS 后，直接运行以下命令即可：

```bash
# 使用 curl
bash <(curl -sL https://raw.githubusercontent.com/LIU-31415/hysteria2-onekey/master/hysteria.sh)

# 或使用 wget
bash <(wget -qO- https://raw.githubusercontent.com/LIU-31415/hysteria2-onekey/master/hysteria.sh)
```

运行后自动进入管理菜单，输入 `1` 按提示完成安装即可。

> 💡 **已安装过？** 想覆盖重装可以跳过菜单，一步到位：
> ```bash
> bash <(curl -sL https://raw.githubusercontent.com/LIU-31415/hysteria2-onekey/master/hysteria.sh) --reinstall
> ```

### 方式二：手动下载安装

想先审查脚本内容，或需要离线安装时使用：

```bash
# 下载脚本
wget https://raw.githubusercontent.com/LIU-31415/hysteria2-onekey/master/hysteria.sh

# 或从 Releases 下载最新版
# wget https://github.com/LIU-31415/hysteria2-onekey/releases/latest/download/hysteria.sh

# 赋予执行权限并运行
chmod +x hysteria.sh
bash hysteria.sh
```

### 管理菜单

```
输入 1 → 安装（按提示选择配置）
输入 2 → 卸载（带确认保护）
输入 3 → 启动/停止/重启服务
输入 4 → 修改配置
输入 5 → 查看客户端配置和分享链接
输入 6 → 更新脚本（从 GitHub 拉取最新版）
```

安装完成后直接输入 `hy2` 即可再次调出管理菜单。

#### 修改配置（选项 4）子菜单

```
1. 修改端口     ← 可随时切换单端口/端口跳跃模式
2. 修改密码
3. 修改证书类型
4. 修改伪装形式
5. 编辑带宽限速
```

> 修改端口会停止服务 → 重新走端口配置流程（选模式 + 填端口）→ 自动重启生效，无需手动操作。

## 配置说明

| 配置项 | 默认值 | 说明 |
|--------|--------|------|
| 证书 | 自签证书（伪装必应） | 无域名也能用，TLS 加密完整 |
| 端口 | 443 | 伪装成标准 HTTPS/QUIC 流量 |
| 伪装 | String 403 Forbidden | 模拟 Nginx 拒绝访问，性能最优 |
| 带宽 | 不限制（客户端自控） | 服务端不限速，客户端设置多少跑多少 |
| 拥塞控制 | BBR（standard） | Hysteria 2 默认值，无需额外配置 |

### 证书

- **自签证书（默认）**：无需域名，TLS 加密不受影响，客户端设置 `insecure: true`
- **ACME 自动申请**：需域名，脚本自动申请 Let's Encrypt 证书
- **已有证书文件**：手动指定 crt/key 路径

### 端口

- **单端口模式（推荐）**：默认 443，流量伪装为普通 HTTPS
- **端口跳跃模式**：多端口间切换，对抗运营商 QoS 限速

### 带宽

**服务端不设限速，由客户端自己控制。** 这是社区最推荐的个人使用方式。

客户端配置示例（根据实际网速调整）：

```yaml
bandwidth:
  up: 30 mbps      # 实际上行的 70-80%
  down: 100 mbps   # 实际下行的 70-80%
```

> ⚠️ 带宽值**绝对不能高于 VPS 实际能跑的上限**，否则 Brutal 算法会拼命发包补偿丢包，反而又慢又卡。

## v2rayN 客户端导入

安装完成后脚本会输出 `hysteria2://` 开头的分享链接，复制后在 v2rayN 中：

```
服务器 → 从剪贴板导入 URL
```

或者查看 `/root/hy/url.txt` 文件获取链接。

## 常见问题

### Q：自签证书安全吗？

TLS 加密完整，和正规 HTTPS 站点的加密强度一样。区别仅在于缺少 CA 签名验证——对科学上网场景来说足够安全。

### Q：不设带宽限速会不会把 VPS 跑满？

不会。**客户端设多少跑多少**，如果你在客户端设 `down: 100 mbps`，最高就跑到 100。VPS 是自用的，你自己控制客户端即可。

### Q：连接不上怎么办？

1. 检查 VPS 防火墙是否放行了 UDP 端口
2. 查看日志：`journalctl -u hysteria-server -e`
3. 确认客户端 `insecure: true`（自签证书时）

### Q：看了脚本的审核报告，有改动过吗？

基于以下开源项目改进：

- **[Misaka-blog/hysteria-install](https://github.com/Misaka-blog/hysteria-install)** — 原始脚本，核心逻辑框架
- **[Aki1106-0116/hy2-install](https://github.com/Aki1106-0116/hy2-install)** — 修复了证书申请和 URL 生成等问题的改进版

本脚本在此基础做的优化：

- 证书默认改为自签证书（无需域名）
- 端口默认 443（单端口模式优先）
- 带宽默认不限制（客户端自控）
- 安装前检测是否已存在服务
- 卸载增加确认保护，防误操作
- WARP 泄漏修复（`trap` 保证退出时恢复网络）

---

> 核心逻辑基于 [Misaka-blog](https://github.com/Misaka-blog) 与 [Aki1106-0116](https://github.com/Aki1106-0116) 的开源脚本改进，Hysteria 2 核心由 [apernet](https://github.com/apernet/hysteria) 开发
