# Hysteria 2 一键安装脚本

Hysteria 2 服务端一键安装/管理脚本，适用于 Linux VPS（Debian/Ubuntu/CentOS）。

面向新人优化：**一路回车即可完成最优配置安装**，默认开启双层加密（TLS 1.3 + Salamander 混淆），对运营商完全隐身。

## 快速开始

### 方式一：一键安装（推荐）

SSH 登录 VPS 后，直接运行以下命令即可：

```bash
# 使用 curl
bash <(curl -sL https://raw.githubusercontent.com/LIU-31415/hysteria2-onekey/master/hysteria.sh)

# 或使用 wget
bash <(wget -qO- https://raw.githubusercontent.com/LIU-31415/hysteria2-onekey/master/hysteria.sh)
```

运行后自动进入管理菜单，输入 `1` 然后一路回车即可完成安装。

> 💡 **已安装过？** 想覆盖重装可以跳过菜单，一步到位：
> ```bash
> bash <(curl -sL https://raw.githubusercontent.com/LIU-31415/hysteria2-onekey/master/hysteria.sh) --reinstall
> ```

### 方式二：手动下载安装

想先审查脚本内容，或需要离线安装时使用：

```bash
# 下载脚本
wget https://raw.githubusercontent.com/LIU-31415/hysteria2-onekey/master/hysteria.sh

# 赋予执行权限并运行
chmod +x hysteria.sh
bash hysteria.sh
```

### 管理菜单

```
输入 1 → 安装 Hysteria 2
输入 2 → 卸载 Hysteria 2
输入 3 → 启动/停止/重启服务
输入 4 → 修改配置
输入 5 → 查看客户端配置和分享链接
输入 6 → 更新 Hysteria 2 核心
输入 7 → 更新脚本（从 GitHub 拉取最新版）
```

菜单顶部会显示当前运行状态、监听端口、核心版本，一目了然。

安装完成后直接输入 `hy2` 即可再次调出管理菜单。

#### 修改配置（选项 4）子菜单

```
1. 修改端口       ← 可随时切换单端口/端口跳跃模式
2. 修改密码
3. 修改证书类型
4. 修改伪装形式
5. 编辑带宽限速
6. 修改握手域名   ← 仅自签证书，从推荐列表选或自动测速
7. 修改混淆加密   ← 传输层再加密/抗识别
```

> 修改端口会停止服务 → 重新走端口配置流程（选模式 + 填端口）→ 自动重启生效，无需手动操作。

## 一路回车的默认配置

新人无需做任何选择，一路回车即可得到以下最优配置：

| 步骤 | 提示 | 回车→默认值 | 说明 |
|------|------|------------|------|
| 1 | 证书方式 [1-3] | **1** 自签证书 | 无需域名 |
| 2 | 握手域名 | **www.cloudflare.com** | 从推荐列表选，最纯净 |
| 3 | 证书算法 [1-3] | **1** Ed25519 | 最快最安全 |
| 4 | 端口模式 [1-2] | **2** 单端口 | 推荐 |
| 5 | 端口 | **443** | 标准 HTTPS 端口 |
| 6 | 密码 | **随机生成** | 32 位强密码 |
| 7 | 伪装形式 [1-2] | **1** 403 Forbidden | 性能最优 |
| 8 | 带宽 [1-2] | **2** 不限制 | 客户端自控 |
| 9 | 混淆加密 [1-2] | **1** 开启 Salamander | 传输层再加密 |
| 10 | 混淆密钥 | **随机生成** | 32 位强密钥 |

## 配置说明

| 配置项 | 默认值 | 说明 |
|--------|--------|------|
| 证书 | 自签证书（Ed25519，SNI=cloudflare） | 无域名也能用，TLS 加密完整 |
| 端口 | 443 | 伪装成标准 HTTPS/QUIC 流量 |
| 伪装 | String 403 Forbidden | 模拟 Nginx 拒绝访问，性能最优 |
| 带宽 | 不限制（客户端自控） | 服务端不限速，客户端设置多少跑多少 |
| 拥塞控制 | BBR（standard） | Hysteria 2 默认值，无需额外配置 |
| 混淆加密 | Salamander | QUIC 包头再做一层 AES-CTR 流加密 |
| TLS | 强制 TLS 1.3 | `minVersion: tls1.3`，禁用 TLS 1.2 |
| ALPN | h3, h2, http/1.1 | 标准 HTTP/3 协商 |
| QUIC 保活 | 10s / 30s | `keepAlivePeriod` / `maxIdleTimeout` |

### 证书

- **自签证书（默认）**：无需域名，TLS 加密不受影响，客户端设置 `insecure: true`
  - 证书算法可选：Ed25519（默认，最快）、prime256v1、secp384r1
  - 握手域名（SNI）从推荐列表选，或自动测速选最优
