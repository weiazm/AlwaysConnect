# AlwaysConnect 详细设计

版本：v0.4（2026-10-30）
目标：Mac VPN 客户端，替代 Cisco Secure Client（AnyConnect），个人自用。
一句话：打开就自动连上，断线绝不漏网，分流规则自己说了算。
本版改动：核心技术栈定为 Rust（Swift 只做 NE 壳与 UI）；分流规则引擎改按业界成熟机制复用（不再自研）；应用规则机制纠正为透明代理（上一版的 NEAppProxyProvider 有误）；交互按 macOS 原生菜单栏应用重做；新增第五节功能取舍判断。

## 一、目标与非目标

### 目标
- 连公司现有 Cisco 网关（当前配置：服务器条目 SZDC，Group SecureVPN）。
- 打开 app 自动登录：账号密码 Keychain 保存，免手动输入。
- 断线无限自动重连；断线期间故障关闭，流量不回落本地网络。
- VPN 开启时家里局域网（192.168.0.0/16）直通，可开路由器管理页。
- 应用 / 域名 / 网段三级分流规则：哪些走公司 VPN、哪些走直连，用户说了算；实现机制复用业界成熟方案（见第四节），不自研。
- 交互不照搬 AnyConnect：按 macOS 原生菜单栏应用的形态做（见第三节），高级、美观、低开销。

### 非目标（本期不做）
- 企业管理侧：策略下发、集中管理、多用户管理。
- Posture 合规检查、Umbrella DNS 防护、AMP 终端防护联动（Cisco 的 NAC/AMP/Web Security 模块，后续扩展池）。
- 标准协议扩展（WireGuard / OpenVPN / IKEv2），后续再议。
- iOS 版本。

## 二、总体架构

```
┌─────────────────────────────────────────────────────────────┐
│ App 进程（Swift + SwiftUI/AppKit，LSUIElement 菜单栏应用）     │
│  菜单栏面板（第一界面）/ 主窗口（第二入口）/ 首次向导 / 规则编辑 │
│  Keychain 凭据管理 / 规则配置 / 诊断打包                       │
└──────────────┬──────────────────────────────────────────────┘
               │ C ABI（FFI）
               ▼
┌─────────────────────────────────────────────────────────────┐
│ Rust 核心（alwaysconnect-core，可移植，无 Apple 框架依赖）      │
│  规则引擎 / DNS 动态路由 / 重连状态机 / 退避 / libopenconnect 绑定│
│  Linux 上 cargo test 全量验证；macOS 上由 Swift 壳调用          │
└──────────────┬──────────────────────────────────────────────┘
               │ App Groups 共享状态 + XPC（NETunnelProviderManager）
               ▼
┌─────────────────────────────────────────────────────────────┐
│ PacketTunnelProvider（NetworkExtension，系统扩展进程，Swift 壳） │
│  调用 Rust 核心驱动 libopenconnect（AnyConnect SSL VPN 协议）   │
│  认证 / 会话恢复 / 隧道数据面 / 路由安装 / 重连状态机           │
│  DNS 代理（域名规则解析 + 动态路由，Cisco 动态分流机制）         │
└──────────────┬──────────────────────────────────────────────┘
               │ 需要时
               ▼
┌─────────────────────────────────────────────────────────────┐
│ Transparent Proxy Provider（NetworkExtension，应用级规则）     │
│  IVPN / PIA / GlobalProtect 同款透明代理机制：                  │
│  按应用身份逐连接决定走隧道还是直连                            │
└──────────────┬──────────────────────────────────────────────┘
               │ 需要时
               ▼
┌─────────────────────────────────────────────────────────────┐
│ 特权 Helper（LaunchDaemon，管理员授权安装一次）                  │
│  pf 规则兜底：故障关闭第二道防线                                │
└─────────────────────────────────────────────────────────────┘
```

