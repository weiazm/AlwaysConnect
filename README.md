# AlwaysConnect

Replacement of AnyConnect VPN — Mac VPN 客户端，替代 Cisco Secure Client（AnyConnect），个人自用。

一句话：打开就自动连上，断线绝不漏网，分流规则自己说了算。

## 当前状态：脚手架（Scaffold）

本仓库目前只有工程骨架与设计文档，**还不是一个能用的 VPN**。下一步是 Phase 0 原型验证（见 DESIGN.md 第十一节），三项验证全部需要在 Mac 上实测：

1. libopenconnect 在 PacketTunnelProvider 内跑通一次完整连接（账号密码 + SeaTalk 批准），验证会话恢复与路由安装。
2. 透明代理与包隧道共存验证（应用规则按排除制出站、逆向模式能否实现）。
3. DNS 代理 + 动态路由验证（域名规则生效、TTL 刷新、CDN 共用 IP 冲突）。

## 架构

```
App（菜单栏应用，LSUIElement）
  └── PacketTunnelProvider（隧道 + 重连 + 故障关闭 + DNS 代理）
  └── Transparent Proxy Provider（应用级分流规则）
  └── 特权 Helper（pf 规则兜底）
```

- 隧道协议：OpenConnect（libopenconnect），兼容公司现有 Cisco 网关。
- 凭据：只存 macOS Keychain，不落明文。
- 分流机制（复用业界成熟方案，不自研）：
  - 网段规则：WireGuard AllowedIPs 式 CIDR 路由
  - 域名规则：Cisco 动态分流 + Cloudflare WARP 分流隧道（DNS 触发 + 动态路由）
  - 应用规则：IVPN / PIA / GlobalProtect 同款透明代理
  - 分离 DNS：Tailscale Split DNS
- 完整设计见 [DESIGN.md](DESIGN.md)。

## 目录结构

```
AlwaysConnect/
├── project.yml              # XcodeGen 工程定义（在 Mac 上用 xcodegen 生成 .xcodeproj）
├── core/                    # Rust 核心（alwaysconnect-core）：规则引擎、DNS 动态路由、
│                            # 重连状态机、退避、Swift FFI、libopenconnect 绑定
│                            # Linux 上 cargo test 全量验证
├── Sources/
│   ├── App/                 # 菜单栏应用：入口、状态栏、设置、Keychain
│   ├── Shared/              # App 与扩展共用的数据模型
│   ├── Tunnel/              # PacketTunnelProvider（Swift 壳，调 Rust 核心）
│   ├── Proxy/               # Transparent Proxy Provider
│   └── Helper/              # 特权 Helper（pf 兜底）
├── DESIGN.md                # 详细设计（v0.4）
└── README.md
```

## Rust 核心开发（Linux 可验）

```bash
cd core
cargo test                    # 逻辑 + FFI 测试
cargo test --features openconnect  # 含 libopenconnect 绑定冒烟测试（需 libopenconnect-dev）
```

核心模块：`rules`（分流规则引擎）、`dns_routes`（DNS 驱动的动态路由）、`backoff`（重连退避）、`state_machine`（会话状态机）、`ffi`（给 Swift 的 C ABI）、`openconnect`（libopenconnect 绑定，需 feature 开启）。

## CI（无本地 Mac 时的验证闭环）

`.github/workflows/ci.yml`：Ubuntu 跑 Rust 全量测试（含 libopenconnect 认证对本地 ocserv）；macOS runner 跑核心测试、编 Rust staticlib、用 XcodeGen 生成工程并以 `CODE_SIGNING_ALLOWED=NO` 编译整个 App（只验编译和 Swift↔Rust 链接）。CI 验不了真实网关、SeaTalk 批准、真实断线——那几项仍需可信 Mac（Phase 0）。

## 在 Mac 上构建（待 Phase 0）

前置条件：

- macOS 13+，Xcode（最新稳定版）
- Apple Developer Program 会员（NetworkExtension 的 Packet Tunnel 与 Transparent Proxy 权限需要）
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)（生成工程文件）
- libopenconnect（Phase 0 确认集成方式后补充具体版本与构建步骤）

```bash
xcodegen generate
open AlwaysConnect.xcodeproj
```

## 许可证注意

OpenConnect 是 GPL 协议。个人自用不受影响；若未来公开发布本 App，GPL 部分需按规定处理源码义务。