- **ACME 自动申请**：需域名，脚本自动申请 Let's Encrypt 证书
- **已有证书文件**：手动指定 crt/key 路径

### 握手域名（SNI）选择

安装时从推荐列表选择，**所有推荐域名均为常规大站，与 AI/GitHub/Google 等敏感服务无关联**，不会暴露你真实的访问意图：

| 域名 | HTTP/3 | 说明 |
|------|--------|------|
| www.cloudflare.com | ✅ | CDN 基础设施，最纯净（默认） |
| www.apple.com | ✅ | 硬件厂商官网 |
| www.microsoft.com | ✅ | 系统厂商官网 |
| www.bing.com | ❌ | 搜索引擎，无 HTTP/3 |

> ⚠️ **切勿使用** chat.openai.com / github.com / claude.ai / *.google.com 等敏感域名做 SNI，这些是 GFW 重点监控对象，用作 SNI 反而暴露意图。

也可选 `0` 自动测速：脚本会检测各候选域名的 HTTP/3 支持和 TLS 握手延迟，自动选最优。

### 端口

- **单端口模式（推荐）**：默认 443，流量伪装为普通 HTTPS
- **端口跳跃模式**：多端口间切换，对抗运营商 QoS 限速
  - 默认范围：30000-31000（起始端口随机生成于 30000-50000，范围 ~1000 端口）
  - 默认间隔：30s（可选随机 10-60s）

**端口占用检测**：选端口前脚本会自动列出当前已占用的 UDP 端口，避免冲突。选了 TCP 也占用的端口时会软提醒（UDP/TCP 不实际冲突，可继续）。

### 混淆加密（Salamander）

在 QUIC/TLS 加密基础上，对 QUIC 包头再做一层 AES-CTR 流加密：

| 项目 | 未开启 | 开启后 |
|------|--------|--------|
| TLS 加密 | ✅ QUIC + TLS 1.3 | ✅ 不变 |
| 运营商能否识别 | 能看出是 QUIC | **完全随机 UDP 包，无法识别** |
| 被针对性 QoS/阻断 | 有风险 | 极低 |
| 性能损耗 | 无 | 可忽略 |

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

安装完成后脚本会输出 `hysteria2://` 开头的分享链接（已含 obfs 参数），复制后在 v2rayN 中：

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
4. 确认客户端 obfs 密钥与服务端一致（开启混淆时）

### Q：开启混淆加密后客户端怎么配置？

分享链接已自动带上 `&obfs=salamander&obfsParam=xxx` 参数，v2rayN/Clash 直接导入即可。手动配置时 YAML 参考：

```yaml
obfs:
  type: salamander
  salamander:
    password: 你的混淆密钥
```

### Q：如何更新 Hysteria 2 核心？

管理菜单输入 `6` → 确认更新即可。脚本会停止服务 → 拉取官方最新核心 → 重启 → 显示版本变化。

## 致谢

基于以下开源项目改进：

- **[Misaka-blog/hysteria-install](https://github.com/Misaka-blog/hysteria-install)** — 原始脚本，核心逻辑框架
- **[Aki1106-0116/hy2-install](https://github.com/Aki1106-0116/hy2-install)** — 修复了证书申请和 URL 生成等问题的改进版

本脚本在此基础做的优化：

- 一路回车即可完成最优配置（10 步全部有默认值）
- 默认开启 Salamander 混淆加密（传输层再加密，抗识别）
- 默认 Ed25519 自签证书（握手快、CPU 低、256 位安全级）
- 默认 SNI 改为 www.cloudflare.com（HTTP/3 + 最纯净 CDN）
- SNI 推荐列表 + 自动测速选最优
- 强制 TLS 1.3 + ALPN h3/h2/http/1.1 + QUIC 保活参数
- 端口占用检测（UDP/TCP 双检测，TCP 仅软提醒）
- 新增"更新 Hysteria 2 核心"菜单
- 新增"修改握手域名"、"修改混淆加密"配置项
- 修复 `local` 顶层作用域 Bug、obfs 读取 Bug、EC 算法检测 Bug 等
- 菜单显示运行状态/端口/核心版本
- realip 多源 fallback（ip.sb → ipify → ifconfig.me）
- 卸载时清理 acme.sh cron 残留
- 菜单无效输入友好提示（不再直接退出）

---

> 核心逻辑基于 [Misaka-blog](https://github.com/Misaka-blog) 与 [Aki1106-0116](https://github.com/Aki1106-0116) 的开源脚本改进，Hysteria 2 核心由 [apernet](https://github.com/apernet/hysteria) 开发