关键设计决策：
- 核心用 Rust，Swift 只做壳。Rust 核心不依赖任何 Apple 框架，因此同一份代码在 Linux 上 cargo test 全量验证，macOS 上由 Swift 壳经 C ABI 调用；NE 生命周期、Keychain、UI 仍是 Swift 的。
- 隧道与重连逻辑放在 PacketTunnelProvider 里，而不是 App 里。Provider 是系统管理的常驻进程，App 退出、界面关闭都不影响隧道与重连；故障关闭也因此天然成立（Provider 活着，路由就一直在）。
- OpenConnect 以 libopenconnect 形式由 Rust 核心绑定，不走命令行子进程。命令行子进程在系统扩展沙箱里受限多，且状态同步难。
- App 只做三件事：给 Provider 递凭据与配置、把 Provider 的状态展示出来、管理分流规则。
- 分流规则分层复用成熟机制（见第四节）：网段规则 = WireGuard AllowedIPs 式 CIDR 路由；域名规则 = Cisco 动态分流 + Cloudflare WARP 分流隧道；应用规则 = 透明代理（IVPN / PIA / GlobalProtect 同款）。

## 三、交互设计（macOS 原生菜单栏应用）

借鉴对象：Cloudflare WARP（菜单栏一键开关、状态一目了然）、WireGuard macOS（菜单栏隧道列表开关）、Tailscale（菜单栏状态与出口选择）、IVPN macOS（菜单栏与设置分离）、TripMode（菜单栏里按应用开关，与我们的规则卡片同构）。不借鉴 AnyConnect 的多 Tile、多弹窗。

- **形态**：LSUIElement 菜单栏应用，无 Dock 图标；状态栏图标 + Popover 是第一界面，主窗口保留为第二入口（Apple HIG 要求菜单栏附加项不能是功能的唯一入口，设置与规则编辑放主窗口）。
- **状态栏内容**：图标为主，不堆文字。图标用颜色 + 形状双重区分（绿实心=已连接、黄三角=等批准/连接中、红空心=已断开且拦截中），不只靠颜色。点击弹出面板：大开关、一句话状态（"已连接 · 公司网络"、"重连中 · 网络已拦截（第 3 次）"、"等你在 SeaTalk 点批准"）、当前分流模式、最近一次断线、规则与统计快捷入口。面板内容定高、不滚动，Liquid Glass regular 材质，跟随系统外观与"减透明度"设置。
- **首次向导三步，之后不再打扰**：① 保存凭据（Group SecureVPN 预填、服务器 SZDC 预填，只输账号密码一次）→ ② 选分流模式（安全模式/分流模式，见第四节）→ ③ 完成并自动连接。以后打开即连，不再问。
- **等批准与断线都不弹模态框**：等批准时只发一条通知 + 菜单栏变黄 + 面板里一句话"去 SeaTalk 点批准"；断线时菜单栏变红 + 通知聚合（多次断线合并为一条，不刷屏），不弹窗轰炸。
- **规则编辑用卡片，不用手写配置**：应用规则从本机应用列表里勾选（不用手输 Bundle ID）；域名规则支持通配符；网段规则带格式校验；另附规则模板一键套用（见第五节）。命中冲突时当场红字提示，不让用户配出一套自相矛盾的规则。
- **规则测试器**：输入一个域名或选一个应用，立刻显示它会走哪条路、命中了哪条规则、当前生效与否。分流配错时先查这里，不用猜。
- **泄漏自检**：一键检查当前出口 IP 与 DNS 是否符合预期（VPN 应为公司出口、直连应为本地出口），结果一句话，不贴原始报文。
- **统计是二级页面**：在线时长、流量、路由表、重连记录只放在统计页，不进主路径。
- **资源开销控制**：App 本体不轮询，状态由 Provider 经 XPC 推送；Popover 懒加载，关闭即释放；隧道、规则、重连逻辑全在系统扩展进程，App 退出也不影响；无后台定时器，全部用系统事件驱动（NWPathMonitor、系统通知）；界面用 SwiftUI 轻量视图，不做常驻动画与重型图表；日志限速限量。

## 四、分流规则引擎（复用业界成熟机制）

你说得对，分流是成熟机制，不自研。下面每种规则都对到业界已落地的实现，机制、边界、取舍都按公开资料写。

### 4.1 网段规则：WireGuard AllowedIPs 式 CIDR 路由
- 机制：路由表即策略。WireGuard 的 AllowedIPs 同时是路由决策与访问控制：填 0.0.0.0/0 就是全隧道，填具体网段就是分流——"路由表就是配置"。
- 复用点：我们的网段规则直接映射为 includedRoutes / excludedRoutes（NEIPv4Settings），与 AllowedIPs 同款语义：192.168.0.0/16 直连、公司网段走隧道，写进路由表即生效。
- 边界：这是最底层、最稳定的规则，不受 DNS 与应用变化影响。

