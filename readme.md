# Xray Reality & Hysteria 2 工业级自动化网关引擎 (Industrial Architecture Edition)

[![Linux Support](https://img.shields.io/badge/OS-Debian%2011%2B%20%7C%20Ubuntu%2020.04%2B-blue?style=flat-square&logo=linux)](https://www.debian.org/)
[![Kernel](https://img.shields.io/badge/Kernel-TCP%20BBR%20%2B%20FQ-brightgreen?style=flat-square)](https://git.kernel.org/)
[![Protocol](https://img.shields.io/badge/Protocols-VLESS--Vision--Reality%20%7C%20Hysteria2-orange?style=flat-square)](https://github.com/XTLS/Xray-core)
[![Web Server](https://img.shields.io/badge/Gateway-Nginx%20Fallback-009639?style=flat-square&logo=nginx)](https://nginx.org/)
[![License](https://img.shields.io/badge/License-MIT-lightgrey?style=flat-square)](LICENSE)

本项目是一套面向 Linux 高并发服务器深度优化的企业级代理自动化编排引擎。底层深度融合 **VLESS + XTLS-Vision + Reality** 核心，创新性实现 **Nginx 动态本地伪装回落**、**Hysteria 2 (QUIC) 单端口 TCP/UDP 协议共存**、**Systemd 内核事件驱动证书热加载** 以及 **Linux 存储配额与垃圾生命周期管理**。

项目分为两个独立工程版本：
* **`v3.0.sh` (Firewall Edition - 全自动防火墙集成版)**：内嵌跨发行版多后端（UFW / Firewalld / nftables / iptables）防火墙驱动，适用于直接暴露在公网、需要自动化网络访问控制的服务器。
* **`v3.1.sh` (Pure Edition - 纯净网络解耦版)**：剥离主机防火墙规则注入模块，与云平台外部安全组（Cloud Security Group）完全解耦，专为现代公有云拓扑与虚拟化容器环境设计。

---

## 📑 目录 (Table of Contents)

- [1. 核心流量拓扑与架构原理](#1-核心流量拓扑与架构原理)
- [2. v3.0 与 v3.1 深度比对与设计选型](#2-v30-与-v31-深度比对与设计选型)
- [3. 底层机制与系统自适应详解](#3-底层机制与系统自适应详解)
  - [3.1 Nginx 核心特性与语法动态探针](#31-nginx-核心特性与语法动态探针)
  - [3.2 操作系统版本识别与内核 BBR 调优](#32-操作系统版本识别与内核-bbr-调优)
  - [3.3 凭据生命周期与密钥持久化策略](#33-凭据生命周期与密钥持久化策略)
  - [3.4 跨模式切换的状态机与物理擦除机制](#34-跨模式切换的状态机与物理擦除机制)
  - [3.5 存储治理、日志熔断与进程安全底座](#35-存储治理日志熔断与进程安全底座)
  - [3.6 事件驱动证书热重载与规则原子更新](#36-事件驱动证书热重载与规则原子更新)
- [4. 三大部署模式特性矩阵](#4-三大部署模式特性矩阵)
- [5. 环境与端口规范](#5-环境与端口规范)
- [6. 部署与安装指南](#6-部署与安装指南)
- [7. 运维管理与生命周期控制](#7-运维管理与生命周期控制)
- [8. 常见故障排查手册 (FAQ)](#8-常见故障排查手册-faq)

---

## 1. 核心流量拓扑与架构原理

系统在单一入站公网端口（默认 `443`）上实现传输层多路复用，通过 Linux 内核 Socket 机制对 TCP 与 UDP 进行分流处理：

```text
                                  [ 公网客户端入站流量 (Port: 443) ]
                                                   │
                   ┌───────────────────────────────┴───────────────────────────────┐
                   ▼ (TCP 协议流)                                                   ▼ (UDP 协议流 - 仅模式 3)
      【 Xray-Core Gateway 】                                              【 Hysteria 2 Server 】
   VLESS + XTLS-Vision + Reality                                           QUIC 传输加速引擎 (Port: 443)
                   │                                                               │
         ┌─────────┴─────────┐                                                     │
         ▼ (通过 Reality 认证) ▼ (未携带/非法密钥探测)                                      │
   [ Freedom Direct ]   [ 透明回落 Fallback ]                                      ▼ (HTTP 伪装代理)
   规则路由出站匹配:        127.0.0.1:8443                                      Proxy: 127.0.0.1:8444
   - 广告/CN IP 阻断           │                                                           │
   - 境外公网直连放行           ▼                                                           │
                   【 Nginx 本地安全伪装站点 】 ◄──────────────────────────────────────────────┘
                    ├─► SNI 合法匹配  ──► 返回本地现代化 3D 静态站点
                    └─► 非法/未授权探测 ──► 动态触发 ssl_reject_handshake 阻断握手 (TCP RST)
```

### 流量处理核心机制：
1. **TCP/UDP 单端口复用**：操作系统在传输层根据五元组（源IP、源端口、目的IP、目的端口、传输层协议）区分会话。Xray 绑定 `0.0.0.0:443 (TCP)`，Hysteria2 绑定 `0.0.0.0:443 (UDP)`，实现单一端口对外提供双重协议通道。
2. **Reality 握手防探测验证**：客户端通过 X25519 椭圆曲线算法生成认证信息。Xray 服务端使用自身私钥与指定的 `shortId` 进行校验。通过验证则进入代理通道；若探测者直接发起扫描或使用非授权 SNI，Xray 将 TLS 连接通过内存回落至 `127.0.0.1:8443`（Nginx）。
3. **Nginx 主动防御层**：Nginx 监听本地回路地址，对非法流量实施双层过滤：域名匹配则展示逼真的 3D 伪装站点；域名不匹配或直接扫描 IP 时，由内核级 TLS 探针直接拒绝握手，阻断主动特征探测。

---

## 2. v3.0 与 v3.1 深度比对与设计选型

两个脚本在业务逻辑实现上完全同源，核心差异在于**对 Linux 系统网络过滤子系统（防火墙）的干预程度与权限边界**：

| 比对维度 | `v3.0.sh` (Firewall Edition) | `v3.1.sh` (Pure Edition) | 原理与设计影响 |
| :--- | :--- | :--- | :--- |
| **版本标识 (Layer 1)** | `v3.0-Industrial-Firewall` | `v3.1-Industrial-Pure` | 明确标识构建目标与网络治理范围。 |
| **全局上下文状态 (`CTX`)** | 包含 `[old_port]` 与 `[fw_backend]` | 移除 `old_port` 与 `fw_backend` | `v3.0` 需跟踪原端口用于平滑迁移回收；`v3.1` 保持轻量状态机。 |
| **防火墙后端自动探针** | 自动适配 UFW / Firewalld / nftables / iptables | **无任何防火墙探测** | `v3.0` 可自适应宿主机安装的防火墙服务并动态下发规则。 |
| **nftables 原生链隔离** | 独占 `inet xray_gateway` 独立命名表 | **无** | `v3.0` 使用独立表空间与 Handle 原子操作，杜绝影响宿主机其他业务规则。 |
| **双栈规则维护** | 同步操作 IPv4 (`iptables`) 与 IPv6 (`ip6tables`) | **无** | `v3.0` 确保双栈网络的入站规则保持严格对称。 |
| **端口迁移安全机制** | 检测到端口变更时，自动下发 `deny` 销毁旧端口放行 | **无** | `v3.0` 防止由于多次变更配置而在防火墙上遗留无效开放端口。 |
| **传输层协议细粒度控制** | 模式 1/2 显式阻断 UDP，模式 3 显式放行 UDP | **不干预** 任何系统传输层规则 | `v3.0` 践行网络安全最小暴露面原则。 |
| **卸载与系统回退策略** | 自动回收放行端口，物理清退 nftables 配置包含与表 | 仅注销 Systemd 服务、删除配置与二进制文件 | `v3.1` 确保卸载过程不会意外冲刷用户原本的复杂防火墙规则。 |
| **最佳部署场景** | **传统 VPS / 物理服务器 / 无外部安全组的 IDC 机器** | **AWS EC2 / Oracle Cloud / GCP / 阿里云 / 腾讯云** | `v3.1` 杜绝系统内部防火墙与云厂商 Web 控制台安全组发生规则冲突。 |

---

## 3. 底层机制与系统自适应详解

### 3.1 Nginx 核心特性与语法动态探针
为解决不同发行版软件源中 Nginx 版本跨度大（1.18 ~ 1.26+）导致的语法报错，脚本引入了**语法探针检测技术**：在临时目录生成 `/tmp/ngx_probe.conf` 并调用 `nginx -t -c` 捕获底层校验返回值。

```text
[ 安装 Nginx ] ──► [ 生成 /tmp/ngx_probe.conf ] ──► [ nginx -t 语法探测 ]
                                                            │
         ┌──────────────────────────────────────────────────┴──────────────────────────────────────────────────┐
         ▼ (Probe 1: ssl_reject_handshake 测试)                                                                 ▼ (Probe 2: http2 语法测试)
   ┌───────────┴───────────┐                                                                             ┌───────────┴───────────┐
   ▼ (返回码 0: 支持)        ▼ (返回码非 0: 不支持)                                                         ▼ (返回码 0: 现代语法)     ▼ (返回码非 0: 传统语法)
[ 启用默认 Server 握手阻断 ]   [ 略过指令，降级为常规 403 ]                                                     [ 注入独立 http2 on; 指令 ] [ 注入 listen ... http2 兼容指令 ]
```

* **`ssl_reject_handshake` 探针**：Nginx 1.19.4+ 引入的防御特性。校验通过后，脚本将在 `127.0.0.1:8443` 注入 `server_name _; ssl_reject_handshake on;`。当遭遇扫描器使用 IP 暴力探测或未携带正确 SNI 握手时，Nginx 在 TLS 握手初期直接终止会话，断开 TCP 连接，不返回任何证书，杜绝证书指纹泄露。
* **`http2` 语法兼容探针**：Nginx 1.25.1 起废弃了 `listen ... http2;` 语法，改为独立的 `http2 on;`。探针机制自适应当前环境语法，彻底杜绝跨版本部署时报 `the "http2" directive is deprecated` 或配置加载失败的缺陷。

### 3.2 操作系统版本识别与内核 BBR 调优
脚本通过解构 `/etc/os-release` 获取发行版 ID 与内核大版本号，根据 Linux 演变逻辑执行精准的配置路径注入：
* **Debian 13+ (Trixie) 路径自适应**：
  从 Debian 13 开始，官方逐步废弃向 `/etc/sysctl.conf` 直接写入全局参数的旧习惯，推荐由 `systemd-sysctl` 统一接管 `/etc/sysctl.d/*.conf`。脚本检测到系统为 Debian 13+ 时，会自动清理旧文件中的历史配置，将参数独立注入至 `/etc/sysctl.d/99-custom.conf`，并执行 `sysctl --system` 原子重载。
* **通用发行版路径**：对 Debian 11/12 及 Ubuntu，参数平滑写入 `/etc/sysctl.conf` 并调用 `sysctl -p`。
* **参数安全幂等**：注入前调用 `sed -i` 清理旧参数，随后写入：
  $$\text{net.core.default\_qdisc} = \text{fq}$$
  $$\text{net.ipv4.tcp\_congestion\_control} = \text{bbr}$$
  确保即使高延迟恶劣网络环境下仍能保持吞吐量最优。

### 3.3 凭据生命周期与密钥持久化策略
在生产运维中，更换端口或重装系统服务不应导致客户端凭据频繁失效。脚本建立了严格的凭据保护与复用规则：

```text
[ 触发配置生成 ] ──► 检测 /usr/local/etc/xray/config.json 是否存在？
                                │
               ┌────────────────┴────────────────┐
               ▼ (存在已有配置文件)                ▼ (不存在 / 初次全新安装)
      [ jq 提取 UUID / priv_key / short_id ]   [ 动态生成全新凭据 ]
      [ x25519 -i 反向推导 public_key ]        - xray uuid 生成 UUID
               │                               - openssl 生成 short_id
               │                               - x25519 生成密钥对
               └────────────────┬────────────────┘
                                ▼
                   [ 组装写入最终 config.json ]
        (结论: 节点重配/换端口时，客户端节点信息完全无需修改)
```

* **Xray Reality 凭据绝对保持**：
  配置生成模块优先调用 `jq` 读取旧配置的客户端 `id`、`privateKey` 与 `shortIds`。若私钥存在，通过 `$XRAY_BIN x25519 -i "$priv"` 反向推导出公钥。**只要服务器配置文件存在，无论是更换端口还是重新执行部署，核心认证凭据完全不变，已导出的客户端节点永久有效。**
* **Hysteria 2 密码安全轮替**：
  作为高强度对称认证协议，模式 3 部署时会通过 `openssl rand -hex 16` 为 Hysteria 2 重新生成 32 位的强随机密码，降低长期未维护带来的凭据泄露风险。
* **ECC 证书智能复用与频次保护**：
  执行证书申请前，优先校验 `/etc/nginx/ssl/${domain}_ecc.cer` 是否存在且文件大小非空。若有效则直接挂载至 Nginx，避免重复向 Let's Encrypt 发起签发请求，规避每周 5 次的申请频率限制（Rate Limit）。

### 3.4 跨模式切换的状态机与物理擦除机制
脚本内部实现了严格的配置模式对齐函数 `workflow_align_modes`。当用户在不同架构间切换时，未被选中的组件将经历物理级卸载，杜绝“孤儿进程”与配置污染：
* **从模式 3 切换至模式 1/2**：
  自动调用 `driver_hysteria_purge`，停止并注销 `hysteria-server.service`、`hysteria-cert-watcher.path` 及关联任务，物理删除 `/usr/local/bin/hysteria` 二进制文件与 `/etc/hysteria` 目录，彻底释放对应的 UDP 端口监听。
* **从模式 1/3 切换至模式 2 (纯净直连)**：
  模式 2 无需域名与本地 Web 服务。脚本将：
  1. 调用 `driver_cert_purge` 注销 acme 定时任务，抹除 `/root/.acme.sh` 及 SSL 证书，清理 Crontab 与 `.bashrc` 环境变量；
  2. 调用 `driver_nginx_purge_package`，停止服务并执行 `apt-get purge -yqq nginx nginx-common socat`，物理删除 `/etc/nginx`、`/var/www`、`/var/log/nginx`。
  系统网络与进程状态彻底恢复至干净的裸代理核心基线。

### 3.5 存储治理、日志熔断与进程安全底座
* **Systemd 日志限额熔断**：针对部分 VPS 磁盘容量极小（$\le 10\text{GB}$）的痛点，在 `/etc/systemd/journald.conf.d/99-prophet.conf` 中固化配置：
  ```ini
  [Journal]
  SystemMaxUse=100M        # 系统日志最大磁盘配额上限 100MB
  MaxRetentionSec=7day     # 日志最长留存周期 7 天，过期自动轮转
  ForwardToSyslog=no       # 关闭冗余日志向 syslog 写入，防止双重占用
  ```
* **静默证书签发与黑洞策略**：全局设置 `LE_NO_LOG=1`、`LE_LOG_FILE='/dev/null'` 与 `DEBUG=0`，并同步固化至 `/root/.acme.sh/account.conf`，彻底关闭 acme.sh 冗长详细的调试日志。
* **运行时栈垃圾回收 (`CLEANUP_LIST`)**：
  脚本创建的所有临时解压目录（`/tmp/web_temp_*`、`/tmp/xray_build_*`、`/tmp/hy2_*`）和探针脚本均压入垃圾回收数组。脚本绑定操作系统底层信号：
  ```bash
  trap 'cleanup_resources' EXIT
  trap 'cleanup_resources; exit 130' INT
  trap 'cleanup_resources; exit 143' TERM
  ```
  无论是正常运行结束、用户按下 `Ctrl+C` 强退，还是被系统守护进程中断，临时碎片均会被全量清除。
* **排他并发保护锁 (`flock`)**：
  采用文件描述符追加模式与非阻塞排他锁：`exec 9>>"$LOCK_FILE"; flock -n 9`。若并发触发执行，新进程将立即识别活动 PID 并报错退出，杜绝多实例并发写入破坏系统配置文件。

### 3.6 事件驱动证书热重载与规则原子更新
* **Systemd.path 内核事件监听**：
  传统的定时轮询重启容易打断正常通信。本套件部署 `hysteria-cert-watcher.path`，利用 Linux 内核级 `inotify` 机制监视证书文件。当 `acme.sh` 签发新证书写盘时，即刻激活 `hysteria-cert-watcher.service`。配合 `hysteria-cert-restart.sh` 中的文件锁防抖及 `openssl x509` 完整性校验循环，平滑通知 Nginx `reload` 并重启 Hysteria 2，达成零感知证书热更新。
* **路由数据库原子下载与热替换**：
  每周一 03:00 (SGT) 执行更新，预先拉取最新的 `geoip.dat` 与 `geosite.dat` 至临时文件。通过两重严密校验：
  1. 文件体积完整性校验：文件大小必须 $\ge 500\text{KB}$，杜绝因网络阻断下载到 404 错误页；
  2. 二进制一致性校验：调用 `cmp -s` 比对哈希。
  仅当规则库出现实质变更时才进行 `mv -f` 原子覆盖并触发 `systemctl restart xray`，保证线上服务高可用。

---

## 4. 三大部署模式特性矩阵

```text
       ┌─────────────── 模式 1: Web 回落模式 (最稳定/自建站) ───────────────┐
       │ - 拥有独立域名并解析至 VPS                                         │
       │ - 部署 Nginx 现代化 3D 伪装站点                                    │
       │ - 外部探测呈现合法 HTTPS 网页，提供极高的抗封锁能力                  │
       └───────────────────────────────────────────────────────────────────┘
       ┌─────────────── 模式 2: 纯净直连模式 (最轻量/免域名) ───────────────┐
       │ - 无需自有域名，借用大厂 SNI (如 www.apple.com) 握手                │
       │ - 物理拔除 Nginx 与 Web 站点，系统资源开销降至最低                  │
       │ - 节点信息支持 IPv4 / IPv6 双栈独立生成与二维码展示                 │
       └───────────────────────────────────────────────────────────────────┘
       ┌─────────────── 模式 3: 全能共存模式 (双协议栈/全能) ───────────────┐
       │ - 兼具模式 1 的完整 Web 回落伪装架构                               │
       │ - 同一端口 (TCP/UDP) 额外挂载 Hysteria 2 协议                      │
       │ - 提供 TCP (Reality) 与 UDP (QUIC) 双通道互备，无惧运营商 QoS 干扰 │
       └───────────────────────────────────────────────────────────────────┘
```

| 功能指标 | 模式 1：Web 回落模式 | 模式 2：纯净直连模式 | 模式 3：全能共存模式 |
| :--- | :--- | :--- | :--- |
| **自有域名依赖** | **必须** (A / AAAA 解析) | **无需** (借用公网大厂域名) | **必须** (A / AAAA 解析) |
| **Xray 入站协议** | VLESS + Vision + Reality | VLESS + Vision + Reality | VLESS + Vision + Reality |
| **辅助协议栈** | 无 | 无 | **Hysteria 2 (QUIC)** |
| **端口复用特性** | 独占业务端口 (TCP) | 独占业务端口 (TCP) | **TCP/UDP 单端口双栈复用** |
| **本地伪装 Web 站** | 本地 Nginx 3D 网页 (8443) | 无 (流量直接出站) | 本地 Nginx 双端口回落 (8443/8444) |
| **TLS 证书依赖** | 自动申请 Let's Encrypt ECC | 无需申请证书 | 自动申请 Let's Encrypt ECC |
| **抗审查防御等级** | ⭐⭐⭐⭐⭐ (极高) | ⭐⭐⭐⭐ (高) | ⭐⭐⭐⭐⭐ (极高) |
| **适用网络场景** | 日常主力翻墙、防封锁要求高 | 临时快速部署、无域名资源 | 弱网恶劣环境、高丢包、多重网络备用 |

---

## 5. 环境与端口规范

### 5.1 操作系统与架构支持
* **操作系统支持**：
  * **Debian**：11 (Bullseye) / 12 (Bookworm) / **13 (Trixie，已针对 `/etc/sysctl.d/` 完成原生适配)**
  * **Ubuntu**：20.04 / 22.04 / 24.04 LTS
* **CPU 体系架构**：
  * `amd64` (`x86_64`)
  * `arm64` (`aarch64` / `arm64-v8a`)
* **硬件最低配置**：
  * CPU: 1 Core | 内存: 512MB RAM | 磁盘可用空间: $\ge 1\text{GB}$

### 5.2 端口规划与占用说明
| 端口号 | 传输协议 | 暴露属性 | 占用服务 | 功能说明 |
| :--- | :--- | :--- | :--- | :--- |
| **`443`** *(默认)* | TCP | **公网暴露** | Xray Core | Reality 外部入站统一入口（可自定义） |
| **`443`** *(默认)* | UDP | **公网暴露** | Hysteria 2 | 仅在模式 3 启用，与 TCP 共用同一端口号 |
| **`80`** | TCP | **公网暴露** | Nginx | HTTP 301 强制跳转与 ACME Webroot 续签验证 |
| **`8443`** | TCP | **本地监听** | Nginx | Reality 未认证流量与普通 HTTPS 回落终点 |
| **`8444`** | TCP | **本地监听** | Nginx | 仅在模式 3 启用，用于 Hysteria 2 认证失败时 HTTP 伪装回落 |

> [!IMPORTANT]
> 服务器的 `80`、`8443` 与 `8444` 端口已被本地基础设施独占。部署时，**业务监听端口严禁配置为 80、8443 或 8444**，否则交互检查程序将拦截并拒绝执行。

---

## 6. 部署与安装指南

### 6.1 脚本选型与执行
根据服务器所属的网络环境，选择对应版本的脚本进行部署：

```bash
# 场景 A: 传统裸机、独立服务器或无上层安全组的 VPS (推荐内置防火墙闭环)
chmod +x v3.0.sh
./v3.0.sh

# 场景 B: AWS、GCP、Oracle Cloud、阿里云、腾讯云等自带 Web 控制台安全组的实例
chmod +x v3.1.sh
./v3.1.sh
```

### 6.2 交互配置流程分解
1. **模式选择**：按需输入 `1`（Web 回落）、`2`（纯净直连）或 `3`（全能共存）。
2. **域名校验 (模式 1 & 3)**：
   * 输入您的域名，系统将自动发起双栈探针（优先调用 Cloudflare DoH，备用系统 `getent` 底层库），比对本机出口 IPv4/IPv6 与域名的当前解析记录。若解析尚未生效，终端将显示醒目的红色预警。
3. **端口设定**：
   * 输入业务端口（直接回车默认 `443`）。脚本自动扫描系统的 `ss` 套接字表，若目标端口已被占用将提示重新输入。
4. **证书验证方式 (模式 1 & 3)**：
   * **DNS API 验证 (推荐)**：支持 Cloudflare（输入 API Token 与 Zone ID）或 Namesilo（输入 API Key）。通过 DNS 记录自动解析，验证过程无感，原生支持通配符。
   * **HTTP Webroot 验证**：依赖 Nginx 80 端口验证，在 `/etc/nginx/sites-enabled/` 动态注入验证块，无需中断现有 Web 服务。
5. **证书颁发环境**：
   * `Production`：生产环境，签发正式信任的 Let's Encrypt 证书。
   * `Staging`：测试环境，无签发频次限制，供初次配置排查故障使用。

---

## 7. 运维管理与生命周期控制

### 7.1 服务状态与实时日志排查
```bash
# 查看 Xray 状态与实时日志
systemctl status xray
journalctl -u xray -f -n 50

# 查看 Nginx 状态与配置热加载
systemctl status nginx
nginx -t && systemctl reload nginx

# 查看 Hysteria 2 状态 (仅模式 3)
systemctl status hysteria-server
journalctl -u hysteria-server -f -n 50

# 查看证书事件监视器状态 (仅模式 3)
systemctl status hysteria-cert-watcher.path
```

### 7.2 自动化任务与证书状态审查
进入脚本交互菜单，选择 `3. 查看定时任务+证书状态`，或直接执行底层运维命令：
```bash
# 查看证书续签及规则数据库自动更新定时器
systemctl list-timers --all | grep -E "xray-acme|xray-dat"

# 查看 acme.sh 已签发证书列表与有效期
/root/.acme.sh/acme.sh --list --home /root/.acme.sh
```

### 7.3 干净卸载与环境回收
在终端运行脚本并选择 `2. 卸载服务`：
1. **业务组件完全注销**：停止并注销所有相关 Systemd 单元（`xray`、`hysteria-server`、`hysteria-cert-watcher`、`xray-acme`、`xray-dat`），删除二进制文件、站点目录与配置目录。
2. **防火墙规则回收 (`v3.0.sh` 独占)**：自动检索当前运行端口，删除对应的 TCP/UDP 与 80 端口放行规则，抹除 nftables 中的 `inet xray_gateway` 独立规则表。
3. **焦土式依赖清理 (交互式可选)**：系统将询问是否彻底卸载系统工具（`nginx`、`socat`、`jq`、`qrencode`、`unzip`）。确认后将调用 `apt-get purge` 进行清退，并自动执行系统垃圾清理；同时保留已调优的内核 BBR 参数与 Systemd 日志限额策略。

---

## 8. 常见故障排查手册 (FAQ)

### Q1: 部署流程在 Nginx 启动时报错中断？
* **诊断方法**：在终端执行 `nginx -t` 查看语法错误详细定位。
* **原因分析**：
  1. 系统中已有 Apache、Caddy 或宝塔面板占用了 `80` 端口。使用命令 `ss -tulpn | grep :80` 查找占用进程并关闭；
  2. 域名证书申请失败，导致配置中引用的证书文件路径不存在。检查申请环节的域名解析是否完全生效。

### Q2: 模式 3 下 Hysteria 2 无法连接，报错 "Handshake Failed"？
* **诊断方法**：执行 `journalctl -u hysteria-server -e` 调取服务端握手日志。
* **排查步骤**：
  1. 确认云厂商安全组（AWS、Oracle、腾讯云等）控制台是否**已显式放行对应端口的 UDP 协议**；
  2. 确认客户端系统时间与服务器系统时间误差在 60 秒以内；
  3. 部分地区运营商存在恶劣的 UDP QoS 封锁或丢包，可在客户端尝试降低发包速率或开启端口跳跃特性。

### Q3: 运行脚本时提示 `检测到已有安装程序正在运行 (PID: xxxx)`？
* **原因分析**：前次运行被异常强制杀死，未触发脚本清理陷阱，导致 `/var/run/xray_script.lock` 遗留内核排他锁。
* **解决方案**：
  ```bash
  # 确认该进程已退出后，手动删除锁文件重新执行
  rm -f /var/run/xray_script.lock
  ```

### Q4: 重新部署或更换端口后，需要重新配置客户端吗？
* **答案**：
  * **Xray Reality (模式 1/2/3)**：**完全不需要**。脚本内置持久化保护，UUID、私钥、公钥与 Short ID 保持绝对一致。若仅修改了监听端口，只需在客户端修改端口数值即可立即恢复连接。
  * **Hysteria 2 (模式 3)**：需要更新密码。Hysteria 2 每次重新部署均会生成全新的 32 位高强度密码以保证安全性。

---

> *Architected for High-Performance Production Environments.*