### 4.2 域名规则：Cisco 动态分流 + Cloudflare WARP 分流隧道
- 机制：Cisco AnyConnect 4.5+ 的 Dynamic Split Tunneling——按 DNS 域名动态下发分流排除，客户端解析出域名对应的 IPv4/IPv6 地址后动态改路由表与过滤器，让该域名的流量走隧道外；Cloudflare WARP 的 Split Tunnels 同款：Exclude 模式（默认全走网关，列出的 IP/域名除外）与 Include 模式（仅列出的 IP/域名走网关）。
- 复用点：我们的域名规则就是这套机制的客户端本地版——Provider 内 DNS 代理 + 动态路由：规则域名解析时记录结果 IP，动态装路由；按 TTL 刷新；IP 失效删路由。
- 业界已知的边界（照单全收，不回避）：
  - 域名比 IP 慢：需要实时查 IP、改路由表与防火墙，生效有延迟（Cloudflare 原话）。
  - CDN 共用 IP 会误伤：一个 IP 上多个域名时，排除/纳入一个域名可能连带影响同 IP 的其他域名（Cloudflare 原话）。处理：冲突时一律按走 VPN 处理并提示用户。
  - 通配符：Cisco 的动态分流 Values 字段不支持通配符；我们的客户端实现可支持 *.example.com，但要注明这是超出 Cisco 原版的扩展，行为以实测为准。
  - 刷新时机：Cloudflare 是隧道建立时按当时解析结果建规则、每次建隧道时刷新；我们的实现按 TTL 刷新，比它更勤快，代价是路由表 churn 更大，需控制刷新频率。

### 4.3 应用规则：透明代理（IVPN / PIA / GlobalProtect 同款）
- 机制：NETransparentProxyProvider。系统把每个新建的出站 TCP/UDP 连接交给扩展，扩展按源应用身份决定：被排除的应用走物理网卡，其余连接拒绝后按正常路由走（即 VPN 隧道）。IVPN 2026-10-20 刚在 macOS 上线了这套机制（此前 Windows/Linux/Android 早有，macOS 是最后一块拼图），PIA 与 Palo Alto GlobalProtect 在 macOS 上也是同款路线。
- 复用点：我们的应用规则直接用透明代理实现，不再用上一版写错的 NEAppProxyProvider。注意：包隧道的源应用模式（appRules）只对 MDM 纳管设备开放，个人设备不可用，透明代理是个人设备上唯一成熟的应用级分流路径。
- 业界已知的边界（照单全收）：
  - 仅新连接生效：已建立的连接保持原路，直到应用重建连接；改规则会短暂中断被排除应用的连接。
  - 仅 TCP/UDP：系统服务代查的 DNS 仍走 VPN；ping 这类 raw socket 恒走 VPN。
  - 子进程继承：被排除应用拉起的子进程同样被排除，但经 Finder、登录项或 open 命令拉起的不算。
  - 逆向模式在 macOS 上不成熟：IVPN 明确说明"仅选定应用走 VPN、其余直连"的逆向模式在 macOS 上暂不可用（Windows/Linux 有）。影响：我们的分流模式下，应用级"纳入 VPN"规则能否实现需 Phase 0 验证；若不可行，分流模式的应用规则降级为"排除制 + 提示"，不硬上。
  - Safari 排除受限：多数厂商无法把 Safari 排除出隧道（系统限制），PIA 需用特殊的 WebKit 规则且连带影响 Mail 与地图。我们的应用规则对 Safari 做同样提示，不承诺。
- 接线进展：Proxy 已链接 Rust staticlib（Bridge 目录复用 Tunnel 的 RustCore.swift），handleNewFlow 已能按 metaData.sourceAppSigningIdentifier + remoteHostname + TCP 端点主机名做直接放行判定（directEgress，引擎未配置时一律走 VPN）；数据泵（NWConnection 转发）仍是 Phase 2，在此之前直接命中的流也先走 VPN（安全方向，不漏网）。

### 4.4 分离 DNS：Tailscale Split DNS
- 机制：按域名选解析器。Tailscale 的 Split DNS 把特定域名的解析指到特定 DNS 服务器，其余走正常 DNS。
- 复用点：规则域名与公司域名走隧道 DNS（或网关下发 DNS），其余域名走本地 DNS；内网域名误配直连时本地解析不到，只会连不上，不会泄漏（fail-safe 方向）。

### 4.5 默认模式：Cloudflare 的 Exclude / Include
- 安全模式（默认）= Exclude 模式：全走 VPN，列出的除外。好处：没配规则的公司流量不漏网；代价：视频、下载也走 VPN。
- 分流模式 = Include 模式：仅列出的走 VPN，其余直连。好处：不需要 VPN 的流量不挤隧道；代价：没配进 VPN 规则的公司流量会走直连——切到分流模式时 App 强制提醒"Claude 必须配一条应用规则进 VPN"。
- 断线期间两档都一样：故障关闭接管，未命中的流量一律拦截（放行表内除外），不按默认模式放行。

### 4.6 优先级与冲突
应用规则 > 域名规则 > 网段规则 > 默认模式；局域网硬规则高于一切（192.168.0.0/16 永远直连，即使被误配进 VPN 规则也以直连为准并告警）。同目标出现在 VPN 与直连两侧 → 按走 VPN 处理并红字提示。

### 4.7 规则热更新
改规则不重连：App 把新规则推给 Provider，Provider 增量更新路由与 DNS 配置，隧道不断。正在进行的连接按旧规则走完，新连接按新规则走（与 IVPN 的"仅新连接生效"一致）。

## 五、功能优化判断（本轮新增：加 / 暂缓 / 不加）

| 功能 | 判断 | 理由 |
|---|---|---|
| 规则模板一键套用（Claude 走 VPN、视频直连、局域网直连） | 加 | 规则引擎再成熟，配起来也费事；模板把你的实际场景一次配好，之后只改例外 |
| 断线历史与质量看板（轻量，面板一行 + 统计页） | 加 | 你的核心痛点是频繁断线；看得到断线时间、次数与恢复时长，才分得清是网络问题还是网关问题 |
| 通知聚合（断线重连通知合并） | 加 | 无限重连会产生大量事件，不聚合就是刷屏；断线只提醒一次，恢复再提醒一次 |
| 规则导入导出（JSON） | 加 | 成本极低，换机、备份、回滚都有用 |
| 全局快捷键开关（默认关闭，可自定义） | 加 | 菜单栏应用的标配；默认关闭避免与系统快捷键冲突 |
| 泄漏自检与规则测试器 | 加 | 已在第三节，分流配错时唯一的自查手段 |
| 按端口分流、按时间段分流 | 暂缓 | 规则引擎复杂度上升明显，个人场景收益低；留在扩展池 |
| 流量图表、测速 | 暂缓 | 违背低开销原则；计数器够用，图表以后再说 |
| 多账号 / 多网关快速切换 | 暂缓 | 个人自用单网关，优先级低；Phase 3 再做 |
| 按网络位置自动切默认模式 | 不加 | 静默改路由策略有安全风险；安全模式与分流模式必须由用户显式决定 |
| iOS 伴生 App | 不加 | 超出本期范围；macOS 先跑通再说 |

## 六、模块划分

### 1. UI 层（App）
菜单栏面板、主窗口、首次向导、规则编辑（卡片 + 模板）、规则测试器、泄漏自检、统计页、通知。见第三节。
- App 侧接线已落地：KeychainStore 真实现（generic password，AfterFirstUnlock）、ProfileStore（App Groups 非敏感持久化）、TunnelManager（NETunnelProviderManager 建/存/启/停 + 状态观察 + lastError）、菜单栏面板开关接线与启动自动连接；凭据收集 UI（Settings）仍是 Phase 2。

### 2. 凭据与会话层
- 存储：账号、密码、服务器、Group 只存 macOS Keychain（generic password），不写明文文件、不进日志。Touch ID 仅用于"查看/修改凭据"，不 gate 自动登录（否则自动登录会被打断）。
- 启动自动登录：App 启动 → 读 Keychain → 起 Provider → Provider 用保存的凭据认证，全程无弹窗。
- 会话恢复：断线重连优先用原会话恢复（网关会话保持窗口内免 2FA），这是用户实测确认的行为。
- 等批准态：网关要求重新批准时，Provider 上报 awaiting-approval 状态，App 通知 + 菜单栏变黄并持续等待；网关超时关闭尝试后，Provider 自动再发起一次（会再推一条批准消息），直到连上或用户手动断开。
- 实现：Rust 核 `core/src/session.rs`（SessionDriver + SessionRecord + AuthOutcome + DriverAction），决策逻辑与退避、状态机复用；认证结果到 AuthOutcome 的映射已落地（`core/src/openconnect.rs` 的 map_auth_error：Obtain(-1)→Rejected，为回调拒填约定；其他 Obtain 码与 NoCookie→Transient；ParseUrl/CaFile→Rejected）。
- NeedsApproval 在阻塞等待中的上报仍是缺口：obtain_cookie 在等 push 时是阻塞的，驱动要实时知道"在等批准"，需表单回调在看到无凭据字段的 push 形表单时通知驱动，并用 openconnect_set_cancel_fd 实现批准超时中断——两者都需真实网关的表单形状验证，挂起到有 Mac + 真实网关。
- 会话恢复的边界（2026-10-30 更正：此前“库路径无 Cookie 注入公开函数”的说法是错的，错在信了二手 API 总结；本地 9.12 头文件原文为准）：`openconnect_set_cookie()` 存在（openconnect.h:669，另有 clear_cookie :670），因此新进程走库路径也能用已存 Cookie 恢复（set_cookie 后建连接），SessionRecord 两条路线都能用。进程内存活的 vpninfo 掉线后靠 mainloop 原地重连仍是最快路径；Cookie 被拒或过期则回落完整认证（可能需批准）。驱动不猜 Cookie 过期：有效性只由服务器对重连尝试的响应证明，不用计时器。
- 状态机扩展：原机没有\"认证被拒\"的终态路径和连接中/认证中的手动断开路径，驱动需要，`state_machine` 增加 AuthRejected（认证中 → 已断开）与 ManualDisconnect（连接中/认证中 → 已断开）。

### 3. 隧道层（Provider + libopenconnect）
- 协议：AnyConnect SSL VPN（CSTP over TLS，DTLS 数据面按网关协商）。
- 认证：Group（SecureVPN）+ 用户名 + 密码 + SeaTalk push 等待。
- 路由：默认路由走 utun；排除路由 192.168.0.0/16 走物理网卡（NEIPv4Settings.excludedRoutes）。
- DNS：隧道 DNS 按网关下发；规则域名走 Provider 的 DNS 代理；局域网域名解析走本地。
- 睡眠/唤醒、网络切换（Wi-Fi 漫游、网络变化）：NWPathMonitor 触发立即重连尝试，并刷新域名规则的解析结果。

### 4. 重连与故障关闭（核心）
状态机：
```
已断开 → 连接中 → 认证中 → 等批准 → 已连接
已连接 →（掉线）→ 重连中（会话恢复）
重连中 →（会话失效）→ 认证中 → 等批准 → 已连接
重连中 / 等批准 →（用户手动断开）→ 已断开（恢复本地网络）
```

- 退避策略：1s、2s、5s、10s、30s封顶，带抖动，永不放弃；成功后重置。
- 故障关闭第一道（主防线）：掉线后 Provider 不拆除 utun、不撤销路由，数据面停止转发，流量黑洞丢弃。系统路由仍指向隧道，物理网卡收不到外发流量，因此不可能"回落本地"。
- 故障关闭第二道（pf 兜底，需特权 Helper）：pf 锚点规则——物理网卡出方向默认拒绝，仅放行 192.168.0.0/16、DHCP（获取局域网地址必需）与本地回环。Provider 异常退出时规则仍在，不漏网。
- 实现：`core/src/pf.rs` 生成锚点文本（纯文本生成，加载/卸载归 Helper 的 pfctl 调用）。关键约束：网关 IP 必填——没有它 pf 会把重连自身的路也挡住，客户端断线后永远连不回来；所以 Helper 只在隧道起来后（网关 IP 已知）才装规则，装之前没有隧道、没有可漏的流量。另放行 mDNS 与 fe80::/10；pfctl 是最终校验，加载失败必须上报用户、不得静默跳过。
- Helper 已接 pf 生成：`AlwaysConnectHelper generate-pf`（经 C ABI 调 Rust 核）在 stdout 输出锚点文本；CI 在 macOS runner 上实跑并校验输出（含无网关时失败）。pfctl 加载/卸载随 LaunchDaemon 安装来（Phase 2，需 root 与 Mac）。
- 手动断开 vs 意外掉线严格区分：只有手动断开才恢复本地网络、清除 pf 规则；意外掉线一律保持拦截，直到连上或用户手动断开。
- 拦截期间的用户可见状态：菜单栏变红，面板显示"已断开，网络已拦截，正在重连（第 N 次）"，而不是假装在线。

### 5. 诊断层
- 日志：分级（错误/信息/调试），默认信息级；调试级记录协议关键步骤，密码、Cookie、2FA 相关内容一律脱敏。
- 诊断包：日志 + 配置（去敏感）+ 系统与版本信息，一键导出，对标 Cisco DART。

## 七、关键流程

### 启动自动登录
1. 用户打开 App。
2. App 读 Keychain，拿到服务器、Group、账号、密码。
3. App 起 Provider 并递交配置。
4. Provider 认证 → 网关放行（会话保持期内无 2FA，或 SeaTalk 批准后放行）→ 建隧道、装路由 → 状态"已连接"。

### 断线重连（会话恢复路径）
1. 隧道丢包/保活超时 → Provider 判定掉线，状态"重连中"，路由保持、流量黑洞。
2. 按退避间隔用原会话恢复；成功 → 状态"已连接"，退避重置。
3. 会话已失效 → 转完整认证；网关要求批准 → 状态"等批准"，App 通知用户；批准后建隧道。

### 断线重连（需批准路径）
1. 同上进入"等批准"，App 通知用户。
2. 用户点批准 → 连上；网关超时 → Provider 自动再发起（再推一条批准），循环直到连上或手动断开。
3. 全程 Kill Switch 生效，Claude 流量不会换 IP 出去。

### 局域网访问（VPN 连通时）
1. 访问 192.168.x.x → 匹配排除路由 → 走物理网卡直连 → 路由器管理页打开。
2. 访问其他地址 → 按规则引擎判定：命中规则按规则走，未命中按默认模式走。

### 手动断开
1. 用户点 Disconnect → Provider 拆隧道、撤路由 → Helper 清除 pf 规则 → 恢复本地网络 → 状态"已断开"。

## 八、数据模型

- Profile：{ 服务器（SZDC）、Group（SecureVPN）、自动连接开关、默认模式（安全/分流） }。
- Credential：Keychain 条目 { 服务器、账号、密码 }，按服务器+账号区分。
- Rule：{ 类型（应用/域名/网段）、目标（签名身份/域名通配符/网段）、方向（走 VPN/直连）、启用开关 }。
- NetworkPolicy：{ 分流排除网段[]（默认 192.168.0.0/16）、断线放行表[]（默认同左）、pf 兜底开关 }。
- SessionState：{ 状态、网关、隧道 IP、连接开始时间、重连次数、上次断线时间、等批准标志 }。
- Statistics：{ 上行/下行字节、在线时长、历史断线记录 }。

## 九、安全设计

- 密码只进 Keychain，不进偏好文件、日志、诊断包、崩溃报告。
- Provider 与 App 之间只传配置与状态，不回传密码明文到界面进程日志。
- pf 规则最小化：默认拒绝 + 明确放行，不做"允许全部再补洞"。
- 日志与诊断包强制脱敏：密码、会话 Cookie、Authorization 相关字段。
- 代码与素材全部自研自绘，不复制 Cisco 二进制、界面资源与品牌。

## 十、权限、分发与签名

- 必需权限：NetworkExtension（Packet Tunnel + Transparent Proxy），需 Apple Developer Program 会员。
- 特权 Helper：SMAppService / LaunchDaemon，安装时一次管理员授权。
- 分发：Developer ID + 公证，不走 Mac App Store。原因：App Store 对 NetworkExtension + 特权 Helper + GPL 组件的组合限制多，个人自用没必要过审。
- 系统要求：macOS 13+（NetworkExtension 现代 API），Apple Silicon 与 Intel 通用架构。

## 十一、开发排期（估计，非承诺）

- Phase 0 原型验证（1–2 周）：① libopenconnect 在 PacketTunnelProvider 内跑通一次完整连接（手动账号密码 + SeaTalk 批准），验证会话恢复与路由安装；② 透明代理与包隧道共存验证（应用规则流量能否按排除制出站、逆向模式能否实现）；③ DNS 代理 + 动态路由验证（域名规则生效、TTL 刷新、CDN 共用 IP 冲突）；④ macOS 下隧道数据面接法二选一：NE 包泵（packetFlow ↔ libopenconnect 对接）或特权 Helper 直接跑 openconnect CLI（Tunnelblick 式）。任一受阻则改走兜底方案（见第十二节）。
- Phase 1 MVP（3–4 周）：App + Provider + Keychain 自动登录 + 连接/断开 + 192.168 分流 + 网段规则 + 无限重连 + 故障关闭主防线（路由不撤）。
- Phase 2 加固（2–3 周）：pf 兜底 Helper、菜单栏、统计、通知、等批准态 UI、诊断打包、应用规则、域名规则、规则测试器、泄漏自检、规则模板、通知聚合。
- Phase 3 完善（2 周）：偏好设置完整、放行表编辑、开机自启、多服务器/多账号、日志脱敏、公证分发。

## 十二、风险与未知

- 网关会话保持窗口未知：快速重连免批准的窗口多长，需实测；窗口外重连必然触发批准。
- SeaTalk 批准超时未知：超时后 Provider 自动再发起的行为需实测。
- OpenConnect 与公司网关版本兼容性需实测（协议细节、Group 选择、DTLS 协商）。
- PacketTunnelProvider 沙箱对 libopenconnect 的限制需 Phase 0 验证。
- 透明代理与包隧道共存、逆向模式（仅选定应用走 VPN）能否实现，需 Phase 0 验证；若不可行，分流模式的应用规则降级为排除制 + 提示，不硬上。
- Safari 排除受限：系统级限制，应用规则对 Safari 不承诺排除效果。
- pf 规则与 macOS 大版本升级的兼容性需持续跟进。
- 本设计不改动公司网关配置；若网关侧策略（如禁止保存密码、强制每次 2FA）与自动登录冲突，以网关策略为准，App 侧只能做到"少输密码 + 等批准"。

## 十三、查漏清单（逐项已覆盖）

- **IPv6 泄漏**：系统有 IPv6 时，未经隧道的 IPv6 出口会绕过全部规则。处理：VPN 激活时物理网卡出方向 IPv6 默认拦截（pf 兜底包含 IPv6 规则），除非网关下发 IPv6 隧道；局域网 IPv6（fe80::/10 链路本地）放行。
- **DNS 泄漏**：规则外域名的解析必须走隧道 DNS；Provider 的 DNS 配置只覆盖规则域名与隧道域名，其余域名解析仍走系统 DNS 时需确认不经过本地明文通道外泄内网域名。处理：默认模式为安全模式时，全部 DNS 走隧道；分流模式时仅规则域名与公司域名走隧道，其余走本地（用户已知情）。
- **DoH/DoT 绕过**：浏览器或应用自带加密 DNS 会绕过 Provider 的 DNS 代理，域名规则对它失效。处理：应用规则是后盾——给浏览器配一条应用规则即可全量覆盖；规则测试器里对 DoH 应用做提示。
- **QUIC（UDP 443）**：HTTP/3 走 UDP，域名规则靠 DNS 解析结果的 IP 路由，同样生效；应用规则走透明代理的 UDP 流，同样生效。无额外缺口。
- **Captive Portal（酒店/机场 Wi-Fi 登录页）**：Kill Switch 全拦截时，Portal 登录页打不开。处理：检测到 Captive Portal 时，App 提示用户"临时放行 Portal 登录"，用户确认后仅放行 Portal 域名/IP，登录完成自动恢复拦截；不自动静默放行。
- **mDNS / Bonjour / AirDrop / 打印机发现**：链路本地组播（224.0.0.0/4、ff02::/16）与局域网发现流量放行，不进隧道。
- **网关自身直连**：到网关的流量必须走物理网卡（隧道还没建起来时），网关地址自动加入直连排除，不依赖用户配置。
- **DHCP 与链路本地**：DHCP（67/68）、ARP、本地回环一律放行，否则局域网地址都拿不到。
- **睡眠唤醒与网络切换**：唤醒与 Wi-Fi 切换时立即重连并刷新域名解析，不用等退避周期跑完。
- **规则热更新**：改规则不重连，增量更新路由与 DNS；进行中连接按旧规则走完。
- **规则冲突**：同目标出现在 VPN 与直连两侧 → 按走 VPN 处理并红字提示；局域网网段被配进 VPN → 以直连为准并告警。
- **内网域名误配直连**：公司内网域名若被配进直连，因本地 DNS 解析不到，只会连不上，不会泄漏到外网（fail-safe 方向），规则测试器会提示"该域名本地解析不到"。

## 十四、后续扩展池（本期不做）

- 标准协议：WireGuard / OpenVPN / IKEv2。
- Cisco 对齐：Posture 合规、Umbrella 式 DNS 防护、AMP 联动、Web Security。
- 通用附加：分流可视化编辑器、连接质量看板、断网保护可视化、DNS 泄漏检测、Shortcuts、多账号快速切换、配置加密分享。
- 高级规则：按端口分流（如仅 443 走 VPN）、按时间段分流（如工作时间自动切安全模式）。

## 十五、Phase 0 分叉决议（v0.5，2026-10-31，用户授权助手定）

### 决议：走特权 Helper + openconnect CLI 路线，放弃 NE 包泵路线

新架构：App（菜单栏）+ Helper（LaunchDaemon，root：跑 openconnect CLI、管 pf、管路由与 DNS）+ Proxy（透明代理，只做应用规则）+ pf 兜底。PacketTunnelProvider 目标移出构建，不再承担隧道；其源码保留在 Sources/Tunnel（不编译）作参考，CLI 路线跑通后删除。

### 定性理由（按权重排序）

1. **最少未验证机制**：CLI 路线复用久经实战的 openconnect 二进制——认证、CSTP、DTLS、重连、MTU、DPD 全是现成的。NE 包泵路线要把 packetFlow 的包喂给 libopenconnect，依赖的喂包机制（socketpair + tun fd 注入或等效 API）未经本项目验证，NE 沙箱对库的网络、文件、Keychain 访问也未经验证。没 Mac 的情况下，每多一个未验证机制，风险就翻一倍。
2. **没 Mac 也能验得更多**：CLI + ocserv 在 Linux 上就能跑通编排逻辑（拉起、传参、Cookie 恢复、退出码、脚本钩子），只剩 tun 与路由表被沙箱挡住；NE 包泵离开 NE 运行时一步都验不了。
3. **Helper 本来就要有**：pf 兜底无论如何都需要一个特权 Helper，CLI 路线不新增特权组件，只给已有组件加活。一次管理员授权装 Helper，同时解决 pf 与隧道。
4. **Tunnelblick 同款，有维护先例**：同一模型在 macOS 大版本间有人持续维护，不是孤例。
5. **沉没成本可控**：被放弃的只是 Tunnel 目标的接线代码（Provider 壳 + 会话驱动适配），Rust 核的规则、会话驱动、pf、认证映射全部复用；Proxy 不受影响。

### 付出的代价（明说，不藏）

- App 与隧道的关系从 NETunnelProviderManager 改为 XPC：App 读 Keychain，启动时经 XPC 把凭据发给 Helper（Helper 只放内存，不落盘）；Helper 用 --passwd-on-stdin（新认证）或 --cookie-on-stdin（会话恢复）起 openconnect，--authgroup 传 Group。
- 失败关闭的第一道改由自定义 vpnc-script 承担：脚本的断开路径一律不拆路由、不清 pf（只记日志），只在 Helper 确认"用户手动断开"后才由 Helper 显式恢复本地网络；意外掉线时路由与 pf 原地保留，openconnect 自身重连 + Helper 的退避双保险。
- 等批准态的感知从"库回调通知"变为"CLI 输出启发式"：Helper 从 openconnect 的 --verbose 输出里识别 push 等待标记，真实网关的实际输出形状是 Phase 1 待验证项，验出来之前不承诺精确的等批准文案。
- 分发仍需付费开发者账号（Proxy 的 NE entitlement + Helper 的 SMAppService + 公证），包隧道 entitlement 省掉了，但 binding 约束没变。
- openconnect 是 GPL：个人自用无碍，对外分发需处理源码义务。

### 随决议的改动清单（Phase 1 重做项）

- project.yml：Tunnel 目标移出构建，App 目标去掉对 Tunnel 的依赖；Proxy、Helper 不变。
- App 侧：TunnelManager（NETunnelProviderManager）替换为 HelperClient（XPC：启动、停止、状态订阅、lastError）；面板状态源从 NEVPNStatus 改为 Helper 上报的状态。
- Helper 侧：除 generate-pf 外，增加 CLI 编排（拉起、停止、退出码与重连决策、Cookie 持久化复用 SessionRecord、pf 加载/卸载、vpnc-script）。
- Rust 核：会话驱动复用为编排决策逻辑；认证结果映射从 obtain_cookie 码改为 CLI 退出码 + 脚本钩子信号（Phase 1 落实）。
- 本决议之前的 Tunnel 相关设计段落（第二节架构、第六节第 3 条隧道层）以本节为准，不再单独改旧文。
