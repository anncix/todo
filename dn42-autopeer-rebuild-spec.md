# dn42 Autopeer 复刻开发文档

> 目标：依据本文档可以从零实现一个与 `jasonxu114514/dn42` 行为等价的系统，包含控制平面、Telegram Bot、Web UI、Looking Glass 与运行在路由器上的 Go 节点服务。
> 原文仓库：`https://github.com/jasonxu114514/dn42`
> 基线版本：`4248b8952074692b51ecf4d4bee4598dc0c0c586`（2026-06-09，`feat(bot): limit group chats to looking-glass commands`）
> 代码规模：约 7528 行（Python 约 4000 行、Go 约 1600 行、模板/静态资源/配置约 1900 行）
> 运行环境：Python 3.11+、Go 1.22+、Linux 路由器（root，需 `wg-quick`、`birdc`、`ping`、`traceroute`、`mtr`）

**阅读路径建议**

1. 第一次复刻：按 §1 架构 → §3 配置 → §4 数据 → §5 WSS 协议 → §6 节点枢纽 → §7 Peer 逻辑 → §13 Go 节点 的顺序实现。
2. 只做 Bot：读 §3、§8、§9、§10。
3. 只做 Web：读 §4、§10、§11、§12。
4. 需要 1:1 对齐交互：读 §8.4 命令表、§8.7 FSM 文案、§11.3 模板字段、附录 A 文案速查。
5. 上线部署：读 §2.5、§2.6、§14、§16。
6. 验收：直接用 §15 的清单 + §15.3 一致性对照表。
7. 排期实施：按 §17 的阶段拆分，逐阶段交付可运行产物。

**符号约定**

| 符号 | 含义 |
|---|---|
| `必须` | 缺少会导致功能不可用、协议不兼容或产生安全漏洞 |
| `建议` | 影响稳定性/可维护性，可按部署环境调整 |
| `原实现` | 基线版本中的具体行为，复刻时建议保持一致 |
| `⚠️` | 已知缺陷、隐式契约或易错点，详见各章末尾“实现陷阱”与 §18 |

**与上一份文档的关系**

本文档是独立仓库（`jasonxu114514/dn42`，dn42 Autopeer）的复刻规格，不是 `Potat0000/dn42-bot` 的续作。两者虽然都叫“dn42 bot”，但通信方向、认证体系、数据持久化、Web 能力完全不同，不能复用旧文档的协议章节。核心差异见 §1.5。

**文档结构**

| 章节 | 内容 | 面向 |
|---|---|---|
| §0 术语与速查 | 术语、常量、派生规则、完整示例 | 所有人（先读） |
| §1 系统架构 | 三端拓扑、时序、信任边界、与旧仓库差异、目录树 | 架构 |
| §2 部署与运行 | 环境前提、`start.py`、`.env`、节点 `config.json`、systemd、反代 | 运维 |
| §3 配置与入口 | `Settings`、lifespan、中间件、不安全默认值守卫 | 后端 |
| §4 数据模型 | 7 张表逐列结构、状态机、索引、查询函数 | 后端 |
| §5 Node WSS 协议 | 连接建立、信封、8 个命令、超时映射、心跳 | 协议 |
| §6 节点枢纽 | `NodeHub` 实现、连接替换、状态清洗 | 后端 |
| §7 Peer 领域逻辑 | 校验、地址派生、WG/BIRD 渲染、部署与拆除 | 后端 |
| §8 Bot 实现规格 | 双 Router、12 条命令、三套 FSM、文案、分块 | Bot |
| §9 Bot-only REST API | 12 个端点、认证、模型、错误约定 | Bot/后端 |
| §10 认证流程 | Kioubit / Telegram Mini App / FindNOC、身份归一 | 安全 |
| §11 Web UI 规格 | 35 条路由、渲染管线、门户、管理后台、模板宏 | 前端/后端 |
| §12 Looking Glass | 四层防护、`POST /lg`、限流、审计、摘要、命令映射 | 功能 |
| §13 Go Node 实现规格 | 配置、手写 WebSocket、命令分发、Runner、状态采集 | 节点 |
| §14 安全要求 | 威胁模型、秘密流向、校验矩阵、权限、检查清单 | 安全 |
| §15 验收用例 | 10 个端到端场景、字段对照、68 条回归、负面用例 | 测试 |
| §16 运维手册 | 巡检、排障决策树、备份恢复、升级扩容、应急 | 运维 |
| §17 实施阶段 | M0–M9 里程碑、任务清单、复杂度、返工点 | 项目管理 |
| §18 改进建议 | 架构演进、安全加固优先级、可观测性、不要改的契约 | 维护 |
| 附录 A | 文案速查、状态枚举、常量总表、术语对照、源码映射 | 所有人（速查） |

---

## 0. 术语与速查

### 0.1 术语表

| 术语 | 含义 |
|---|---|
| Backend / 控制平面 | FastAPI 单进程应用。同时承载 SSR Web UI、Bot-only REST API、节点 WSS 入口、公开 Looking Glass |
| Node / PoP | 操作者经营的一台路由器（如 `frankfurt`、`tokyo`），在 `nodes` 表中是一行记录 |
| Node service / 节点服务 | 部署在 Node 上的 Go 守护进程，root 运行，**主动拨出** WSS 连回 Backend，执行 WireGuard/BIRD 操作与探针命令 |
| Bot | aiogram 3.x Telegram Bot，长轮询（polling），通过 HTTP 调用 Backend 的 `/api/telegram/*` |
| Peer | 一条 WireGuard 隧道 + 一个 BGP 会话。归属某个 `users` 记录，绑定某个 Node |
| LG / Looking Glass | 公开的 ping / traceroute / mtr / route 查询入口，按客户端 IP 限流并写审计日志 |
| Challenge | 一次性登录挑战串，`auth_challenges` 表中的一行，TTL 600 秒 |
| Binding | `telegram_bindings` 中 UID → user 的映射，一个 Telegram UID 全局唯一 |
| Kioubit | 第三方 dn42 身份认证服务（`dn42.g-load.eu`），用 ECDSA 签名断言“某 ASN 属于某人” |
| FindNOC | 第三方 Telegram UID → ASN 查询服务（`findnoc.ox5.cc`），作为 Bot 轻量登录路径 |
| deploy / applied | 部署结果的两个独立维度：`ok` 表示命令整体成功，`applied` 表示配置已落盘并重启接口成功 |
| LLA | IPv6 link-local 地址（`fe80::/10`），dn42 默认的 BGP 邻居地址类型 |
| ULA | IPv6 私有地址（`fc00::/7`，涵盖 `fd00::/8`），可选替代 LLA |
| IFNAMSIZ | Linux 网络接口名长度上限 15 字节（含结尾 NUL，实际可用 15 字符以内） |

### 0.2 关键常量速查

| 常量 | 值 | 位置 | 说明 |
|---|---|---|---|
| `heartbeatInterval` | 20s | Go `backend/client.go` | 节点上行心跳周期 |
| `statusSampleInterval` | 60s | Go `backend/client.go` | wg/birdc 输出缓存刷新周期 |
| `defaultReconnectDelay` | 5s | Go `backend/client.go` | 断线重连间隔 |
| `maxFramePayload` | 1 MiB | Go `backend/client.go` | 单帧上限，不支持分片 |
| `maxStatusOutput` | 64 KiB | Go `backend/client.go` | 状态输出截断上限 |
| `defaultMaxConcurrency` | 4 | Go `internal/config` | LG 类命令并发上限；显式 `0` 表示不限制 |
| `command_timeout_seconds` | 12s（示例配置） | 节点 `config.json` | 单次子进程超时 |
| Node 请求超时（Python） | 20s（deploy）/ 其它命令默认 | `app/peer/deploy.py` | `request_node` 的 `timeout` |
| `CHALLENGE_TTL` | 600s | `app/auth/service.py` | 登录挑战有效期 |
| Kioubit 时钟偏差 | ±60s | `app/auth/kioubit.py` | 超出即拒绝 |
| `LG_RATE_LIMIT` | 20 次 | `.env` | 每 IP 每窗口请求数，`0` 关闭 |
| `LG_RATE_WINDOW_SECONDS` | 60s | `.env` | 限流窗口 |
| 配置片段上限 | 16 KiB | Go `runner` | 单份 wg/bird 配置大小上限 |
| WG MTU | 默认 1420，范围 1280–9000 | `app/peer/validation.py` | 数据库与渲染共用 |
| 配置文件权限 | 0640，目录 0750 | Go `runner` | 原子写入后 `Rename` |
| Bot 消息块 | 3900 字符 | `app/bot/main.py` | 超长输出分块发送 |

### 0.3 派生规则（复刻必须一致）

这三条规则贯穿配置渲染、Web 预填、Bot 显示和 Go 节点部署，任何一处不一致都会导致“看起来成功但隧道不通”。

**1）WireGuard 监听端口 = ASN 后 5 位**

```python
def wireguard_listen_port(asn: str) -> int:
    value = normalize_asn_number(asn)   # 去 "AS" 前缀，必须纯数字
    port = int(value[-5:])              # 4242420090 -> 20090
    if port < 1 or port > 65535:
        raise ValueError("Derived WireGuard listen port is out of range")
    return port
```

同一节点上“一个 ASN 至多一个 Peer”是端口不冲突的前提，因此 `peer_requests` 上有 `UNIQUE(node_id, asn)`。

**2）Link-local 地址 = `fe80::<ASN 短后缀>`**

```python
def normalize_dn42_asn_suffix(asn: str) -> str:
    value = normalize_asn_number(asn)
    if len(value) < 4:
        suffix = value
    elif value.startswith("424242"):
        suffix = value[6:]              # 4242420099 -> "0099"
    else:
        suffix = value[-4:]             # 65001 -> "5001"
    suffix = suffix.lstrip("0") or "0"  # "0099" -> "99"
    return suffix.lower()

def asn_link_local_address(asn: str) -> str:
    return f"fe80::{normalize_dn42_asn_suffix(asn)}"
```

示例：`AS4242420090` → `fe80::90`；`AS4242425001` → `fe80::5001`；`AS65001` → `fe80::5001`（与前者**碰撞**，但不能靠改地址避免，见下条）。

**3）协议名/接口名/文件名 = `DN42_<ASN 后 4 位>_<peer.id 后 4 位>`**

```python
def peer_protocol_name(peer: PeerRequest, node: Node) -> str:
    asn_suffix = normalize_asn_number(peer.asn)[-4:]
    return f"DN42_{asn_suffix}_{peer.id[-4:]}"
```

长度固定 14 字符（`DN42_` 5 + 4 + `_` 1 + 4），满足 IFNAMSIZ 15 限制。**必须**带上 `peer.id` 后 4 位，否则 `AS4242425001` 与 `AS65001` 在同一节点会得到同一个名字 `DN42_5001`，导致两台对端的 wg 配置、BIRD 协议互相覆盖。

### 0.4 完整示例（便于对照）

假设：`LOCAL_ASN=4242420000`，节点 `frankfurt`，`url=de-fra.example.net`，`dn42_ipv4=172.20.0.1`，`dn42_ipv6=fd00::1`，节点公钥 `NODEKEY...`。用户 `AS4242420090` 在 Web 提交：

| 字段 | 值 |
|---|---|
| endpoint | `198.51.100.9:51820` |
| wg_public_key | `PEERKEY...`（44 字符 base64） |
| wg_mtu | `1420` |
| peer_dn42_ipv4 | `172.20.90.1` |
| peer_dn42_ipv6 | `fd00::90` |
| peer_link_address | 留空（回退 ASN 派生） |
| bgp_extended | 勾选 |

派生结果：

| 派生项 | 值 |
|---|---|
| `local_link_address` | `fe80::0`（节点 ASN 4242420000 的后缀全零 → `"0"`；实际复刻时建议在管理端显式设置为节点自己的 LLA） |
| `peer_link_address` | `fe80::90` |
| WG `ListenPort` | `20090` |
| 节点侧 endpoint | `de-fra.example.net:20090` |
| 协议名 | `DN42_0090_<peer.id 后四位>` |
| `PostUp` | `ip addr add fe80::0/64 dev %i` |
| BIRD neighbor | `neighbor fe80::90%DN42_0090_xxxx as 4242420090;` |

---

## 1. 系统架构

### 1.1 组件拓扑

```text
                          ┌──────────────────────────────┐
                          │  Telegram（私聊 / 群聊）      │
                          └──────────────┬───────────────┘
                                         │ polling（Bot 主动拉取）
                                         ▼
┌──────────────────────────────────────────────────────────────────────┐
│ Backend（FastAPI 单进程，uvicorn）                                    │
│                                                                      │
│  /                Web UI（Jinja2 SSR）                                │
│  /portal/*        用户自助 Peer 管理                                  │
│  /admin/*         管理员控制台（节点/Peer/成员/审计）                  │
│  /lg              公开 Looking Glass（SSR + fetch 双模式）             │
│  /auth/kioubit/callback  Kioubit 登录回调                             │
│  /telegram/auth   Telegram Mini App 落地页                            │
│  /api/telegram/*  Bot-only REST（X-Backend-Secret）                   │
│  /api/nodes/ws    Node WSS 入口（Bearer token）                       │
│                                                                      │
│  SQLite（SQLAlchemy 2.x）  SessionMiddleware  SlidingWindowRateLimiter │
└───────────┬──────────────────────────────────────┬───────────────────┘
            │ HTTP（内网 / localhost）               │ WSS（Node 主动拨出，TLS）
            ▼                                      ▼
┌───────────────────────┐              ┌───────────────────────────────┐
│ Bot（aiogram 3.x）     │              │ Node service（Go，root）       │
│ 命令 + FSM + 内联按钮  │              │  ├─ 手写 WebSocket 客户端      │
│ 调用 Backend REST      │              │  ├─ wg-quick up/down           │
└───────────────────────┘              │  ├─ birdc c / show status      │
                                       │  ├─ ping / traceroute / mtr    │
                                       │  └─ 读写 /etc/wireguard, /etc/bird/peers
                                       └───────────────────────────────┘
```

三条关键方向约定，**必须**严格保持：

1. **Node 主动连 Backend**，Backend 从不主动连 Node。好处是节点可在 NAT 后，且只需出站 443。
2. **Bot 主动连 Backend**，Backend 不反向调用 Telegram。Bot 使用 polling，无需公网 webhook。
3. **浏览器不直连 Node**。所有 LG 查询经 Backend 转发到 Node，Node 返回纯文本。

### 1.2 进程与端口

| 进程 | 监听 | 出站 | 运行身份 |
|---|---|---|---|
| Backend | `HOST:PORT`（默认 `127.0.0.1:8000`，生产由 nginx 反代 443） | 无（除 FindNOC HTTP 调用） | 普通用户 |
| Bot | 无监听（polling） | `api.telegram.org`、Backend `TELEGRAM_BACKEND_URL` | 普通用户 |
| Node service | 无监听 | Backend `wss://.../api/nodes/ws` | **root** |

### 1.3 一次 Peer 创建的完整时序

```text
用户            Bot                  Backend                 Node service
 │  /create       │                      │                         │
 │───────────────>│                      │                         │
 │                │ POST /api/telegram/challenge                    │
 │                │─────────────────────>│ 写 auth_challenges      │
 │                │<─────────────────────│ {token, url}            │
 │  打开 Mini App │                      │                         │
 │  Kioubit 签名  │                      │                         │
 │  tg.sendData   │                      │                         │
 │───────────────>│ web_app_data         │                         │
 │                │ POST /api/telegram/verify                       │
 │                │─────────────────────>│ 验签 + consume + upsert │
 │                │<─────────────────────│ user + binding          │
 │  选节点/填表   │                      │                         │
 │───────────────>│ FSM 收集 9 个字段     │                         │
 │                │ POST /peer/preview    │                         │
 │                │─────────────────────>│ 校验并渲染预览           │
 │                │<─────────────────────│ 配置片段                 │
 │  确认          │                      │                         │
 │───────────────>│ POST /peer/create     │                         │
 │                │─────────────────────>│ INSERT peer (deploying) │
 │                │                      │ peers.deploy ──────────>│
 │                │                      │                         │ 写 wg conf
 │                │                      │                         │ wg-quick down/up
 │                │                      │                         │ 写 bird conf
 │                │                      │                         │ birdc c
 │                │                      │<─────────────────────────│ {ok, applied, ...}
 │                │                      │ UPDATE deploy_status     │
 │                │<─────────────────────│ {peer, config}          │
 │  收到配置+状态 │                      │                         │
 │<───────────────│                      │                         │
```

### 1.4 信任边界

| 边界 | 信任依据 | 被攻破的后果 |
|---|---|---|
| 浏览器 → Backend | Session Cookie（签名，`SameSite=Lax`，生产 `Secure`） | 可管理自己的 Peer；管理员可管理全站 |
| Bot → Backend | `X-Backend-Secret` 常量时间比较 | 可伪造任意 Telegram UID 的身份与操作 |
| Node → Backend | `Authorization: Bearer <node.token>` 常量时间比较 | 可冒充节点返回伪造状态、接收部署指令 |
| Backend → Node | 仅通过已认证 WSS 连接 | 节点服务以 root 执行固定 argv，**不经过 shell** |
| Kioubit → Backend | ECDSA/SHA-512 签名 + 60s 重放窗口 + domain 精确匹配 | 可伪造任意 ASN 登录 |
| FindNOC → Backend | 服务端 token（仅 Bot 后端持有） | 可把任意 UID 绑定到任意 ASN |

### 1.5 与 `Potat0000/dn42-bot` 的架构差异

| 维度 | dn42-bot（旧） | 本项目（Autopeer） |
|---|---|---|
| 控制通道 | Server → Agent，HTTP POST 明文 | Node → Backend，WSS + TLS，请求/响应信封 |
| 节点身份 | Header 里的共享 Secret | 每节点独立 Bearer token，可单独轮换 |
| 状态存储 | Agent 无数据库，配置即状态 | Backend SQLite 存 Peer/Node/User/审计；节点仍以文件为准 |
| 认证 | 聊天内输入特权码 | Kioubit ECDSA + Telegram Mini App + FindNOC |
| Web | 无 | 完整 SSR Web UI + 管理后台 |
| LG | Bot 内命令直连 Agent | 公开 Web LG + Bot LG，统一限流与审计 |
| 部署语义 | 成功/失败 | `ok` 与 `applied` 双维度 + `deploy_output` 留档 |
| 并发控制 | 线程池 | 节点内信号量（LG）+ `deployMu`（部署串行） |

### 1.6 源码目录结构

```text
dn42/
├── app/
│   ├── main.py                 # FastAPI 入口：lifespan 守卫、Session、异常处理、router 注册
│   ├── config.py               # Settings（pydantic-settings）
│   ├── node_ws.py              # NodeHub / NodeConnection / WSS 路由 / 状态清洗
│   ├── api/telegram.py         # Bot-only REST（9 个端点）
│   ├── auth/
│   │   ├── kioubit.py          # ECDSA 验签
│   │   ├── findnoc.py          # FindNOC HTTP 客户端
│   │   ├── service.py          # challenge / user upsert / binding
│   │   └── session.py          # Session cookie 读写
│   ├── bot/main.py             # aiogram Bot（命令 + FSM + LG 回调）
│   ├── db/
│   │   ├── models.py           # 7 张表
│   │   ├── session.py          # engine / SessionLocal / get_db
│   │   └── init_db.py          # create_all + 列补齐 + 索引
│   ├── peer/
│   │   ├── validation.py       # 输入校验 + ASN 派生
│   │   ├── config.py           # wg/bird/user 配置渲染
│   │   ├── service.py          # create/update/delete/deploy/preview 编排
│   │   ├── deploy.py           # 调用 nodes 的 peers.deploy / peers.remove
│   │   └── queries.py          # joinedload 查询封装
│   ├── lg/
│   │   ├── validation.py       # query_type/target 校验
│   │   ├── ratelimit.py        # 进程内滑动窗口
│   │   ├── client.py           # NodeClient
│   │   └── summary.py          # peer 状态摘要
│   ├── web/
│   │   ├── deps.py             # templates / flash / require_admin / Pagination
│   │   ├── pages.py            # 首页 / 登录 / 回调
│   │   ├── portal.py           # 用户自助
│   │   ├── admin.py            # 管理后台
│   │   └── lg.py               # 公开 LG
│   ├── templates/              # Jinja2（base + 用户页 + admin/*）
│   ├── static/                 # app.js / styles.css / kioubit-auth-button.js
│   └── keys/public_key.pem     # Kioubit 公钥
├── cmd/node/main.go            # Go 节点入口
├── internal/
│   ├── config/config.go        # config.json 解析与默认值
│   ├── api/server.go           # 命令分发、并发信号量、部署串行化
│   ├── runner/runner.go        # 固定 argv、校验、原子写、wg/bird 操作
│   └── backend/client.go       # WSS 客户端（手写握手与帧）+ 心跳 + 状态采集
├── docs/{node-api.md,auth-flow.md}
├── start.py                    # 本地启动器（前后端 + Bot）
├── .env.example
├── config.example.json
├── requirements.txt
├── pyproject.toml
└── go.mod
```

---

## 2. 部署与运行

### 2.1 环境前提

| 项 | 要求 | 说明 |
|---|---|---|
| dn42 ASN | 已注册，且拥有可宣告的前缀 | 用于 `LOCAL_ASN` 与 BGP `from dnpeers` 模板 |
| 控制平面主机 | Python 3.11+，可被节点出站访问 443 | 域名必须与 Kioubit 注册的 domain 精确一致 |
| 每台 PoP | Linux、root、`wg-quick`、`bird2`、`iproute2`、`ping`、`traceroute`、`mtr` | 节点服务需要 root 才能创建接口与写 `/etc` |
| BIRD | 已存在 `template bgp dnpeers`，`local as <你的 ASN>` | 节点只写 peer 片段，不改主配置 |
| Telegram | Bot Token；Bot 的 domain 在 Kioubit 侧登记 | Mini App 的 `return` 必须落在已登记 domain |
| 反向代理 | nginx/Caddy，支持 WebSocket upgrade | Backend 默认只监听 127.0.0.1 |

**必须**在节点上预先准备好 BIRD 模板，否则生成的片段无法被 `birdc c` 加载：

```text
template bgp dnpeers {
  local as 4242420000;
  ipv4 {
    import filter dn42_import_filter;
    export filter dn42_export_filter;
  };
  ipv6 {
    import filter dn42_import_filter;
    export filter dn42_export_filter;
  };
}
```

模板的具体过滤规则由各 dn42 网络自定，本项目只负责生成 `protocol bgp ... from dnpeers { ... }` 片段。

### 2.2 本地快速启动：`start.py`

`start.py` 是一个零依赖启动器，负责解析 `.env`、检查 Python 依赖、启动 Backend 与 Bot，并把两路输出加上前缀。

```bash
# 最简：同时启动 backend + bot（要求 .env 里已有真实密钥）
python start.py

# 本地测试：允许 HTTP 与占位密钥
python start.py --allow-http

# 只启动后端（调试 Web）
python start.py --backend-only --host 127.0.0.1 --port 8000

# 只启动 Bot（后端已在别处运行）
python start.py --bot-only
```

**行为规格**

1. `parse_env(path)`：逐行读取 `.env`，忽略空行与 `#` 注释，按第一个 `=` 切分，去除值两端的成对引号，写入 `os.environ`（**不覆盖**已存在的变量）。
2. `backend_python()`：优先 `sys.executable`，否则回退 `python3`。
3. `missing_modules()`：用 `importlib.util.find_spec` 检查 `fastapi`、`uvicorn`、`sqlalchemy`、`aiogram`、`pydantic_settings`、`cryptography`，缺失时打印 `pip install -r requirements.txt` 并退出。
4. `--allow-http`：设置 `ALLOW_INSECURE_DEFAULTS=1`，并把 `HOST` 默认改为 `0.0.0.0`（便于容器/局域网访问）。**生产禁用**。
5. `public_base_url()`：根据 `DOMAIN` 是否含 scheme 决定 `http://` 或 `https://`，用于日志显示。
6. `start_process(cmd, name, env)`：`subprocess.Popen`，`stdout=PIPE`，`stderr=STDOUT`，`bufsize=1`，`text=True`。
7. `stream_output(proc, name)`：逐行读取并打印 `[backend] ...` / `[bot] ...`，进程退出时打印退出码。
8. `main()`：注册 `SIGINT`/`SIGTERM`，收到后先 `terminate()` 两个子进程，`wait(timeout=5)`，超时则 `kill()`。

**⚠️** `start.py` 只适合开发。生产环境应由 systemd/supervisor 分别托管 Backend 与 Bot，避免启动器成为单点。

### 2.3 `.env` 全量配置

Backend 通过 `pydantic-settings` 读取 `.env`（`extra="ignore"`）。字段名不区分大小写，环境变量优先于 `.env`。

| 变量 | 默认值 | 必填 | 说明 |
|---|---|---|---|
| `APP_NAME` | `dn42 Autopeer` | 否 | 出现在页面标题与导航 |
| `HOST` | `127.0.0.1` | 否 | uvicorn 绑定地址 |
| `PORT` | `8000` | 否 | uvicorn 端口 |
| `DOMAIN` | `127.0.0.1:8000` | **是** | 对外域名（可带 scheme）。用于 `base_url`、`auth_domain`、Kioubit 的 `return` 校验 |
| `SESSION_SECRET` | `dev-session-secret` | **是** | SessionMiddleware 签名密钥；占位值会拒绝启动 |
| `DATABASE_URL` | `sqlite:///./autopeer.db` | 否 | SQLAlchemy URL |
| `LOCAL_ASN` | 空 | **是** | 本网络 ASN（纯数字或 `AS` 前缀），用于节点回退与管理员判定 |
| `WIREGUARD_PRIVATE_KEY_PLACEHOLDER` | `{{WIREGUARD_PRIVATE_KEY}}` | 否 | 渲染节点侧 wg 配置时写入的占位符，由节点服务替换 |
| `KIOUBIT_PUBLIC_KEY_PATH` | `app/keys/public_key.pem` | **是** | Kioubit 验签公钥（PEM） |
| `TELEGRAM_BOT_TOKEN` | 空 | Bot 必填 | aiogram Token |
| `TELEGRAM_BACKEND_SECRET` | `dev-telegram-secret` | **是** | Bot 调 Backend 的共享密钥；占位值会拒绝启动 |
| `TELEGRAM_BACKEND_URL` | 空 | 否 | Bot 访问 Backend 的地址；空则用 `base_url` |
| `FINDNOC_API_URL` | `https://findnoc.ox5.cc` | 否 | FindNOC 基址 |
| `FINDNOC_API_TOKEN` | 空 | 否 | 空 = 禁用 FindNOC 快速登录 |
| `ALLOW_INSECURE_DEFAULTS` | `0` | 否 | `1` 时允许占位密钥并关闭 Secure Cookie |
| `LG_RATE_LIMIT` | `20` | 否 | 每 IP 每窗口次数；`0` 关闭限流 |
| `LG_RATE_WINDOW_SECONDS` | `60` | 否 | 限流窗口秒数 |
| `FORWARDED_IP_HEADER` | 空 | 否 | 仅在可信反代后设为 `X-Forwarded-For`；否则留空 |

`.env.example` 原文：

```dotenv
APP_NAME="dn42 Autopeer"
HOST="127.0.0.1"
PORT="8000"
DOMAIN="example.com"
SESSION_SECRET="change-me"
DATABASE_URL="sqlite:///./autopeer.db"
LOCAL_ASN="4242420000"

KIOUBIT_PUBLIC_KEY_PATH="app/keys/public_key.pem"

TELEGRAM_BOT_TOKEN=""
TELEGRAM_BACKEND_SECRET="change-me-too"
TELEGRAM_BACKEND_URL="http://127.0.0.1:8000"

FINDNOC_API_URL="https://findnoc.ox5.cc"
FINDNOC_API_TOKEN=""

ALLOW_INSECURE_DEFAULTS="0"

LG_RATE_LIMIT="20"
LG_RATE_WINDOW_SECONDS="60"
FORWARDED_IP_HEADER=""
```

**⚠️** `DOMAIN` 必须写成 Kioubit 登记的那个 host（含端口则一并写）。`auth_domain` 会剥掉 scheme 与路径，只留 `netloc`，Kioubit 验签时与之**精确比较**，`www.` 前缀不同也会失败。

### 2.4 节点 `config.json` 全量配置

Go 侧使用 `encoding/json` 的 `Decoder.DisallowUnknownFields()`，**未知字段会导致启动失败**，便于尽早发现拼写错误。

| 字段 | 类型 | 默认值 | 必填 | 说明 |
|---|---|---|---|---|
| `name` | string | 无 | **是** | 节点名，必须与 Backend `nodes.name` 完全一致 |
| `token` | string | 无 | **是** | 节点 Bearer token，由管理员创建节点时生成 |
| `backend_wss_url` | string | 无 | **是** | `wss://domain/api/nodes/ws`；`http(s)` 会自动转 `ws(s)` |
| `max_concurrency` | `*int` | 4 | 否 | LG 类命令并发上限；`0` 表示不限制（仅测试用） |
| `command_timeout_seconds` | int | 12 | 否 | 子进程超时；超时返回 `command timed out` |
| `birdc_path` | string | `/usr/sbin/birdc` | 否 | birdc 可执行文件 |
| `ping_path` | string | `ping` | 否 | 依赖 PATH 时可只写名字 |
| `traceroute_path` | string | `traceroute` | 否 | |
| `mtr_path` | string | `mtr` | 否 | |
| `wg_path` | string | `wg` | 否 | 仅用于状态查询 |
| `wg_quick_path` | string | `/usr/bin/wg-quick` | 否 | 用于 up/down |
| `wireguard_peer_dir` | string | `/etc/wireguard` | 否 | 每 Peer 一个 `<name>.conf` |
| `bird_peer_dir` | string | `/etc/bird/peers` | 否 | 每 Peer 一个 `<name>.conf` |
| `bird_peer_group` | `*string` | `bird` | 否 | `null`/缺省 → `bird`；显式 `""` → 不 chown |
| `deploy_reload_cmd` | string | `birdc c` | 否 | 部署后执行的 reload 命令（按空白切分，不经 shell） |
| `wireguard_private_key` | string | 无 | **是** | 44 字符 base64；会替换配置里的占位符 |
| `wireguard_public_key` | string | 无 | **是** | 44 字符 base64；经 `pubkey` 命令上报给 Backend |

`config.example.json` 原文：

```json
{
  "name": "frankfurt",
  "token": "change-me",
  "backend_wss_url": "wss://autopeer.example.com/api/nodes/ws",
  "max_concurrency": 4,
  "command_timeout_seconds": 12,
  "birdc_path": "/usr/sbin/birdc",
  "ping_path": "ping",
  "traceroute_path": "traceroute",
  "mtr_path": "mtr",
  "wg_path": "wg",
  "wg_quick_path": "/usr/bin/wg-quick",
  "wireguard_peer_dir": "/etc/wireguard",
  "bird_peer_dir": "/etc/bird/peers",
  "bird_peer_group": "bird",
  "deploy_reload_cmd": "birdc c",
  "wireguard_private_key": "change-me",
  "wireguard_public_key": "change-me"
}
```

**指针类型的语义（必须一致）**

```go
func (c Config) Concurrency() int {
    if c.MaxConcurrency == nil { return defaultMaxConcurrency } // 4
    if *c.MaxConcurrency < 0    { return defaultMaxConcurrency }
    return *c.MaxConcurrency                                     // 0 = 无上限
}

func (c Config) BirdGroup() string {
    if c.BirdPeerGroup == nil { return defaultBirdPeerGroup }    // "bird"
    return *c.BirdPeerGroup                                      // "" = 不 chown
}
```

若把 `*int` 改成 `int`，就永远无法区分“未配置”和“显式 0”，会失去“0 = 不限制”的能力；`bird_peer_group` 同理，无法表达“显式不 chown”。

**启动校验（`cmd/node/main.go`）**

```go
cfg, err := config.Load(*configPath)
if err != nil { log.Fatalf("config: %v", err) }
if !runner.ValidWireGuardKey(cfg.WireGuardPrivateKey) { log.Fatal("wireguard_private_key invalid") }
if !runner.ValidWireGuardKey(cfg.WireGuardPublicKey)  { log.Fatal("wireguard_public_key invalid") }
if cfg.BackendWSURL == "" { log.Fatal("backend_wss_url required") }
if cfg.Name == ""         { log.Fatal("name required") }
r := runner.New(cfg)
srv := api.New(r, cfg.Concurrency())
client := backend.New(cfg, srv, logger)
client.Run(ctx)
```

### 2.5 systemd 单元示例

**Backend**

```ini
[Unit]
Description=dn42 Autopeer backend
After=network-online.target

[Service]
Type=simple
User=autopeer
Group=autopeer
WorkingDirectory=/opt/dn42
EnvironmentFile=/opt/dn42/.env
ExecStart=/opt/dn42/.venv/bin/uvicorn app.main:app --host 127.0.0.1 --port 8000
Restart=always
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=/opt/dn42

[Install]
WantedBy=multi-user.target
```

**Bot**

```ini
[Unit]
Description=dn42 Autopeer Telegram bot
After=network-online.target autopeer-backend.service

[Service]
Type=simple
User=autopeer
Group=autopeer
WorkingDirectory=/opt/dn42
EnvironmentFile=/opt/dn42/.env
ExecStart=/opt/dn42/.venv/bin/python -m app.bot.main
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

**Node service（在 PoP 上）**

```ini
[Unit]
Description=dn42 Autopeer node service
After=network-online.target bird.service wg-quick@wg0.service
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/dn42-node -config /etc/dn42-node/config.json
Restart=always
RestartSec=5
# 节点需要写 /etc/wireguard 与 /etc/bird/peers，不能启用 ProtectSystem=strict

[Install]
WantedBy=multi-user.target
```

### 2.6 nginx 反代（必须支持 WebSocket）

```nginx
server {
    listen 443 ssl http2;
    server_name autopeer.example.com;

    ssl_certificate     /etc/letsencrypt/live/autopeer.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/autopeer.example.com/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        # 仅在确认反代会覆盖该头时启用 FORWARDED_IP_HEADER=X-Forwarded-For
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location /api/nodes/ws {
        proxy_pass http://127.0.0.1:8000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_read_timeout 120s;   # 必须大于心跳周期 20s
        proxy_send_timeout 120s;
    }
}
```

**⚠️** 若 `proxy_read_timeout` 小于 20s，WSS 会被反代切断；Go 侧会在 5s 后重连，表现为日志中反复 `dial`，但功能“时好时坏”。

### 2.7 新增一台节点的完整操作

1. 管理员登录 `/admin/nodes`，填写：
   - Name：`frankfurt`（唯一，后续不可随意改名，节点 `config.json` 必须同步）
   - Location：`DE`
   - Public address：`de-fra.example.net` 或 `172.20.0.1`（**不带 scheme/端口**，提交时会被 `normalize_node_host` 清洗）
   - ASN：留空表示用 `LOCAL_ASN`
   - DN42 IPv4 / IPv6：节点自身在 dn42 内的地址，展示给对端
   - Enabled：勾选
2. 提交后跳转节点详情页，复制 **API token**。
3. 在 PoP 上写 `/etc/dn42-node/config.json`，填入 `name`、`token`、`backend_wss_url`、WG 私钥/公钥、路径。
4. `systemctl enable --now dn42-node`。
5. 回到 `/admin/nodes/{id}/edit`，确认 `Connection: online`；点击 **Refresh key**，把节点上报的 WG 公钥写入 `nodes.wg_public_key`。
6. 此时该节点才会出现在 `/portal/new` 的节点下拉框（仅 `enabled=true`）。

**token 轮换**：详情页 **Reset token** 生成新的 `secrets.token_urlsafe(32)`。旧连接不会被立即踢掉（`_lookup_node_auth` 在下次建连时校验），但节点重连会失败，必须同步更新 `config.json`。若要立即断开，重启节点服务。

### 2.8 权限与目录

| 路径 | 权限 | 属主 | 说明 |
|---|---|---|---|
| `/etc/wireguard/` | `0750` | `root:root` | 节点服务 `MkdirAll` 保证存在 |
| `/etc/wireguard/DN42_*.conf` | `0640` | `root:root` | 原子写入（临时文件 + `Rename`） |
| `/etc/bird/peers/` | `0750` | `root:root` | |
| `/etc/bird/peers/DN42_*.conf` | `0640` | `root:bird` | `chownToGroup` 让 BIRD 可读 |
| `/etc/dn42-node/config.json` | `0600` | `root:root` | 含私钥与 token |
| `autopeer.db` | `0600` | `autopeer` | 含所有用户与 token |

---

## 3. 配置与 FastAPI 入口

### 3.1 `Settings` 定义

`app/config.py` 是唯一配置源，**必须**保持字段名与 `.env` 一致：

```python
from functools import lru_cache
from urllib.parse import urlsplit
from pydantic_settings import BaseSettings, SettingsConfigDict

INSECURE_SECRET_VALUES = frozenset(
    {"dev-session-secret", "change-me", "dev-telegram-secret", "change-me-too", ""}
)

class Settings(BaseSettings):
    app_name: str = "dn42 Autopeer"
    host: str = "127.0.0.1"
    port: int = 8000
    domain: str = "127.0.0.1:8000"
    session_secret: str = "dev-session-secret"
    database_url: str = "sqlite:///./autopeer.db"
    local_asn: str = ""
    wireguard_private_key_placeholder: str = "{{WIREGUARD_PRIVATE_KEY}}"

    kioubit_public_key_path: str = "app/keys/public_key.pem"

    telegram_bot_token: str = ""
    telegram_backend_secret: str = "dev-telegram-secret"
    telegram_backend_url: str = ""

    findnoc_api_url: str = "https://findnoc.ox5.cc"
    findnoc_api_token: str = ""

    allow_insecure_defaults: bool = False
    lg_rate_limit: int = 20
    lg_rate_window_seconds: int = 60
    forwarded_ip_header: str = ""

    model_config = SettingsConfigDict(env_file=".env", extra="ignore")
```

### 3.2 派生属性

| 属性 | 逻辑 | 用途 |
|---|---|---|
| `base_url` | `domain` 去尾斜杠；无 scheme 时补 `https://` | 页面显示、Bot 拼回调 |
| `bot_backend_url` | `telegram_backend_url` 去尾斜杠，空则 `base_url` | Bot 的 HTTP 基址 |
| `auth_domain` | 去 scheme 后取 `netloc`（无 scheme 时按 `//domain` 解析） | Kioubit 验签的 domain 精确匹配 |
| `findnoc_enabled` | `findnoc_api_token.strip()` 非空 | 决定 Bot `/login` 是否先试 FindNOC |
| `insecure_default_secrets()` | 检查 `SESSION_SECRET` 与 `TELEGRAM_BACKEND_SECRET` 是否在占位集合 | lifespan 启动守卫 |

```python
@property
def base_url(self) -> str:
    domain = self.domain.strip().rstrip("/")
    if domain.startswith(("http://", "https://")):
        return domain
    return f"https://{domain}"

@property
def auth_domain(self) -> str:
    domain = self.domain.strip().rstrip("/")
    parsed = urlsplit(domain if "://" in domain else f"//{domain}")
    return (parsed.netloc or parsed.path).rstrip("/")
```

`get_settings()` 使用 `@lru_cache`，进程内只实例化一次。修改 `.env` 必须重启进程。

### 3.3 `app/main.py` 入口

```python
@asynccontextmanager
async def lifespan(app: FastAPI):
    settings = get_settings()
    insecure = settings.insecure_default_secrets()
    if insecure and not settings.allow_insecure_defaults:
        raise RuntimeError(
            "Refusing to start with default secrets: " + ", ".join(insecure)
            + ". Set ALLOW_INSECURE_DEFAULTS=1 for local testing only."
        )
    init_db()
    yield

app = FastAPI(title=settings.app_name, lifespan=lifespan)
app.add_middleware(
    SessionMiddleware,
    secret_key=settings.session_secret,
    https_only=not settings.allow_insecure_defaults,
    same_site="lax",
)
app.mount("/static", StaticFiles(directory="app/static"), name="static")
```

**异常处理器**

```python
@app.exception_handler(StarletteHTTPException)
async def http_exception_handler(request: Request, exc: StarletteHTTPException):
    if exc.status_code in {401, 403, 404, 500} and "text/html" in request.headers.get("accept", ""):
        return templates.TemplateResponse(
            request, "error.html",
            {"code": exc.status_code, "title": ..., "detail": exc.detail},
            status_code=exc.status_code,
        )
    return JSONResponse({"detail": exc.detail}, status_code=exc.status_code)
```

这保证：浏览器访问不存在的页面得到样式化 404；Bot/前端 fetch 得到 `{"detail": ...}`，便于统一处理。

**Router 注册顺序（原实现）**

```python
app.include_router(telegram.router)   # /api/telegram/*
app.include_router(node_ws.router)    # /api/nodes/ws
app.include_router(pages.router)      # /, /login, /logout, /auth/kioubit/callback, /telegram/auth
app.include_router(portal.router)     # /portal/*
app.include_router(admin.router)      # /admin/*
app.include_router(lg.router)         # /lg
```

顺序对功能影响不大，但**必须**保证 `/api/nodes/ws` 不被页面路由的 catch-all 抢占。若后续新增 SPA 或通配路由，应放在最后。

### 3.4 不安全默认值守卫

**必须**保留。占位密钥会让 Session 可被伪造、Bot API 可被任意调用：

- 触发条件：`SESSION_SECRET` 或 `TELEGRAM_BACKEND_SECRET` 的 `strip()` 结果落在
  `{"dev-session-secret", "change-me", "dev-telegram-secret", "change-me-too", ""}`。
- 默认行为：`lifespan` 抛 `RuntimeError`，进程退出。
- 例外：`ALLOW_INSECURE_DEFAULTS=1`（仅本地）。
- 同时 `https_only=False`，否则本地 HTTP 下 Session Cookie 不会回传，登录看起来“没生效”。

**⚠️** 只检查两个密钥，不检查 `TELEGRAM_BOT_TOKEN` 与 `FINDNOC_API_TOKEN`。后者为空是合法的“禁用”状态。

### 3.5 初始化数据库

`app/db/init_db.py` 在 lifespan 中调用一次，承担“建表 + 轻量迁移”：

```python
def create_schema() -> None:
    Base.metadata.create_all(bind=engine)

def _ensure_node_columns(conn) -> None:
    # 6 列：wg_public_key, asn, dn42_ipv4, dn42_ipv6, system_status_json, last_seen_at
    ...

def _ensure_peer_request_columns(conn) -> None:
    # 4 列：wg_mtu, bgp_extended, deploy_status, deploy_output
    ...

def _ensure_indexes(conn) -> None:
    # nodes.name, peer_requests(node_id, asn), lg_queries.created_at
```

策略说明：不使用 Alembic，而是“`create_all` + `PRAGMA table_info` 检查缺失列后 `ALTER TABLE ADD COLUMN`”。优点是无迁移文件依赖；缺点是**不能删列、不能改类型**。复刻时若要长期演进，建议引入 Alembic，但首版保持原实现即可。

---

## 4. 数据模型

### 4.1 实体关系

```text
users 1 ──── n asn_identities
  │ 1
  ├──────── n telegram_bindings
  ├──────── n peer_requests
  └──────── n lg_queries (user_id 可空)
nodes 1 ──── n peer_requests
nodes 1 ──── n lg_queries
auth_challenges 独立表（token 唯一，一次性）
```

设计要点：

1. **Peer 归属 `users` 而不是 Telegram UID**。`/logout` 只删 `telegram_bindings`，Peer 保留；重新绑定后仍能看到自己的 Peer。
2. **Node 与 Peer 都用 UUID4 字符串主键**，URL 不可枚举，也不泄露创建顺序与总量。
3. **`users.primary_asn` 唯一**：一个 ASN 对应一个用户；多 ASN 的历史写入 `asn_identities` 作为审计。
4. **`peer_requests` 有 `UNIQUE(node_id, asn)`**：同一节点上一个 ASN 只能有一条 Peer，这是 WG 端口可派生的前提。

### 4.2 表结构

#### users

| 列 | 类型 | 默认 | 约束 | 说明 |
|---|---|---|---|---|
| `id` | INTEGER | 自增 | PK | |
| `primary_asn` | VARCHAR(32) | | 唯一、索引 | 纯数字字符串，不含 `AS` |
| `first_email` | VARCHAR(255) | NULL | | 首次登录时 Kioubit 返回的邮箱 |
| `is_admin` | BOOLEAN | false | | 每次登录按 `LOCAL_ASN` 重算，不手工维护 |
| `created_at` | DATETIME | `utcnow()` | | 带时区 |
| `last_login_at` | DATETIME | NULL | | 每次成功登录更新 |

#### asn_identities

| 列 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `id` | INTEGER | 自增 | PK |
| `user_id` | INTEGER | | FK → users.id，索引 |
| `asn` | VARCHAR(32) | | 索引 |
| `mnt_json` | TEXT | `"[]"` | Kioubit 返回的 maintainer 列表（JSON 字符串） |
| `effective_mnt` | VARCHAR(128) | NULL | 选定的 maintainer |
| `allowed4_json` | TEXT | `"[]"` | 允许的 IPv4 前缀 |
| `allowed6_json` | TEXT | `"[]"` | 允许的 IPv6 前缀 |
| `authtype` | VARCHAR(64) | NULL | `kioubit` / `findnoc` / `admin-manual` |
| `verified_at` | DATETIME | `utcnow()` | |

#### auth_challenges

| 列 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `id` | INTEGER | 自增 | PK |
| `token` | VARCHAR(128) | | 唯一、索引；`secrets.token_urlsafe(32)` |
| `purpose` | VARCHAR(32) | | `web` 或 `telegram`，索引 |
| `telegram_user_id` | VARCHAR(64) | NULL | `telegram` 用途时绑定预定的 UID |
| `telegram_chat_id` | VARCHAR(64) | NULL | |
| `expires_at` | DATETIME | | 索引；创建时间 + 600s |
| `consumed_at` | DATETIME | NULL | 非空即已使用，不能复用 |
| `created_at` | DATETIME | `utcnow()` | |

#### telegram_bindings

| 列 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `id` | INTEGER | 自增 | PK |
| `user_id` | INTEGER | | FK → users.id，索引 |
| `telegram_user_id` | VARCHAR(64) | | **唯一**、索引；一个 UID 只能绑一个用户 |
| `telegram_chat_id` | VARCHAR(64) | | 索引；用于主动推送（当前未使用） |
| `username` | VARCHAR(64) | NULL | 展示用 `@name` |
| `linked_at` | DATETIME | `utcnow()` | |

#### nodes

| 列 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `id` | VARCHAR(36) | UUID4 | PK |
| `name` | VARCHAR(64) | | 唯一、索引；与节点 `config.json` 的 `name` 一致 |
| `location` | VARCHAR(128) | `""` | 展示用 |
| `url` | VARCHAR(512) | | 节点公网地址（纯 host，无 scheme/端口） |
| `token` | VARCHAR(255) | `""` | Bearer token；为空则**永不可连** |
| `wg_public_key` | VARCHAR(128) | `""` | 节点上报，展示给对端 |
| `asn` | VARCHAR(32) | `""` | 留空回退 `LOCAL_ASN` |
| `dn42_ipv4` | VARCHAR(64) | `""` | 展示给对端 |
| `dn42_ipv6` | VARCHAR(64) | `""` | 展示给对端 |
| `enabled` | BOOLEAN | true | 禁用后隐藏于公开站点且拒绝 WSS |
| `last_seen_at` | DATETIME | NULL | 心跳/请求触发的最近在线时间 |
| `system_status_json` | TEXT | `"{}"` | 最近一次心跳的清洗后系统状态 |
| `created_at` | DATETIME | `utcnow()` | |

#### peer_requests

| 列 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `id` | VARCHAR(36) | UUID4 | PK |
| `user_id` | INTEGER | | FK → users.id，索引 |
| `asn` | VARCHAR(32) | | 对端 ASN，纯数字，索引 |
| `node_id` | VARCHAR(36) | | FK → nodes.id，索引 |
| `tunnel_type` | VARCHAR(32) | `wireguard` | 预留字段，当前只有 WG |
| `endpoint` | VARCHAR(255) | `""` | 空 = 对端拨号我方 |
| `wg_public_key` | VARCHAR(128) | | 对端 WG 公钥（44 字符） |
| `wg_mtu` | INTEGER | 1420 | `server_default="1420"` |
| `local_link_address` | VARCHAR(128) | `""` | 我方隧道地址（LLA 或 ULA） |
| `peer_link_address` | VARCHAR(128) | `""` | 对端隧道地址 |
| `peer_dn42_ipv4` | VARCHAR(64) | `""` | 对端 dn42 IPv4（信息展示） |
| `peer_dn42_ipv6` | VARCHAR(64) | `""` | 对端 dn42 IPv6（信息展示） |
| `bgp_extended` | BOOLEAN | true | 是否输出 `extended messages` / `extended next hop` |
| `status` | VARCHAR(32) | `pending` | `pending` / `approved` / `disabled`，索引 |
| `admin_note` | TEXT | `""` | 管理员备注 |
| `deploy_status` | VARCHAR(32) | `not_deployed` | `not_deployed` / `deploying` / `deployed` / `failed`，索引 |
| `deploy_output` | TEXT | `""` | 最近一次部署输出（含错误） |
| `deployed_at` | DATETIME | NULL | 最近一次 `applied=true` 的时间 |
| `created_at` | DATETIME | `utcnow()` | |
| `updated_at` | DATETIME | `utcnow()` | |

表级约束：`UniqueConstraint("node_id", "asn", name="uq_peer_node_asn")`。

#### lg_queries

| 列 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `id` | INTEGER | 自增 | PK |
| `user_id` | INTEGER | NULL | 公开查询为 NULL |
| `node_id` | VARCHAR(36) | | FK → nodes.id，索引 |
| `query_type` | VARCHAR(32) | | `ping` / `trace` / `mtr` / `route` |
| `target` | VARCHAR(255) | | 已校验的目标 |
| `ok` | BOOLEAN | false | 命令是否成功 |
| `result` | TEXT | `""` | 输出全文（审计用） |
| `created_at` | DATETIME | `utcnow()` | 索引（后台按时间倒序分页） |

### 4.3 状态机

**Peer 生命周期**

```text
                 create (Web / Bot / Admin)
                            │
                            ▼
                    status=pending
                    deploy_status=not_deployed
                            │
     管理员批准 / 直接创建（Bot 与 Portal 默认 approved）
                            ▼
                    status=approved
                            │
          deploy 成功 ──────┼────── deploy 失败
                            ▼                ▼
                 deployed           failed（ok=false 或异常）
                            │
                 update / redeploy
                            ▼
                 deploy_status=deploying → deployed | failed

管理员 disable → status=disabled（节点侧不自动拆除，需手动 delete）
```

**deploy_status 语义**

| 值 | 含义 | UI 展示 |
|---|---|---|
| `not_deployed` | 从未尝试或记录被清空 | 灰色 `not deployed` |
| `deploying` | 已提交节点，等待响应 | 黄色 `deploying` |
| `deployed` | 节点返回 `applied=true` | 绿色 `deployed` |
| `failed` | 节点返回 `ok=false`、超时、离线或校验失败 | 红色 `failed` |

**Node 状态**

`nodes.enabled` 是配置态；`online` 是运行时态（`NodeHub` 内存），不落库。二者组合：

| enabled | online | 行为 |
|---|---|---|
| true | true | 正常收发命令 |
| true | false | `NodeOfflineError`，部署失败并记录 |
| false | — | WSS 拒绝连接；`request` 抛 `ValueError("Node is disabled")`；公开页隐藏 |

**User 管理员状态**

```python
user.is_admin = normalize_asn(user.primary_asn) == normalize_asn(settings.local_asn)
```

每次 `upsert_user_from_kioubit` / `upsert_user_from_findnoc` 都重算。**不要**提供“手工设为管理员”的持久化入口，否则本地 ASN 变更后会留下越权账号（后台允许 toggle，但下次登录会被重算覆盖，这是刻意行为）。

### 4.4 索引与查询

`init_db._ensure_indexes` 建立：

- `nodes(name)`：WSS 按名字认证。
- `peer_requests(node_id, asn)`：唯一约束自带索引，覆盖“同节点同 ASN”检查。
- `lg_queries(created_at)`：后台审计分页按时间排序。

`app/peer/queries.py` 统一使用 `joinedload` 避免 N+1：

```python
def peer_with_node(db, peer_id): ...
def peers_for_user_with_nodes(db, user_id): ...
def owned_peer_with_node(db, peer_id, user_id): ...
def enabled_node_by_id(db, node_id): ...
def enabled_node_by_name(db, name): ...
```

**⚠️** 所有返回 ORM 对象的函数都要求调用方在同一个 `Session` 内完成序列化，或在关闭前把需要的字段拷贝出来。FastAPI 的 `Depends(get_db)` 在请求结束时才关闭 Session，跨 `await` 使用同一 ORM 对象可能触发 `DetachedInstanceError`。Bot API 的 `/status` 端点因此先快照再并发请求（见 §9.6）。

### 4.5 时间处理

- 全部时间用 `datetime.now(UTC)`（`utcnow()`），字段声明 `DateTime(timezone=True)`。
- SQLite 实际不保存时区，读回可能是 naive。比较时必须保证双方都 aware，或统一转成 UTC naive。
- 页面上显示时显式追加 `UTC` 文案（如节点详情的 `Last seen`），避免读者误解为本地时间。
- Kioubit 验签的时间偏差判断用 `abs(now - auth_time) > 60`，`now` 与 `auth_time` 都必须是 aware UTC。

### 4.6 实现陷阱

1. **删除 Node 前必须没有 Peer**。后台 `POST /admin/nodes/{id}/delete` 检测到关联 Peer 时拒绝（返回 flash 错误），否则留下指向不存在节点的孤儿记录。
2. **删除 User 没有实现**。若手工删库，`telegram_bindings` 与 `peer_requests` 不会级联删除（未配置 `ondelete`），会留下悬空外键。
3. **`peer_requests.asn` 不做唯一约束**，唯一性只在 `(node_id, asn)` 上；同一 ASN 可在不同节点各有一条 Peer。
4. **`system_status_json` 是字符串**，不是 SQLite JSON 类型。读取时统一走 `_load_system_status` + `_clean_system_status`，避免旧数据里混入异常字段。
5. **`deploy_output` 无长度上限**。节点返回的大段输出会整段入库，建议在应用层截断（原实现未截断，见 §18）。

---

## 5. Node WSS 协议

这是整个系统最关键、也最容易被“看起来能连上但命令不通”坑到的部分。**必须**逐字段一致。

### 5.1 连接建立

```http
GET /api/nodes/ws?name=frankfurt HTTP/1.1
Host: autopeer.example.com
Upgrade: websocket
Connection: Upgrade
Sec-WebSocket-Key: <base64 16 字节随机>
Sec-WebSocket-Version: 13
Authorization: Bearer <node.token>
```

Backend 认证流程（`_authenticate_node` → `_lookup_node_auth`）：

1. 读取 `name` 查询参数，空则拒绝。
2. 从 `Authorization` 头取 `Bearer ` 后的 token；前缀不匹配则为空串。
3. 在工作线程中查库（避免阻塞事件循环）。
4. 节点不存在、`enabled=false`、`token` 为空、`compare_digest` 不匹配，任一条件成立即返回 `None`。
5. 认证失败：`await websocket.close(code=1008)`，**不 accept**。
6. 认证成功：`accept()`，`NodeHub.register`。

**⚠️** 不要在 accept 之前 `send_json`，Starlette 会抛 `RuntimeError`。认证失败只能 close。

**为什么 token 为空的节点永不可连**：节点名会出现在公开状态页（`node.name`），是半公开信息。若允许空 token 连接，任何知道名字的人都能冒充节点接收部署指令。

### 5.2 消息信封

**上行：hello（连接后立即发送一次）**

```json
{
  "type": "hello",
  "public_key": "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=",
  "system": {
    "hostname": "router1",
    "os": "linux",
    "arch": "amd64",
    "uptime_seconds": 123456,
    "load_1": 0.12,
    "load_5": 0.08,
    "load_15": 0.05,
    "cpu_percent": 7.5,
    "memory_percent": 31.2,
    "memory_used_bytes": 1073741824,
    "memory_total_bytes": 3435973836,
    "network_rx_bytes_per_second": 1024.5,
    "network_tx_bytes_per_second": 2048.0,
    "goroutines": 8,
    "wireguard": {"ok": true, "output": "..."},
    "bird": {"ok": true, "output": "..."}
  }
}
```

**上行：heartbeat（每 20s）**：与 `hello` 完全同构，仅 `type` 不同。

**下行：request**

```json
{
  "type": "request",
  "id": "3f2c9a1b8d7e4f60a1b2c3d4e5f60718",
  "command": "peers.deploy",
  "payload": { }
}
```

**上行：response（成功）**

```json
{
  "type": "response",
  "id": "3f2c9a1b8d7e4f60a1b2c3d4e5f60718",
  "result": {"ok": true, "applied": true, "output": "...", "files": ["..."]}
}
```

**上行：response（命令级错误）**

```json
{
  "type": "response",
  "id": "3f2c9a1b8d7e4f60a1b2c3d4e5f60718",
  "error": "invalid json"
}
```

约定：

- `id` 由 Backend 生成，`uuid.uuid4().hex`（32 字符）。
- Node 必须原样回传 `id`；不匹配的响应会被丢弃。
- `result` 必须是 JSON 对象；不是对象时 Backend 抛 `NodeRequestError("Node returned an invalid response")`。
- `error` 非空时 Backend 抛 `NodeRequestError(error)`，不会读取 `result`。
- 非 `request` 类型的下行消息，Node 直接 `continue`。
- 非 `response` / `hello` / `heartbeat` 的上行消息，Backend 记 debug 日志后忽略。

### 5.3 命令矩阵

| command | payload | result 字段 | 并发受限 | 说明 |
|---|---|---|---|---|
| `pubkey` | `{}` | `public_key` | 否 | 返回节点配置中的公钥 |
| `lg.ping` | `{"target": "..."}` | `ok`, `output` | **是** | `ping -c 4 -W 3 <target>` |
| `lg.trace` | `{"target": "..."}` | `ok`, `output` | **是** | `traceroute -n -q 1 -w 2 -m 20 [-6] <target>` |
| `lg.mtr` | `{"target": "..."}` | `ok`, `output` | **是** | `mtr --report --report-cycles 4 --no-dns --report-wide [-6] <target>` |
| `lg.route` | `{"target": "..."}` | `ok`, `output` | **是** | `birdc show route for <target>` |
| `peers.status` | `{"protocol_name": "..."}` | `ok`, `output`, `wireguard` | **是** | BIRD + WG 两段输出 |
| `peers.deploy` | 见下 | `ok`, `applied`, `output`, `files` | 否（`deployMu` 串行） | 写配置并重启接口 |
| `peers.remove` | 见下 | `ok`, `applied`, `output`, `files` | 否（`deployMu` 串行） | 拆除并删文件 |

**`peers.deploy` payload**

```json
{
  "request_id": "f81d4fae-7dec-11d0-a765-00a0c91e6bf6",
  "asn": "4242420090",
  "node": "frankfurt",
  "protocol_name": "DN42_0090_1a2b",
  "wireguard_config": "# Generated ...\n[Interface]\n...",
  "bird_config": "# Generated ...\nprotocol bgp DN42_0090_1a2b from dnpeers {\n...}\n"
}
```

**`peers.remove` payload**

```json
{
  "request_id": "f81d4fae-7dec-11d0-a765-00a0c91e6bf6",
  "protocol_name": "DN42_0090_1a2b"
}
```

**`peers.status` 示例响应**

```json
{
  "ok": true,
  "output": "BIRD 2.15.1 ready.\nName       Proto      State       Since ...\nDN42_0090_1a2b BGP Established ...",
  "wireguard": "interface: DN42_0090_1a2b\n  public key: ...\n  latest handshake: 12 seconds ago"
}
```

`ok` 只反映 BIRD 命令；即使接口不存在，`wireguard` 也会返回 `No such device` 供展示。

### 5.4 超时、重试与错误映射

| 场景 | Backend 异常 | Bot/Web 表现 |
|---|---|---|
| 节点不在 `_connections` | `NodeOfflineError("Node 'x' is offline")` | `node offline`，部署标记 failed |
| `enabled=false` | `ValueError("Node is disabled")` | 同上看，管理端提示 |
| 20s 内无响应 | `NodeRequestError("Node 'x' timed out running peers.deploy")` | 输出写入 `deploy_output` |
| 响应带 `error` | `NodeRequestError(error)` | 原文展示 |
| `result` 非对象 | `NodeRequestError("Node returned an invalid response")` | |
| 连接在等待中断开 | `NodeOfflineError("... disconnected")` | 由 `fail_pending` 触发 |
| 同一节点新连接顶替旧连接 | 旧连接 `pending` 全部失败，close code `4000` | |

**没有自动重试**。重试策略由调用方决定：`fetch_node_public_key` 失败返回 `None` 并保留旧值；Peer 部署失败只记录，不自动回滚。

### 5.5 时序细节

```text
Node                          Backend
 │  GET /api/nodes/ws?name=...   │
 │  Authorization: Bearer ...    │
 │──────────────────────────────>│ 查库 + compare_digest
 │<──────────────────────────────│ accept
 │  {"type":"hello",...}         │
 │──────────────────────────────>│ register → 写 last_seen/wg_pubkey
 │                               │
 │  {"type":"request","id":...}  │ ← 任意时刻（LG/部署/状态）
 │<──────────────────────────────│ 创建 Future 挂起
 │  {"type":"response","id":...} │
 │──────────────────────────────>│ set_result → 唤醒
 │                               │
 │  {"type":"heartbeat",...}     │ 每 20s
 │──────────────────────────────>│ 更新内存 + 60s 节流入库
 │                               │
 │  （TCP 断开）                  │
 │──────────────────────────────>│ unregister → fail_pending
 │                               │ 5s 后 Node 重连
```

### 5.6 心跳与状态持久化

- Node 每 20s 发送 heartbeat，内容包含系统指标与 `wg`/`bird` 状态**完整快照**。
- `wg`/`birdc` 子进程最多每 60s 执行一次，中间心跳复用缓存（`statusSampleInterval`）。这使心跳保持 20s 的活性，同时把子进程开销降到 1/3。
- Backend 每次心跳都更新内存 `NodeRuntime.last_seen_at`，但**入库最多每 60s 一次**（`STATUS_PERSIST_INTERVAL_SECONDS`），除非公钥变化。
- 入库在工作线程执行（`anyio.to_thread.run_sync`），避免同步 SQLAlchemy 阻塞事件循环。
- 命令成功返回时也会 `_mark_online`，但**不写库**（热路径不做 DB I/O）。

### 5.7 实现陷阱

1. **`send_lock` 必须存在**。部署响应、心跳、LG 响应可能并发写同一 WebSocket；Starlette 的 `send_json` 并发调用会交错帧，导致 Node 侧 JSON 解析失败。
2. **替换连接时先 `fail_pending` 再 close**。否则旧连接上的 Future 永远挂起，直到超时。
3. **`unregister` 必须校验 `current is connection`**。节点快速重连时，旧连接的 `finally` 可能在新连接注册之后执行；不校验会把新连接从 map 中删掉，导致“在线但命令发不出去”。
4. **`request_node_sync` 的三段回退**：优先 `anyio.from_thread.run`（在 worker 线程中）；若报“AnyIO worker thread”/“can only be run from”且当前线程没有运行中的 loop，则 `asyncio.run`；否则原样抛出。复刻时若省略此函数，Web 同步路由将无法调用异步 WSS。
5. **Node 侧读循环不设读超时**。依赖 TCP 与心跳保活；若中间设备静默丢包，只能靠反代 `proxy_read_timeout` 或 TCP keepalive 发现。
6. **JSON 帧上限 1 MiB**。`wg show` 或 BIRD 全量输出可能接近上限，Node 已截断到 64 KiB，但自定义命令要注意。
7. **`hello` 没有 `name` 字段**。节点身份完全由查询参数与 Bearer token 决定，不要试图从消息体读名字。

---

## 6. Backend 节点枢纽实现

`app/node_ws.py` 同时承担四件事：WSS 路由、连接注册表、请求/响应关联、系统状态清洗与持久化。建议按本章的数据结构原样实现。

### 6.1 数据结构与不变量

```python
@dataclass(frozen=True)
class NodeAuth:
    id: str
    name: str

@dataclass
class NodeRuntime:
    online: bool = False
    connected_at: datetime | None = None
    last_seen_at: datetime | None = None
    system: dict[str, Any] = field(default_factory=dict)
    persisted_at: datetime | None = None
    persisted_system_json: str = ""
    persisted_public_key: str | None = None

class NodeConnection:
    websocket: WebSocket
    node: NodeAuth
    pending: dict[str, asyncio.Future[dict[str, Any]]]
    send_lock: asyncio.Lock

class NodeHub:
    _connections: dict[str, NodeConnection]   # key = node.id
    _runtime: dict[str, NodeRuntime]          # key = node.id
    _lock: threading.RLock                    # 保护两个 dict
```

不变量：

1. `_connections[node.id]` 只保存**当前最新**连接；旧连接被替换后立即从 map 移除。
2. `_runtime[node.id]` 在节点首次注册时创建，断开后保留（用于展示 `last_seen_at` 与历史状态）。
3. `_lock` 是 `threading.RLock` 而不是 `asyncio.Lock`，因为 `request_node_sync` 可能在不同线程访问；临界区只做内存读写，不能 `await`。
4. `pending` 的键是请求 `id`，每个 Future 只被 `set_result` 或 `set_exception` 一次。

### 6.2 注册与注销

```python
async def register(self, websocket, node):
    connection = NodeConnection(websocket, node)
    now = utcnow()
    with self._lock:
        previous = self._connections.get(node.id)
        self._connections[node.id] = connection
        state = self._runtime.setdefault(node.id, NodeRuntime())
        state.online = True
        state.connected_at = now
        state.last_seen_at = now
    if previous is not None:
        previous.fail_pending(NodeOfflineError(f"Node '{node.name}' reconnected"))
        await previous.close(code=4000, reason="replaced by a newer connection")
    await anyio.to_thread.run_sync(
        functools.partial(_store_node_status, node.id, system=None, public_key=None)
    )
    ...
```

要点：

- **先改 map，再处理旧连接**。否则旧连接 close 的回调可能先执行 `unregister`，把新连接误删。
- 注册时立即写一次库（`last_seen_at`），让离线后重连的节点马上显示在线时间。
- close code `4000` 是应用自定义码，表示“被新连接顶替”。Node 侧收到任何 close 都会退出读循环并重连。

```python
async def unregister(self, connection):
    with self._lock:
        current = self._connections.get(connection.node.id)
        if current is not connection:
            return
        self._connections.pop(connection.node.id, None)
        state = self._runtime.setdefault(connection.node.id, NodeRuntime())
        state.online = False
    connection.fail_pending(NodeOfflineError(f"Node '{connection.node.name}' disconnected"))
```

**必须**先比较 `current is connection`。节点闪断重连时，两个协程可能交错：新连接 register 后，旧连接 finally 才 unregister；没有这个判断会把新连接删掉。

### 6.3 请求/响应关联

```python
async def request(self, node, command, payload, timeout):
    if not node.enabled:
        raise ValueError("Node is disabled")
    with self._lock:
        connection = self._connections.get(node.id)
    if connection is None:
        raise NodeOfflineError(f"Node '{node.name}' is offline")

    request_id = uuid.uuid4().hex
    loop = asyncio.get_running_loop()
    future = loop.create_future()
    connection.pending[request_id] = future
    try:
        await connection.send_json({
            "type": "request", "id": request_id,
            "command": command, "payload": payload or {},
        })
        response = await asyncio.wait_for(future, timeout=timeout)
    except TimeoutError as exc:
        raise NodeRequestError(f"Node '{node.name}' timed out running {command}") from exc
    except NodeOfflineError:
        raise
    except Exception as exc:
        raise NodeOfflineError(f"Node '{node.name}' connection failed: {exc}") from exc
    finally:
        connection.pending.pop(request_id, None)

    error = response.get("error")
    if error:
        raise NodeRequestError(str(error))
    result = response.get("result")
    if not isinstance(result, dict):
        raise NodeRequestError("Node returned an invalid response")
    self._mark_online(connection)
    return result
```

注意：

- `asyncio.wait_for(future, timeout)` 超时后会取消 Future；`handle_message` 里的 `not future.done()` 判断可避免对已取消 Future `set_result` 抛 `InvalidStateError`。
- `finally` 必须清理 `pending`，否则每次超时都会泄漏一个 Future。
- `send_json` 走 `send_lock`，避免与心跳/其他响应的发送交错。
- 成功返回后 `_mark_online` 只更新内存，不写库。

### 6.4 消息分发

```python
async def handle_message(self, connection, message):
    if message.get("type") == "response":
        request_id = str(message.get("id") or "")
        future = connection.pending.get(request_id)
        if future is not None and not future.done():
            future.set_result(message)
        return
    if message.get("type") in {"hello", "heartbeat"}:
        system = _clean_system_status(message.get("system"))
        public_key = message.get("public_key")
        await self.record_seen(
            connection,
            system=system,
            public_key=public_key if isinstance(public_key, str) else None,
        )
```

未知类型只记 debug。**不要**对未知类型抛异常，否则旧版节点发送的扩展消息会直接断开连接。

### 6.5 状态清洗白名单

`_clean_system_status` 是安全边界：Node 是可信但对端输入（如 `ping` 输出）可能包含任意文本。它只保留固定字段并做类型/长度约束：

| 字段组 | 处理 |
|---|---|
| `hostname`, `os`, `arch` | 仅字符串，`strip()`，截断 128 |
| `uptime_seconds`, `goroutines` | 仅 int/float，转 int |
| `load_1/5/15`, `cpu_percent`, `memory_percent`, `network_rx/tx_bytes_per_second` | 仅数字，`max(x, 0)`，保留 2 位小数 |
| `memory_used_bytes`, `memory_total_bytes` | 仅数字，非负 int |
| `wireguard`, `bird` | 递归 `_clean_command_status`：`ok` 布尔化，`output` 字符串且截断 64 KiB 后追加 `\n[truncated]` |

未知字段一律丢弃。这保证数据库里不会出现无法渲染的嵌套结构，也避免恶意节点写入超大 JSON。

### 6.6 系统摘要与指标

`_system_summary` 生成一行人类可读文本，供节点列表与详情页使用：

```text
router1 | linux/amd64 | up 12d 3h | load 0.12 0.08 0.05 | wg ok | bird ok
```

规则：

- 依次追加 hostname、`os/arch`、`up <uptime>`、`load a b c`、`wg ok/fail`、`bird ok/fail`。
- 用 `" | "` 连接；全空时返回 `"No system heartbeat yet"`。
- uptime 格式：≥1 天 `Xd Yh`；≥1 小时 `Xh Ym`；否则 `Xm`。

`_resource_metrics` 生成 3 个卡片项：

| label | 值 |
|---|---|
| `CPU` | `7.5%` |
| `Mem` | `31.2% 1.0GiB/3.2GiB`（有总量时追加） |
| `Net` | `rx 1.0KiB/s / tx 2.0KiB/s` |

`_format_bytes` 使用 1024 进制，B 不带小数，其余保留 1 位；`_format_rate` 追加 `/s`。

### 6.7 在线/离线上下文合并

`node_runtime_context(nodes)` 为模板构造统一结构：

```python
{
  node_id: {
    "online": bool,
    "connected_at": datetime | None,
    "last_seen_at": datetime | None,   # 优先内存，回退 nodes.last_seen_at
    "system": dict,                    # 优先内存，回退 system_status_json
    "system_summary": str,
    "resource_metrics": list[dict],
  }
}
```

**合并顺序必须是“内存优先、数据库兜底”**。否则刚断开的节点会立刻显示为 `No system heartbeat yet`，丢失最后一次状态。

### 6.8 线程与数据库

- `_lookup_node_auth`、`_store_node_status` 都是同步函数，通过 `anyio.to_thread.run_sync` 调用。
- `record_seen` 先 `_mark_online`（纯内存），再按 60s 节流决定是否入库。
- 公钥变化会绕过 60s 节流立即入库，因为对端配置依赖它。
- 公钥入库前用 `normalize_wireguard_key` 校验；非法值只记 warning，不覆盖旧值。

### 6.9 实现陷阱

1. **`_persist_seen_if_needed` 的节流状态必须在锁内更新**，否则并发心跳会同时通过判断，导致重复写库。
2. **`NodeRuntime.system` 的拷贝**：`snapshot()` 返回 `dict(state.system)` 浅拷贝；模板只读，因此足够。若后续要修改嵌套字段，需深拷贝。
3. **`_lookup_node_auth` 在登录时检查 `enabled`**，但已建立的连接不会因为管理员禁用而立即断开。禁用后的行为是：新连接被拒；已有连接仍可收命令，直到下次重连。复刻时若不接受此行为，需在 `POST /admin/nodes/{id}/update` 中主动 close。
4. **`_store_node_status` 用 `SessionLocal()` 独立会话**，不能复用请求的 `db`，否则跨线程使用 Session 会报错。
5. **`record_seen` 中 `public_key` 为 `None` 表示“本次没带”，不是“清空”**。节流逻辑必须区分。

---

## 7. Peer 领域逻辑

### 7.1 输入校验规则

所有规则集中在 `app/peer/validation.py`。**必须**在 Web、Bot、API 三个入口共用，不能各自实现。

| 字段 | 规则 | 错误文案（原实现） |
|---|---|---|
| `endpoint` | 空白允许；非空时长度 ≤255；每个字符 `33 ≤ ord ≤ 126`（禁止空格/控制字符）；必须 `host:port`；端口 1–65535；IPv6 必须 `[addr]:port`；host 可为 IP 或 RFC-1123 域名 | `Endpoint must be in host:port form` / `Endpoint port must be between 1 and 65535` / `Endpoint IPv6 address is invalid` / `Endpoint IPv6 endpoints must be written as [address]:port` / `Endpoint host must be an IP address or hostname` / `Endpoint must not contain spaces or control characters` |
| `wg_public_key` | 正则 `[A-Za-z0-9+/]{43}=`（44 字符） | `WireGuard public key must be a 44-character base64 value` |
| `wg_mtu` | 空→1420；整数；1280–9000 | `WireGuard MTU must be between 1280 and 9000` |
| `peer_dn42_ipv4` | 可空；`ip_interface` 解析；版本必须是 4 | `Must be a valid IPv4 address` |
| `peer_dn42_ipv6` | 可空；版本必须是 6 | `Must be a valid IPv6 address` |
| `peer_link_address` | 可空；非空时必须是 `fe80::/10` 或 `fc00::/7`；去掉前缀返回纯地址 | `Peer address must be an IPv6 link-local (fe80::/10) or ULA (fd00::/8) address` |
| `local_link_address` | 同上；为空则推导 | 同上 |
| `peer_asn` | 去 `AS` 前缀后纯数字 | `ASN must be numeric` |
| `bgp_extended` | `true/false` 或 `1/true/yes/on/enabled` 与 `0/false/no/off/disabled/""` | `BGP extension switch must be on or off` |

**至少一个地址**：`peer_dn42_ipv4`、`peer_dn42_ipv6`、`peer_link_address` 不能同时为空，否则：

```text
Enter at least one peer address: DN42 IPv4, DN42 IPv6, or link-local.
```

### 7.2 隧道地址推导优先级

```python
# 对端 BGP 地址
if peer_link_address:
    peer_link = normalize_tunnel_address(peer_link_address)
elif peer_dn42_ipv6 能作为 tunnel address:
    peer_link = normalize_tunnel_address(peer_dn42_ipv6)
else:
    peer_link = fe80::<ASN 后缀>       # derive_peer_link_address

# 我方 BGP 地址
if local_link_address:
    local_link = normalize_tunnel_address(local_link_address)
else:
    local_link = _derive_local_link_address(node, settings, peer_link)
    if not local_link:
        raise ValueError("Cannot derive our tunnel address - set the node's ASN (or LOCAL_ASN) first.")
```

`_derive_local_link_address` 的两个分支**必须**区分：

```python
def _derive_local_link_address(node, settings, peer_link_address):
    asn = node_effective_asn(node, settings.local_asn)
    if not asn:
        return ""
    if is_link_local(peer_link_address):
        return asn_link_local_address(asn)          # fe80::<节点 ASN 后缀>
    suffix = normalize_dn42_asn_suffix(asn)
    peer_ip = IPv6Address(peer_link_address.split("/", 1)[0])
    net = IPv6Network((int(peer_ip), 64), strict=False)
    return str(IPv6Address(int(net.network_address) + int(suffix, 16)))
```

- **对端是 LLA**：我方也用 LLA，按节点 ASN 派生。BIRD 邻居需加 `%interface` scope。
- **对端是 ULA**：取对端地址所在 `/64` 网络，加上我方 ASN 后缀作为主机位。例如对端 `fd00:1234::90/64`、我方后缀 `1` → `fd00:1234::1`。ULA 不需要 scope。

**⚠️** 若把 ULA 分支也写成 `fe80::`，BGP 会话会因邻居地址不在同一子网而永远 `Active`。

### 7.3 WireGuard 配置渲染

```python
def render_wireguard_peer_config(peer, node, private_key_placeholder):
    listen_port = wireguard_listen_port(peer.asn)
    endpoint_line = f"Endpoint = {peer.endpoint}\n" if peer.endpoint.strip() else ""
    return f"""# Generated by dn42 Autopeer for request {peer.id}
# AS{peer.asn} on node {node.name}

[Interface]
PrivateKey = {private_key_placeholder}
ListenPort = {listen_port}
Table = off
MTU = {peer_wireguard_mtu(peer)}
PostUp = ip addr add {post_up_address(peer)} dev %i

[Peer]
{endpoint_line}PersistentKeepalive = 15
PublicKey = {peer.wg_public_key}
AllowedIPs = 10.0.0.0/8, 172.20.0.0/14, 172.31.0.0/16, fd00::/8, fe80::/64
"""
```

逐项说明：

| 行 | 为什么必须这样 |
|---|---|
| `PrivateKey = {{WIREGUARD_PRIVATE_KEY}}` | Node 启动时用 `wireguard_private_key` 替换；占位符缺失会导致私钥为空，`wg-quick` 拒绝启动 |
| `ListenPort = ASN 后 5 位` | 每个 ASN 固定端口，对端配置可静态生成 |
| `Table = off` | 不写内核路由表，路由由 BIRD 管理，避免与 dn42 路由冲突 |
| `MTU` | 写入 `[Interface]`，不是 `[Peer]` |
| `PostUp = ip addr add <local>/64 dev %i` | 给隧道接口加我方 LLA/ULA；固定 `/64` |
| `Endpoint` 可有可无 | 对端主动拨号时省略；由对端拨我方时填写 |
| `PersistentKeepalive = 15` | 节点侧保活 |
| `AllowedIPs` | dn42 + 公网 IPv4 段 + IPv6 ULA/LLA 的固定集合 |

### 7.4 BIRD 配置渲染

```python
def render_bird_peer_config(peer, node, local_asn):
    local_asn_number = normalize_asn_number(local_asn)
    peer_asn_number = normalize_asn_number(peer.asn)
    protocol_name = peer_protocol_name(peer, node)
    scope = f"%{protocol_name}" if is_link_local(peer.peer_link_address) else ""
    extended_enabled = peer.bgp_extended

    lines = [
        f"# Generated by dn42 Autopeer for request {peer.id}",
        "# BIRD2 peer snippet based on the dn42 wiki MP-BGP over IPv6 template.",
        f"# Requires a global template named `dnpeers` with local as {local_asn_number}.",
        "",
        f"protocol bgp {protocol_name} from dnpeers {{",
    ]
    if extended_enabled:
        lines.append("  enable extended messages on;")
    lines.extend([
        f"  neighbor {peer_link_ip(peer)}{scope} as {peer_asn_number};",
        f"  source address {local_link_ip(peer)};",
        "  direct;",
    ])
    if extended_enabled:
        lines.extend(["  ipv4 {", "    extended next hop on;", "  };"])
    lines.append("}")
    return "\n".join(lines) + "\n"
```

生成的典型片段：

```text
# Generated by dn42 Autopeer for request 7b1c...
# BIRD2 peer snippet based on the dn42 wiki MP-BGP over IPv6 template.
# Requires a global template named `dnpeers` with local as 4242420000.

protocol bgp DN42_0090_1a2b from dnpeers {
  enable extended messages on;
  neighbor fe80::90%DN42_0090_1a2b as 4242420090;
  source address fe80::1;
  direct;
  ipv4 {
    extended next hop on;
  };
}
```

规则：

- `scope` 只在**对端地址是 LLA** 时添加；ULA 加了反而会让 BIRD 报错。
- `source address` 永远是我方地址，不加 scope。
- `direct;` 必须存在，否则 BIRD 会尝试递归解析邻居。
- `bgp_extended=false` 时同时省略 `enable extended messages on;` 与 `ipv4 { extended next hop on; }`，两处必须成对开关。

### 7.5 对端可读配置

`render_user_config` 给用户一份“照着填”的注释版：

```text
# Generated dn42 peer config for AS4242420090 on node frankfurt

[Interface]
# PrivateKey = <your-private-key>
# Address = fe80::90/64
MTU = 1420

[Peer]
PublicKey = <节点公钥>
Endpoint = de-fra.example.net:20090
AllowedIPs = 10.0.0.0/8, 172.20.0.0/14, 172.31.0.0/16, fd00::/8, fe80::/64
PersistentKeepalive = 25

# BGP
# Neighbor ASN: AS4242420000
# Neighbor IP: fe80::1
# Your ASN: 4242420090
# Our side will expect your BGP neighbor address: fe80::90
# Your DN42 IPv4: 172.20.90.1
# Your DN42 IPv6: fd00::90
# BGP extensions: enabled
```

注意：这是**注释版**，不是可直接使用的配置；`PrivateKey` 与 `Address` 被注释掉，提示用户替换。`peering_info` 同时提供结构化字段给 Web 渲染。

### 7.6 创建流程

```python
def create_peer(db, *, user, node, endpoint, wg_public_key, peer_link_address, settings, ...):
    if find_peer_on_node(db, node.id, user.primary_asn) is not None:
        raise ValueError("You already have a peer on this node. Edit or delete the existing one instead.")
    values = normalize_peer_input(...)
    peer = PeerRequest(..., status="approved", deploy_status="deploying")
    peer.node = node
    db.add(peer); db.flush()
    return deploy_peer_request(db, peer, settings)
```

关键点：

- **先做唯一性检查**，再校验输入，避免用户填了一堆字段才被告知重复。
- Peer 直接 `status="approved"`，没有人工审批环节（与原 README 的自动 peering 一致）。`pending` 只保留给未来的审批流/迁移数据。
- `deploy_status="deploying"` 在第一次 `flush` 前设置，因此页面在部署期间刷新能看到 `deploying`。
- `create_peer` **自己 commit**，调用方不要再 commit。

`deploy_peer_request` 的两阶段事务：

```python
peer.deploy_status = "deploying"
peer.deploy_output = ""
peer.updated_at = utcnow()
db.flush()
snapshot = _snapshot_peer(peer)   # 转成纯 dataclass
db.commit()                       # 先提交“部署中”，释放读事务
try:
    result = deploy_peer(snapshot.peer, snapshot.node, settings)
except Exception as exc:
    result = {"ok": False, "output": str(exc)}
updated = peer_with_node(db, peer.id)
apply_deploy_result(updated, result)
db.commit()
```

**为什么先 commit 再调用节点**：

1. 部署是同步阻塞调用（最长 20s），长时间持有 SQLite 写事务会阻塞其他请求。
2. 提交后其他页面能立即看到 `deploying`，避免“点了没反应”。
3. `_snapshot_peer` 把 ORM 对象转成 frozen dataclass，跨线程安全。

### 7.7 更新与节点迁移

```python
def update_peer(db, *, peer, node, ..., status, redeploy=False):
    if status not in {"approved", "disabled"}:
        raise ValueError("Unsupported peer status")
    duplicate = find_peer_on_node(db, node.id, peer.asn, exclude_id=peer.id)
    if duplicate:
        raise ValueError(f"AS{peer.asn} already has another peer on this node.")

    moved_from = _snapshot_peer(peer) if peer.node_id != node.id else None
    # 写入新字段...
    if status == "disabled":
        updated = teardown_peer_request(db, peer)
    elif redeploy:
        updated = deploy_peer_request(db, peer, settings)
    else:
        db.commit()
        updated = peer_with_node(db, peer.id)

    if moved_from is not None:
        _teardown_orphan_on_old_node(*moved_from)
    return updated
```

语义：

| 操作 | 行为 |
|---|---|
| 改字段、`redeploy=False` | 只更新数据库，节点侧保持旧配置 |
| 改字段、`redeploy=True` | 立即重新部署（Bot 编辑走此路径） |
| `status=disabled` | **立即拆除**节点配置（`wg-quick down` + 删文件），`deploy_status=removed` |
| 更换节点 | 在新节点部署/更新后，best-effort 拆除旧节点；旧节点离线只记 warning |

**⚠️** 节点迁移时 `_snapshot_peer(peer)` 必须在 `peer.node_id = node.id` **之前**调用，否则快照里已经是新节点，旧节点配置永远不会被清理。协议名由 ASN + peer.id 决定，节点迁移不改变它，所以旧快照仍指向正确文件。

### 7.8 拆除与删除

```python
def teardown_peer_request(db, peer):
    ...
    result = remove_peer(snapshot.peer, snapshot.node)   # timeout 20s
    ok = bool(result.get("ok", False))
    updated.deploy_status = "removed" if ok else "failed"
    updated.deploy_output = output
    updated.deployed_at = None if ok else updated.deployed_at
```

- 拆除成功把 `deploy_status` 设为 `removed`（**模型默认值列表之外的第五个状态**），页面会显示为中性 badge。
- `delete_peer` 先拆除（best-effort，失败只 warning），再删除行。即使节点离线，数据库记录也会被删除，不会卡住用户。

### 7.9 预览

`preview_peer` 不写库、不调节点。它构造一个临时 `PeerRequest`（不 `add`），把 `peer.node = node`，再调用 `peering_info` 生成“我方参数”。Web 的确认页与 Bot 的预览都走这里。

**必须**保证预览与实际创建使用同一套 `normalize_peer_input`，否则会出现“预览显示 fe80::90，实际创建成别的值”。

### 7.10 部署结果映射

```python
def apply_deploy_result(peer, result):
    ok = bool(result.get("ok", False))
    peer.deploy_output = str(result.get("output", result))
    if ok:
        peer.deploy_status = "deployed"
        peer.deployed_at = utcnow()
    else:
        peer.deploy_status = "failed"
        peer.deployed_at = None
```

注意：

- 只看 `ok`，**不看 `applied`**。文件已写但 `wg-quick up` 失败时，`ok=false`，状态记为 `failed`，`deploy_output` 保留完整原因。这符合“对端不可用就是失败”的产品语义。
- 若要把 `applied` 暴露给运维，应新增字段或写进 `deploy_output` 前缀，而不是改状态机。

### 7.11 实现陷阱

1. **`wireguard_listen_port` 对短 ASN 也会取后 5 位**：`AS65001` → `65001`，合法；`AS1` → `1`，合法但端口 1 需要 root 且可能与系统服务冲突。复刻时可加最小端口限制（如 ≥1024），但会偏离原行为。
2. **`peer_protocol_name` 依赖 `peer.id`**，因此 Peer 必须是先有 UUID 再渲染。`preview_peer` 中临时对象没有持久化，`peer.id` 为 `None`，所以预览**不能**调用 `peer_protocol_name`；它只渲染对端配置，不渲染节点侧协议名。
3. **`AllowedIPs` 含 `fe80::/64`**。部分内核会因此把链路本地流量也送进隧道；原实现如此，复刻保持一致即可。
4. **`PersistentKeepalive` 两侧不同**：节点侧 15s，对端示例 25s。不要“统一”成一个值。
5. **`PostUp` 固定 `/64`**，即使 `local_link_address` 输入带了 `/128`，也会被 `normalize_tunnel_address` 去掉前缀后再拼 `/64`。
6. **`deploy_peer` 检查 `node.enabled`，`remove_peer` 不检查**。删除/禁用时即使节点已禁用也会尝试拆除，失败则记 `failed`。
7. **`create_peer` 的唯一性检查与数据库唯一约束是双保险**。并发创建同一 `(node, asn)` 时，后者会触发 `IntegrityError`；调用方应捕获并转为友好提示。

## §8 Bot 实现规格

Bot 是**唯一面向普通用户的交互入口**（Web UI 也存在，但 Bot 承担注册、创建、编辑、删除、状态查询和 Looking Glass）。整个 Bot 是单进程、单事件循环、`aiogram` 3.x 的 **long polling** 模式，不暴露任何入站端口；它主动向 Backend 发 HTTP 请求，请求头带共享密钥。

### 8.1 进程模型与依赖

必须满足以下约束：

- 进程只依赖 `TELEGRAM_BOT_TOKEN`、`BOT_BACKEND_URL`、`TELEGRAM_BACKEND_SECRET` 三项配置；其余配置（`DOMAIN`、`LOCAL_ASN`）只用于文案与 URL 拼接。
- 使用 `Dispatcher()` 单例，`start_polling(bot)`；不得使用 webhook，否则需要额外暴露端口与 TLS 终止。
- 对 Backend 的调用使用 **标准库 `urllib` + `asyncio.to_thread`**，不引入 `aiohttp`/`httpx`。理由：依赖最小、超时行为可控、错误类型简单。
- `POST` 超时 40s（覆盖 deploy 的 20s + 排队），`GET` 超时 30s。
- 模块级创建 `settings = get_settings()`、`backend = Backend()`、`dp = Dispatcher()`；这意味着 Bot 进程启动时就会读取环境变量，配置错误在 import 阶段即暴露。

原实现（`app/bot/main.py` 前 100 行）：

```python
class Backend:
    """Small stdlib HTTP client for the bot's backend API."""

    def __init__(self) -> None:
        self.base_url = settings.bot_backend_url.rstrip("/")
        self.headers = {"X-Backend-Secret": settings.telegram_backend_secret}

    def _request_sync(
        self, method: str, path: str, payload: dict[str, Any] | None = None, timeout: int = 30
    ) -> dict[str, Any]:
        data = None
        headers = dict(self.headers)
        if payload is not None:
            data = json.dumps(payload).encode("utf-8")
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(
            f"{self.base_url}{path}", data=data, headers=headers, method=method
        )
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                body = response.read().decode("utf-8")
        except urllib.error.HTTPError as exc:
            body = exc.read().decode("utf-8", errors="replace")
            raise BackendStatusError(exc.code, body) from exc
        except (OSError, TimeoutError) as exc:
            raise BackendError(str(exc)) from exc
        if not body:
            return {}
        try:
            return json.loads(body)
        except ValueError as exc:
            raise BackendError("Backend returned a non-JSON response") from exc

    async def post(self, path: str, payload: dict[str, Any]) -> dict[str, Any]:
        return await asyncio.to_thread(self._request_sync, "POST", path, payload, 40)

    async def get(self, path: str) -> dict[str, Any]:
        return await asyncio.to_thread(self._request_sync, "GET", path)
```

两个异常类型必须区分：

| 异常 | 触发 | 携带信息 | 用途 |
| --- | --- | --- | --- |
| `BackendError` | 连接失败、超时、非 JSON | 文本 | 统一显示“服务不可达” |
| `BackendStatusError` | 收到非 2xx | `status_code`、`body` | 取 FastAPI 的 `detail` 给用户看；404 可替换为专用文案 |

`detail_of()` 负责从错误响应体里取 `detail`，取不到就回退原文：

```python
def detail_of(exc: BackendStatusError) -> str:
    try:
        payload = json.loads(exc.body)
    except ValueError:
        return exc.body
    return str(payload.get("detail", exc.body))
```

### 8.2 双 Router 与聊天类型策略

这是本 Bot 最容易写错、也最能体现产品意图的一处设计：

```python
lg_router = Router(name="looking_glass")
private_router = Router(name="account")

private_router.message.filter(F.chat.type == ChatType.PRIVATE)
private_router.callback_query.filter(F.message.chat.type == ChatType.PRIVATE)
```

注册顺序必须是 `lg_router` 先、`private_router` 后：

```python
dp.include_router(lg_router)
dp.include_router(private_router)
```

行为矩阵（必须逐格实现）：

| 聊天类型 | `/ping` `/trace` `/mtr` `/route` | `/login` `/create` `/edit` `/delete` `/listpeers` `/logout` | 其他文本 |
| --- | --- | --- | --- |
| 私聊 | 由 `lg_router` 处理 | 由 `private_router` 处理 | 若在 FSM 中则由对应状态 handler 处理；否则忽略 |
| 群聊 | 由 `lg_router` 处理 | **静默忽略**（无任何回复） | 静默忽略 |
| 频道 | 一般收不到消息 | 不处理 | 不处理 |

设计要点：

- `lg_router` 不加任何 chat 过滤，因为看板查询是公开、无副作用、可审计的操作，群里使用是合理场景。
- `private_router` 同时过滤 `message` 与 `callback_query`。只过滤 message 会让群里的内联按钮回调仍然生效，从而把群变成向导界面。
- “静默忽略”是刻意的：在群里回复“请私聊我”会制造噪音。复刻时不要好心加提示。
- `/cancel` 位于 `private_router` 且**不带 `default_state`**，因此它在任何 FSM 状态下都能触发；它注册在向导步骤 handler 之前，保证优先级。

### 8.3 命令菜单

必须调用两次 `set_my_commands`：

```python
await bot.set_my_commands(BOT_COMMANDS)
await bot.set_my_commands(GROUP_BOT_COMMANDS, scope=BotCommandScopeAllGroupChats())
```

`BOT_COMMANDS` 共 12 条，顺序即客户端菜单顺序：

| command | description（原文） |
| --- | --- |
| `login` | `Login your DN42 asn` |
| `logout` | `Logout your DN42 asn` |
| `listpeers` | `list your peers` |
| `create` | `create your peer` |
| `edit` | `edit a peer` |
| `delete` | `delete a peer` |
| `ping` | `ping someone` |
| `trace` | `trace someone` |
| `mtr` | `mtr someone` |
| `route` | `show route on a node` |
| `cancel` | `cancel all` |
| `help` | `show this help` |

注意：

- `/start` **故意不列入**菜单，但 handler 仍然存在（`Command("start", "help")`）。它是隐含入口，不占用菜单位。
- 群聊子集由 `GROUP_COMMAND_NAMES = {"ping","trace","mtr","route"}` 过滤 `BOT_COMMANDS` 派生，保证描述文本永远同步，不要在群聊里手写第二份列表。
- 命令菜单只是“提示”，不是权限控制。真正的权限控制来自 Router 过滤与 Backend 的 Telegram binding 校验。

### 8.4 `/start` 与 `/help` 文案

`HELP_TEXT` 必须逐字复刻（`{admin_asn_display()}` 为 `AS<number>` 或 `(not configured)`）：

```text
dn42 autopeer bot
Our ASN: AS4242420090

/login - Login your dn42 ASN
/logout - Logout your dn42 ASN
/listpeers - Show your peers status
/create - create a peer
/edit - edit one of your peers
/delete - delete one of your peers
/ping
/trace
/mtr
/route
/cancel - Cancel ALL?
```

`admin_asn_display()` 的规则：

```python
def admin_asn_display() -> str:
    raw = settings.local_asn.strip()
    if not raw:
        return "(not configured)"
    try:
        return f"AS{normalize_asn_number(raw)}"
    except ValueError:
        return raw
```

即：未配置显示占位符；可解析则统一成 `AS<裸数字>`；不可解析则原样显示（便于运维发现自己填错了）。

### 8.5 FSM 状态图

三组状态，全部是 `StatesGroup`：

```python
class CreatePeer(StatesGroup):
    node = State()
    endpoint = State()
    public_key = State()
    dn42_ipv4 = State()
    dn42_ipv6 = State()
    link_local = State()
    mtu = State()
    bgp_extended = State()
    confirming = State()

class EditPeer(StatesGroup):
    choosing = State()
    endpoint = State()
    public_key = State()
    mtu = State()

class DeletePeer(StatesGroup):
    choosing = State()
    confirming = State()
```

#### 创建向导（9 态）

```text
/create
  ↓ 校验账号已绑定 + 拉取启用节点
CreatePeer.node            “Let's create a peer. Which node?”（回复键盘列出节点名）
  ↓ 必须命中节点名
CreatePeer.endpoint        host:port 或 skip
  ↓ looks_like_endpoint
CreatePeer.public_key      44 字符 base64，正则 ^[A-Za-z0-9+/]{43}=$
  ↓
CreatePeer.dn42_ipv4       IPv4 / skip
CreatePeer.dn42_ipv6       IPv6 / skip
CreatePeer.link_local      link-local 或 ULA / skip
CreatePeer.mtu             1280-9000 / default
CreatePeer.bgp_extended    yes/no / default
  ↓ 调用 /api/telegram/peer/preview，把预览与 payload 一起存进 FSM
CreatePeer.confirming      必须回 yes/y
  ↓ /api/telegram/peer/create
完成，state.clear()
```

每一步的校验必须“失败即停留原状态”，不能前进也不能清空已有字段：

- `node`：`choice not in data["nodes"]` → 提示重新选。
- `endpoint`：`skip`/`none`/`-` 归一化为空串；否则必须 `host:port`，端口 1-65535。
- `public_key`：只做**语法**校验（44 字符 base64 且以 `=` 结尾），不做曲线点校验；真正的密钥合法性由节点侧 WireGuard 决定。
- `dn42_ipv4` / `dn42_ipv6` / `link_local`：`skip`/`none`/`-`/空 → 空串；非空值原样保存，由 Backend 的 `normalize_*` 严格校验。
- `mtu`：空或 `default` → 1420；`keep`/`same` 在创建阶段**不允许**（`allow_keep=False`）。
- `bgp_extended`：空/`yes`/`y`/`on`/`enable`/`enabled`/`true`/`1`/`default`/`skip` → `True`；`no`/`n`/`off`/`disable`/`disabled`/`false`/`0` → `False`；其余 → 重新提问。

关键实现细节：**预览时就把完整 payload 存进 FSM**，确认时直接取用。这样确认阶段不会因为用户输入被再次解析而漂移：

```python
await state.update_data(create_payload=payload)
await state.set_state(CreatePeer.confirming)
await message.answer(format_block(peer_preview_text(preview)), parse_mode="Markdown")
```

确认阶段：

```python
if (message.text or "").strip().lower() not in {"yes", "y"}:
    await message.answer("Not confirmed. Send 'yes' to create it, or /cancel.")
    return
data = await state.get_data()
await state.clear()
result = await call_backend(... data["create_payload"] ...)
```

**先 `state.clear()` 再调用 Backend**：即使创建失败，向导也已结束，用户可以重新 `/create`；失败信息里包含 `deploy_output`，不会丢失诊断。

#### 编辑向导（4 态）

```text
/edit
  ↓ 拉取用户 peers，把 peer_ids 与 peer_mtu 映射写入 FSM
EditPeer.choosing      按序号选择（支持 "2" 或 "#2"）
  ↓
EditPeer.endpoint      新 host:port，或 skip 表示“无端点”
EditPeer.public_key    新公钥
EditPeer.mtu           1280-9000，或 keep/same 保留原 MTU
  ↓ 调用 /api/telegram/peer/edit，redeploy=True
完成
```

编辑**只允许改 endpoint / 公钥 / MTU**，这是刻意的：地址、节点、状态属于管理员职责，普通用户改动会破坏路由一致性。Web 端的管理员编辑页才提供节点迁移、状态切换。

MTU 提示中的当前值来自 FSM 里预先快照的 `peer_mtu` 映射，而不是重新查库，避免会话中数据变化导致提示与实际不一致：

```python
current_mtu = data.get("peer_mtu", {}).get(str(data["peer_id"]), DEFAULT_WIREGUARD_MTU)
```

#### 删除向导（2 态）

```text
/delete
  ↓ 拉取 peers
DeletePeer.choosing    按序号选择
  ↓
DeletePeer.confirming  必须回 yes/y
  ↓ /api/telegram/peer/delete
“Deleted peer.”
```

删除成功只回 `Deleted peer.`，不带 ASN/节点信息——因为此时记录已不在库里。

### 8.6 输入解析辅助函数

这些函数是 Bot 与 Backend 之间的“宽容层”：Bot 接受人类常见写法，Backend 执行严格校验。必须按以下语义实现。

| 函数 | 语义 | 边界 |
| --- | --- | --- |
| `looks_like_endpoint(v)` | `rpartition(":")` 后 host 非空、port 全数字且 1-65535 | 不校验 host 是否为合法 IP 或域名 |
| `parse_index(text, count)` | 去空白、去前导 `#`、全数字、范围 `[1, count]` | 非法返回 `None`，调用方提示重输 |
| `parse_mtu(text, allow_keep)` | `keep`/`same` 且允许时返回 `None`（表示保持） | 空/`default` → 1420；其余交给 `normalize_wireguard_mtu` |
| `parse_optional_value(text)` | 空/`skip`/`none`/`-` → `""` | 否则原样返回（含前缀） |
| `parse_yes_no(text)` | 见 8.5 的取值集合 | 无法判定返回 `None` |
| `reject_if_command(message, action)` | 文本以 `/` 开头则提示“你在向导中” | 防止 `/ping` 被当成字段值 |

`reject_if_command` 的实现与文案：

```python
async def reject_if_command(message: Message, action: str) -> bool:
    if message.text and message.text.strip().startswith("/"):
        await message.answer(f"You're in the middle of /{action}. Send /cancel to abort.")
        return True
    return False
```

注意它是**布尔返回值**而不是抛异常；每个步骤 handler 的第一行都要写：

```python
if await reject_if_command(message, "create"):
    return
```

这段逻辑不能省略。看板命令的 handler 都带 `default_state` 过滤，因此向导状态下 `/ping` **不会**被 `lg_router` 执行；消息会落到当前向导状态的 handler，被当成字段值。于是 `/ping 1.1.1.1` 会被存成 endpoint 或公钥，随后产生难以理解的校验失败。`reject_if_command` 把这种误触转成明确提示，并保留用户已填的字段。

### 8.7 全部提示文案

复刻时直接使用下表文本（英文原文），不要“优化”措辞，因为用户文档与截图都基于这些字符串。

#### 入口与账号

| 场景 | 文案 |
| --- | --- |
| 未绑定（通用） | `Your Telegram account is not linked to a dn42 ASN yet. Use /login first.` |
| `/login` 多 ASN | `You control multiple ASNs in FindNOC — pick the one to log in with:` |
| `/login` 成功（FindNOC） | `Logged in via FindNOC quick verification.` + 换行 + `ASN: AS{asn}` + 换行 + `Your Telegram account is now linked. Use /create to add a peer.` |
| `/login` 回退 Mini App | `Open the app to verify your dn42 ASN:` |
| 非 HTTPS | `Telegram Web Apps require DOMAIN to use HTTPS.` + `Current verification URL is: {url}` + 说明 `Set DOMAIN to a public HTTPS domain and restart both the backend and bot.` |
| 验证完成 | `ASN verification complete.` + `ASN: AS{asn}` + `Maintainer: {effective_mnt or unknown}` + `Method: {authtype or unknown}` |
| 验证数据损坏 | `Verification data was malformed: {exc}` |
| `/logout` 成功 | `Logged out. Your Telegram account is no longer linked to AS{asn}.` + `Your peers are kept — use /login to link again.` |

#### 创建向导

| 步骤 | 文案 |
| --- | --- |
| 选节点 | `Let's create a peer. Which node?` |
| 节点不匹配 | `Please pick one of the listed nodes, or /cancel.` |
| 端点 | `WireGuard endpoint as host:port (e.g. 198.51.100.7:51820), or send 'skip' if your side will dial us.` |
| 端点格式错误 | `Endpoint must be host:port (e.g. 198.51.100.7:51820), or send 'skip'. Try again or /cancel.` |
| 公钥 | `Your WireGuard public key (44-character base64).` |
| 公钥格式错误 | `That doesn't look like a WireGuard public key (44-char base64 ending in '='). Try again or /cancel.` |
| IPv4 | `Your DN42 IPv4 address, or send 'skip'.` |
| IPv6 | `Your DN42 IPv6 address, or send 'skip'.` |
| 链路本地 | `Your link-local/BGP address (e.g. fe80::99), or send 'skip'.` |
| MTU | `WireGuard MTU (1280-9000). Send 'default' to use 1420.` |
| BGP 扩展 | `Enable BGP extensions (multiprotocol BGP, extended nexthop)? Send yes/no, or default for yes.` |
| BGP 输入非法 | `Please send yes or no, or /cancel.` |
| 确认 | `Send 'yes' to create it, or /cancel.` |
| 未确认 | `Not confirmed. Send 'yes' to create it, or /cancel.` |
| 无节点 | `No nodes are available right now.` |

#### 编辑与删除向导

| 步骤 | 文案 |
| --- | --- |
| 选择编辑对象 | `Which peer do you want to edit?` + 换行 + `peer_list_text` |
| 选择删除对象 | `Which peer do you want to delete?` + 换行 + `peer_list_text` |
| 序号非法 | `Reply with the number of a listed peer, or /cancel.` |
| 无 peer 可编辑 | `You have no peers to edit. Use /create first.` |
| 无 peer 可删除 | `You have no peers to delete.` |
| 新端点 | `New WireGuard endpoint as host:port, or send 'skip' for none.` |
| 新公钥 | `New WireGuard public key (44-character base64).` |
| 新公钥格式错误 | `That doesn't look like a WireGuard public key. Try again or /cancel.` |
| 新 MTU | `New WireGuard MTU (1280-9000, current {mtu}). Send 'keep' to keep it.` |
| 删除确认 | `Delete this peer? This tears down the tunnel and BGP session. Send 'yes' to confirm, or /cancel.` |
| 未确认删除 | `Deletion not confirmed. Send 'yes' to confirm, or /cancel.` |
| 删除成功 | `Deleted peer.` |

#### 列表、取消与错误前缀

| 场景 | 文案 |
| --- | --- |
| 无 peer（列表） | `You have no peers yet. Use /create to add one.` |
| `/cancel` 无状态 | `Nothing to cancel.` |
| `/cancel` 有状态 | `Cancelled.` |
| 向导中误触命令 | `You're in the middle of /{action}. Send /cancel to abort.` |
| 菜单过期 | `This menu expired — re-run the command.` |
| 回调非法 | `Invalid selection.` |
| 创建结果 | `{action} peer on {node} (AS{asn}) — deploy: {deploy_status}`，`action` 为 `Created` 或 `Updated` |
| 成功后的说明 | `Use these settings to configure your interface:` + `peering_info_lines` |
| 预览开头 | `Review this peer before deployment.` + `Interface helper:` + … |
| 预览字段 | `Node:` / `Endpoint:` / `DN42 IPv4:` / `DN42 IPv6:` / `BGP neighbor address:` / `BGP extensions:` |

错误前缀（`call_backend` 的 `error_prefix`），必须与上表一致：

`Could not load nodes`、`Could not start`、`Preview failed`、`Create failed`、`Edit failed`、`Delete failed`、`Peer lookup failed`、`Logout failed`、`Verification failed`、`Could not create verification challenge`、`Could not load your peers`。

### 8.8 `peering_info` 的展示格式

`peering_info_lines` 是 Bot 与 Web 共用的“我方参数”格式化函数，输出七行：

```text
ASN: AS4242420090
IPv4: 172.20.x.x
IPv6: fd00::x
Link-local: fe80::...

Endpoint: [2001:db8::1]:20090

WireGuard Public Key: <44-char>
wireguard MTU: 1420
```

规则：

- `asn` 为占位符 `<our-asn>` 时**不加** `AS` 前缀，直接显示该占位符。
- `ipv4`/`ipv6` 缺失显示 `-`。
- `link_local` 原样显示（Backend 已保证非空）。
- `Link-local` 之后有一个空行，`Endpoint` 之后也有一个空行；其余字段逐行紧排。
- `mtu` 缺失回退 `DEFAULT_WIREGUARD_MTU`。

`peering_info_text` 只是加一行前缀：

```python
return "Use these settings to configure your interface:\n" + peering_info_lines(info)
```

### 8.9 创建/编辑结果的发送策略

`send_peer_result` 必须按 `deploy_status` 分流：

```python
deploy_status = result.get("deploy_status")
await message.answer(
    f"{action} peer on {result.get('node')} (AS{result.get('asn')}) — deploy: {deploy_status}",
    reply_markup=ReplyKeyboardRemove(),
)
if deploy_status == "deployed" and result.get("peering"):
    block = format_block(peering_info_text(result["peering"]))
    await message.answer(block, parse_mode="Markdown")
    return
output = str(result.get("deploy_output", "")).strip()
if output:
    await message.answer(format_block(output, 1500), parse_mode="Markdown")
```

要点：

- 第一条消息一定有，告知节点与状态，同时**移除回复键盘**（避免旧的节点名按钮残留）。
- 成功时发「我方参数」，失败时发 `deploy_output`（截断到 1500 字符）。两者互斥。
- 失败时 `deploy_output` 可能为空（例如早期错误），此时只发第一条消息。

### 8.10 Looking Glass 交互

这是 Bot 最精巧的部分，包含“随机节点先跑 + 按钮切换 + 一次性 token”。

#### 命令入口

四个命令都调用 `run_lg(message, state, query_type)`，且都带 `default_state` 过滤：

```python
@lg_router.message(Command("ping"), default_state)
async def ping_cmd(message: Message, state: FSMContext) -> None:
    await run_lg(message, state, "ping")
```

`default_state` 的作用：当用户处于创建向导时，`/ping` 不会被执行，而是落到 `reject_if_command` 产生友好提示。这避免了向导被看板命令打断。

#### 目标解析

```python
def parse_lg_target(message: Message) -> str:
    parts = (message.text or "").split()
    if len(parts) < 2:
        raise ValueError("Usage: /<command> <target>")
    return parts[1]
```

只取第二个 token，忽略其余。原因：节点由内联按钮选择，不是位置参数。`/ping 1.1.1.1 from frankfurt` 不会报错，只会用 `1.1.1.1`。

#### 立即执行 + 随机节点

```python
names = [node["name"] for node in data.get("nodes", [])]
token = secrets.token_urlsafe(6)
await state.update_data(
    lg_token=token, lg_query_type=query_type, lg_target=target, lg_nodes=names
)
node = random.choice(names)
placeholder = await message.answer(
    format_block(f"{lg_caption(query_type, target)} @ {node}\n\nrunning…"),
    parse_mode="Markdown",
    reply_markup=lg_node_inline_keyboard(names, token, active=node),
)
await render_lg(placeholder, user_id=..., query_type=..., target=..., node=node, names=names, token=token)
```

顺序必须是：

1. 先发占位消息（返回 `Message` 对象，后续可 `edit_text`）。
2. 再异步查询并编辑该消息。

否则用户会等待数秒无反馈。占位消息同时承担“键盘载体”的作用。

#### 键盘与回调数据

```python
def lg_node_inline_keyboard(node_names, token, active=None):
    buttons = [
        InlineKeyboardButton(
            text=f"• {name}" if name == active else name,
            callback_data=f"lg:{token}:{index}",
        )
        for index, name in enumerate(node_names)
    ]
    rows = [buttons[i : i + 3] for i in range(0, len(buttons), 3)]
    return InlineKeyboardMarkup(inline_keyboard=rows)
```

- `callback_data` 只含 `lg:<token>:<index>`，**不含目标**。Telegram 限制 64 字节，长 IPv6 或主机名会超限；用索引回避。
- 每行最多 3 个按钮。
- 当前节点加 `• ` 前缀（不是 emoji，避免跨客户端渲染差异）。
- `token` 每次命令重新生成（`secrets.token_urlsafe(6)`，约 8 字符）。

#### 切换节点

```python
@lg_router.callback_query(F.data.startswith("lg:"))
async def lg_choose(callback: CallbackQuery, state: FSMContext) -> None:
    try:
        _, token, index_text = callback.data.split(":", 2)
        index = int(index_text)
    except ValueError:
        await callback.answer("Invalid selection.")
        return
    data = await state.get_data()
    if data.get("lg_token") != token:
        await callback.answer("This menu expired — re-run the command.", show_alert=True)
        return
    names = data.get("lg_nodes", [])
    if not 0 <= index < len(names):
        await callback.answer("Invalid selection.")
        return
    node = names[index]
    query_type = data["lg_query_type"]
    target = data["lg_target"]
    await callback.answer(f"Running {query_type} on {node}…")
    await render_lg(callback.message, user_id=callback.from_user.id, ...)
```

三个校验缺一不可：

| 校验 | 防的问题 |
| --- | --- |
| `split(":", 2)` 成功、`int` 成功 | 伪造/损坏的回调数据 |
| `data["lg_token"] == token` | 旧消息上的按钮。用户第二次 `/ping` 后，FSM 里的 token 被覆盖，旧按钮点击即过期 |
| `0 <= index < len(names)` | 节点列表变化后索引越界 |

注意 `lg_router` 的回调**没有私聊过滤**：群里任何人都能点按钮。但它只能影响**发起者自己**的 FSM 数据——`FSMContext` 的 key 是 `(chat_id, user_id)`，其他人点击时 `state.get_data()` 读不到发起者的 token，于是得到“菜单过期”。这是用 FSM 天然作用域实现的授权，不需要额外判断。

#### 结果就地编辑

```python
text = format_block(f"{lg_caption(query_type, target)} @ {node}\n\n{body}")
try:
    await message.edit_text(text, parse_mode="Markdown", reply_markup=lg_node_inline_keyboard(names, token, active=node))
except TelegramBadRequest:
    pass
```

- 标题固定为 `<type> <target> @ <node>`，其中 `lg_caption` 是 `f"{query_type} {target}".rstrip()`。
- 后端错误不抛出，而是**写进同一个代码块**：`Looking glass failed: {detail}`。这样用户看到的始终是一条消息，不会刷屏。
- `TelegramBadRequest` 必须吞掉。最常见的两种情况：内容未变化（重复点同一节点）、消息过旧无法编辑。
- 键盘重新附加，`active` 指向新节点，用户可继续切换。

### 8.11 消息分块与截断

Telegram 单条消息上限 4096 字符；扣掉代码块围栏与 Markdown 解析余量，原实现取 **3900** 作为安全阈值。

```python
def format_block(text: str, limit: int = 3900) -> str:
    text = text or "(no output)"
    if len(text) > limit:
        text = text[:limit] + "\n...[truncated]"
    return f"```\n{text}\n```"

def chunk_blocks(blocks: list[str], limit: int = 3900) -> list[str]:
    messages: list[str] = []
    current = ""
    for block in blocks:
        if len(block) > limit:
            block = block[:limit] + "\n...[truncated]"
        if current and len(current) + 1 + len(block) > limit:
            messages.append(current)
            current = block
        else:
            current = f"{current}\n{block}" if current else block
    if current:
        messages.append(current)
    return messages
```

要点：

- `chunk_blocks` 只在**块边界**切分，不会把某一个 peer 的状态块切成两半。
- 块之间用单个换行连接，计入 `+1`。
- 单块超限时先截断，因此不会出现“一个块永远塞不进”的死循环。
- `/listpeers` 最后逐条发送，每条都是独立代码块：

```python
for chunk in chunk_blocks(blocks):
    await message.answer(f"```\n{chunk}\n```", parse_mode="Markdown")
```

### 8.12 `/listpeers` 的区块结构

每个 peer 生成一个 `=== ... ===` 区块：

```text
=== frankfurt (AS4242421234) [approved · deployed] ===
your endpoint: 198.51.100.7:51820
your DN42 IPv4: 172.20.1.2
your DN42 IPv6: fd00::2
your link-local: fe80::1234
BGP extensions: enabled
ASN: AS4242420090
IPv4: 172.20.0.1
IPv6: fd00::1
Link-local: fe80::90

Endpoint: [2001:db8::1]:20090

WireGuard Public Key: <44-char>
wireguard MTU: 1420

[WireGuard]
up · handshake 1 minute ago · 1.2 KiB rx / 900 B sent

[BIRD]
Established · routes 12 in / 3 out
```

字段规则：

- 标题：`=== {node} (AS{asn}) [{status} · {deploy_status}] ===`，两个状态用 ` · ` 连接，空值被 `filter(None, ...)` 丢掉。
- 用户侧字段（`your ...`）只在非空时输出。
- `BGP extensions` 永远输出（`enabled`/`disabled`）。
- 有 `peering` 时输出我方参数块；否则只输出 `wireguard MTU: {mtu}`（用于尚未部署/无节点数据的情况）。
- `[WireGuard]` 段：`wg_detail` 为空显示 `(no WireGuard status)`。
- `[BIRD]` 段：`detail` 为空显示 `(no detail)`。
- 状态获取失败时，Backend 返回 `status unavailable: <exc>`，会原样展示在 BIRD 段。

### 8.13 Bot 侧调用矩阵

| Bot 动作 | 方法 + 路径 | 关键 payload | 依赖 |
| --- | --- | --- | --- |
| 生成挑战 | `POST /api/telegram/challenge` | `telegram_user_id`、`telegram_chat_id` | 返回 `token`、`url` |
| Mini App 验证 | `POST /api/telegram/verify` | 上述 + `username`、`params`、`signature` | 返回 `asn`、`effective_mnt`、`authtype` |
| FindNOC 登录 | `POST /api/telegram/findnoc/login` | 上述 + `username`（+ 可选 `asn`） | 404/503 回退 |
| 登出 | `POST /api/telegram/logout` | `telegram_user_id` | 404 显示“未绑定” |
| 我的 peers | `GET /api/telegram/peer/{uid}` | 无 | 404 显示“未绑定” |
| 节点列表 | `GET /api/telegram/nodes` | 无 | 只返回启用节点 |
| 预览 | `POST /api/telegram/peer/preview` | 创建表单字段 | 400 带校验原因 |
| 创建 | `POST /api/telegram/peer/create` | 同上 | 同步等待 deploy |
| 编辑 | `POST /api/telegram/peer/edit` | `peer_id` + 三字段 | `redeploy=True` |
| 删除 | `POST /api/telegram/peer/delete` | `peer_id` | 先拆后删 |
| 列表状态 | `POST /api/telegram/status` | `telegram_user_id` | 并发查所有节点 |
| 看板 | `POST /api/telegram/lg` | `node`、`query_type`、`target` | 12s 超时 |

### 8.14 Bot 实现陷阱

1. **`call_backend` 接收的是 `Awaitable`，不是已启动的 Task**。若写成 `await request` 之外再 `await` 一次会抛 `RuntimeError`。复刻时保持“协程对象传入、函数内 await”。
2. **`private_router` 必须同时过滤 message 和 callback_query**。只过滤 message 时，群里点 `fnlogin:` 按钮仍会执行登录绑定，造成群成员串号。
3. **`/cancel` 不能加 `default_state`**。加了之后向导中无法取消；它的价值就在于任何状态都能清空。
4. **`create_cmd` 先校验账号再拉节点**。顺序反过来会在未登录时提示“无节点可用”，误导用户。
5. **`edit_cmd` 必须快照 MTU**。编辑向导跨多轮消息，期间管理员可能改 MTU；快照保证提示与实际提交一致。
6. **`state.clear()` 的时机**：创建确认在调用 Backend 之前清空；编辑 MTU 在组装 payload 之前清空。清理过早会丢数据，过晚会在失败后让用户卡在“确认”状态。
7. **`web_app_data` 必须 `json.loads` 后按 key 取 `params`/`signature`**。Telegram 送来的是字符串，不是对象。缺 key 或 JSON 损坏要给出 `malformed` 提示，不能 500。
8. **`kioubit_login` 检查 `https://` 前缀**。`DOMAIN` 未配置时 `base_url` 是 `http://...`，Telegram 会拒绝打开 Mini App。必须在发按钮前拦截并解释。
9. **FindNOC 回退只针对 404/503**。400 是真错误（例如用户选了不拥有的 ASN），必须原样展示，不能静默回退到 Kioubit——否则用户会误以为“验证失败”。
10. **`fnlogin:` 回调要把 `callback.message.chat.id` 带上**。绑定记录需要 chat_id 才能发送后续主动消息；只带 user_id 会丢字段。
11. **`render_lg` 不能用 `message.answer`**。它必须 `edit_text`，否则每次切节点都新增一条消息。
12. **`lg_choose` 的 `callback.answer` 要先回，再执行查询**。先查询会让客户端按钮转圈十几秒无响应；`callback.answer("Running ...")` 是“立即确认”。
13. **`format_block` 的 `(no output)`**：空字符串不能生成空代码块（客户端会显示一个孤立阴影框）。
14. **`send_peer_result` 的 `deploy_status == "deployed"` 判断**：不要用 `ok` 字段，Backend 返回的是 `deploy_status` 与 `deploy_output`。
15. **菜单过期提示用 `show_alert=True`**。否则只弹一个 2 秒 toast，群聊里根本看不清。

## §9 Bot-only REST API

前缀固定为 `/api/telegram`，全部端点都挂同一个依赖：

```python
def require_bot_secret(x_backend_secret: str = Header("")) -> None:
    settings = get_settings()
    if not secrets.compare_digest(x_backend_secret, settings.telegram_backend_secret):
        raise HTTPException(status_code=401, detail="Invalid bot secret")
```

三条硬性要求：

- 头名必须是 `X-Backend-Secret`（FastAPI 自动把下划线转成连字符，客户端发送时用连字符形式）。
- 比较必须用 `secrets.compare_digest`，不能 `==`。否则攻击者可通过响应时间逐字节猜密钥。
- 空字符串也必须参与比较。`compare_digest("", "")` 为真，所以**必须**在启动守卫里禁止空密钥（§3.4），否则任何不带头的请求都能通过。

### 9.1 Pydantic 模型规范

所有模型统一：

```python
model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)
```

- `extra="forbid"`：多传字段直接 422，防止 Bot 版本与 Backend 版本漂移时静默忽略新字段。
- `str_strip_whitespace=True`：所有字符串自动 trim，避免用户从 Telegram 复制带空格的值。

#### 身份字段

| 字段 | 类型 | 约束 | 说明 |
| --- | --- | --- | --- |
| `telegram_user_id` | `str` | `^\d{1,20}$` | 必须字符串。JSON 数字会丢精度（Telegram ID 可达 52 位） |
| `telegram_chat_id` | `str` | `^-?\d{1,20}$` | 允许负值（群/频道 ID 为负） |
| `username` | `str \| None` | `^[A-Za-z0-9_]{1,64}$`，最长 64 | 可空；仅用于展示 |

#### 看板请求

| 字段 | 类型 | 约束 | 默认 |
| --- | --- | --- | --- |
| `node` | `str` | `^[A-Za-z0-9_-]{1,64}$` | `"local"` |
| `query_type` | `Literal["ping","trace","mtr","route"]` | 枚举 | 必填 |
| `target` | `str` | 最长 255 | `""` |

`target` 的长度在这里只做粗限；真正的语义校验在 `validate_target`（§12）。

#### 创建/预览请求

`PeerCreateRequest` 与 `PeerPreviewRequest` 字段完全一致（分开定义是为了将来可以独立演进）：

| 字段 | 类型 | 约束 | 默认 |
| --- | --- | --- | --- |
| `telegram_user_id` | `str` | `^\d{1,20}$` | 必填 |
| `node` | `str` | `^[A-Za-z0-9_-]{1,64}$` | 必填 |
| `endpoint` | `str` | 最长 255 | `""` |
| `wg_public_key` | `str` | 长度 1-128 | 必填 |
| `peer_dn42_ipv4` | `str` | 最长 64 | `""` |
| `peer_dn42_ipv6` | `str` | 最长 64 | `""` |
| `peer_link_address` | `str` | 最长 128 | `""` |
| `wg_mtu` | `int \| None` | `1280 <= x <= 9000` | `None` |
| `bgp_extended` | `bool` | — | `True` |

注意：

- `wg_public_key` 的长度上限 128 而不是 44，因为 Backend 还要兼容用户可能带前缀/换行的粘贴；严格校验在 `normalize_wireguard_key`。
- `wg_mtu=None` 与 `wg_mtu=0` 语义不同：前者表示“未指定，用默认 1420”，后者会被 Pydantic 直接拒绝（小于 1280）。
- `bgp_extended` 在 Bot 侧总是显式传布尔值，不做“缺省即真”的推断。

#### 编辑请求

`PeerEditRequest` 与创建请求的差异在于“可选字段用 `None` 表示不改”：

| 字段 | 类型 | 语义 |
| --- | --- | --- |
| `peer_id` | `str`，长度 1-36 | 必填 |
| `endpoint` | `str` | 必填（空串表示清空端点） |
| `wg_public_key` | `str`，长度 1-128 | 必填 |
| `peer_dn42_ipv4` | `str \| None` | `None` = 保持原值 |
| `peer_dn42_ipv6` | `str \| None` | `None` = 保持原值 |
| `peer_link_address` | `str \| None` | `None` = 保持原值 |
| `wg_mtu` | `int \| None` | `None` = 保持原值（对应 Bot 的 `keep`） |
| `bgp_extended` | `bool \| None` | `None` = 保持原值 |

这个三态设计（缺省/空串/具体值）必须严格实现，否则“keep MTU”会变成“重置为默认”。

#### 删除与登出

`PeerDeleteRequest`：`telegram_user_id` + `peer_id`（1-36）。
`LogoutRequest` / `PeerStatusRequest`：仅 `telegram_user_id`。

#### FindNOC 登录

| 字段 | 类型 | 约束 |
| --- | --- | --- |
| `telegram_user_id` | `str` | `^\d{1,20}$` |
| `telegram_chat_id` | `str` | `^-?\d{1,20}$` |
| `username` | `str \| None` | 同上 |
| `asn` | `str \| None` | 最长 16；可带 `AS` 前缀，Handler 内规范化 |

### 9.2 端点清单

| # | 方法 | 路径 | 入参 | 成功响应 | 主要错误 |
| --- | --- | --- | --- | --- | --- |
| 1 | POST | `/challenge` | `ChallengeRequest` | `{token, url}` | 401 |
| 2 | POST | `/verify` | `VerifyRequest` | `{ok, asn, effective_mnt, authtype}` | 400、401 |
| 3 | POST | `/findnoc/login` | `FindNocLoginRequest` | `{ok, asn, method}` 或 `{need_choice, asns}` | 400、401、404、503 |
| 4 | POST | `/logout` | `LogoutRequest` | `{ok, asn}` | 401、404 |
| 5 | GET | `/peer/{telegram_user_id}` | 路径参数 | `{asn, peers:[...]}` | 401、404 |
| 6 | GET | `/nodes` | — | `{nodes:[{name, location}]}` | 401 |
| 7 | POST | `/peer/preview` | `PeerPreviewRequest` | `{ok, node, asn, endpoint, wg_mtu, peer_dn42_ipv4, peer_dn42_ipv6, peer_link_address, bgp_extended, peering}` | 400、401、404 |
| 8 | POST | `/peer/create` | `PeerCreateRequest` | `_peer_summary(peer)` | 400、401、404 |
| 9 | POST | `/peer/edit` | `PeerEditRequest` | `_peer_summary(peer)` | 400、401、404 |
| 10 | POST | `/peer/delete` | `PeerDeleteRequest` | `{ok, id}` | 400、401、404 |
| 11 | POST | `/status` | `PeerStatusRequest` | `{asn, peers:[...]}` | 401、404 |
| 12 | POST | `/lg` | `LGRequest` | 节点返回的 `{ok, output}` | 400、401、404 |

### 9.3 认证与挑战

#### `POST /challenge`

```python
challenge = create_challenge(
    db,
    purpose="telegram",
    telegram_user_id=payload.telegram_user_id,
    telegram_chat_id=payload.telegram_chat_id,
)
return ChallengeResponse(
    token=challenge.token,
    url=f"{settings.base_url}/telegram/auth?token={challenge.token}",
)
```

- `purpose="telegram"` 与 Web 的 `purpose="web"` 隔离；挑战不能跨端复用。
- `url` 必须由 `settings.base_url` 拼接，不能信任请求头 `Host`（否则可被伪造指向攻击者域名）。
- 挑战 TTL 600s，一次性消费。

#### `POST /verify`

完整流程：

```python
verifier = KioubitVerifier(settings.kioubit_public_key_path, settings.auth_domain)
data = verifier.verify(params=payload.params, signature=payload.signature)
challenge = consume_challenge(db, data.get("user_token", ""), purpose="telegram")
if challenge.telegram_user_id != payload.telegram_user_id:
    raise ValueError("Telegram user mismatch")
user = upsert_user_from_kioubit(db, data, settings)
bind_telegram(db, user, telegram_user_id=..., telegram_chat_id=..., username=...)
```

四道校验的顺序不能变：

1. **验签**：ECDSA/SHA-512，公钥来自 `KIOUBIT_PUBLIC_KEY_PATH`。
2. **消费挑战**：`user_token` 必须命中原挑战；已消费/过期/用途不符都拒绝。
3. **UID 一致性**：挑战里记录的 `telegram_user_id` 必须等于请求里的。否则 A 的签名可以被 B 提交，把 B 的 Telegram 绑定到 A 的 ASN。
4. **落库**：先 upsert 用户（可能新建），再绑定 Telegram。

失败统一转 400，返回 `detail` 给 Bot 展示。`upsert_user_from_kioubit` 还会写一条 `ASNIdentity` 审计行，记录 `mnt_json`、`effective_mnt`、`allowed4_json`、`allowed6_json`、`authtype`。

#### `POST /findnoc/login`

这是状态码契约最密集的端点，Bot 依赖它做回退判断：

| 状态码 | 含义 | Bot 行为 |
| --- | --- | --- |
| 200 + `{need_choice, asns}` | 用户控制多个 ASN | 展示 `fnlogin:` 按钮 |
| 200 + `{ok, asn, method}` | 登录成功 | 展示成功文案 |
| 400 | 用户选了不拥有的 ASN、ASN 格式错误 | 原样展示 `detail` |
| 404 | UID 不在 FindNOC | 回退 Kioubit |
| 503 | 功能未配置 / FindNOC 不可达 / token 被拒 | 回退 Kioubit |

实现分支：

```python
if not settings.findnoc_enabled:
    raise HTTPException(status_code=503, detail="FindNOC login is not configured")
uid = payload.telegram_user_id
try:
    if payload.asn is not None:
        asn_number = normalize_asn_number(payload.asn)   # ValueError -> 400
        if not await verify_control(uid, asn_number, settings):
            raise HTTPException(
                status_code=400,
                detail=f"FindNOC has no record that you control AS{asn_number}",
            )
        asns = [asn_number]
    else:
        asns = await query_user_asns(uid, settings)
        if not asns:
            raise HTTPException(
                status_code=404,
                detail="Your Telegram account is not registered in FindNOC",
            )
        if len(asns) > 1:
            return {"need_choice": True, "asns": [f"AS{a}" for a in asns]}
except FindNocError as exc:
    raise HTTPException(status_code=503, detail="FindNOC is currently unavailable") from exc
```

关键安全点：**带 `asn` 的路径必须重新调用 `verify_control`**。不能因为“上一轮 `query_user_asns` 返回过这个 ASN”就信任客户端传回的 `asn`。客户端可以改回调数据。

`query_user_asns` 的语义：

- `404` → `[]`（用户未注册）
- `403` → `FindNocError`（我们自己的 API token 错了，属于运维故障）
- 其他非 200 → `FindNocError`
- 非 JSON / 非 list → `FindNocError`
- 列表元素逐个 `normalize_asn_number`，非法项**跳过**而不是整体失败

#### `POST /logout`

```python
user = get_user_by_telegram(db, payload.telegram_user_id)
if user is None:
    raise HTTPException(status_code=404, detail="Telegram account is not verified")
unbind_telegram(db, payload.telegram_user_id)
return {"ok": True, "asn": user.primary_asn}
```

只删 `TelegramBinding`，不删 `User`、不删 `PeerRequest`。这是数据模型决策的直接体现：Peer 归属 `User`，不归属 Telegram。

### 9.4 Peer 读取端点

#### `GET /peer/{telegram_user_id}`

Bot 用它做两件事：校验账号已绑定（404 → 显示未绑定文案），以及给 `/edit`、`/delete` 提供列表。

响应字段刻意保持精简（不含 `peering`、不含实时状态），因为这是向导的数据源，不需要节点往返：

```json
{
  "asn": "4242421234",
  "peers": [
    {
      "id": "0f3c...",
      "node": "frankfurt",
      "status": "approved",
      "endpoint": "198.51.100.7:51820",
      "peer_dn42_ipv4": "172.20.1.2",
      "peer_dn42_ipv6": "fd00::2",
      "peer_link_address": "fe80::1234",
      "wg_mtu": 1420,
      "bgp_extended": true,
      "created_at": "2026-06-09T12:34:56+00:00"
    }
  ]
}
```

`created_at.isoformat()` 带时区（数据库存 UTC），Bot 只展示序号，不用这个字段。

#### `POST /status`

这是 `/listpeers` 的数据源，与其他端点不同：它会**逐个 peer 向节点发起 WSS 请求**。

```python
peers = peers_for_user_with_nodes(db, user.id)
client = NodeClient()

async def fetch(node: Node, protocol_name: str) -> dict[str, str]:
    try:
        result = await client.peer_status(node, protocol_name)
        return {
            "detail": summarize_peer_bird(str(result.get("output", ""))),
            "wg_detail": summarize_wireguard(str(result.get("wireguard", ""))),
        }
    except Exception as exc:
        return {"detail": f"status unavailable: {exc}", "wg_detail": ""}

snapshots = []
fetches = []
for peer in peers:
    node = peer.node
    snapshots.append({... 所有 ORM 字段 ...})
    fetches.append(fetch(node, peer_protocol_name(peer, node)))

details = await asyncio.gather(*fetches)
return {"asn": user.primary_asn,
        "peers": [{**snap, **detail} for snap, detail in zip(snapshots, details, strict=True)]}
```

必须遵守的三条：

1. **先把所有 ORM 字段读进 `snapshots`**，再 `await`。SQLAlchemy `Session` 不是协程安全的；在 `gather` 里访问 `peer.node` 会触发惰性加载并跨协程使用同一连接。
2. **单个节点失败不能让整批失败**。`fetch` 内捕获所有异常，降级为 `status unavailable: ...`。
3. **`strict=True`** 的 `zip`：`fetches` 与 `snapshots` 长度必须相等；若不等说明代码有 bug，应立刻暴露而不是静默丢数据。

`peering` 在快照阶段计算，因为它依赖 `node_effective_asn(node, settings.local_asn)`，属于纯内存计算。

### 9.5 Peer 写入端点

#### `POST /peer/preview`

```python
preview = preview_peer(
    user=user, node=node, endpoint=..., wg_public_key=..., wg_mtu=...,
    peer_dn42_ipv4=..., peer_dn42_ipv6=..., peer_link_address=...,
    bgp_extended=..., settings=settings,
)
values = preview["values"]
return {
    "ok": True, "node": node.name, "asn": user.primary_asn,
    "endpoint": values.endpoint, "wg_mtu": values.wg_mtu,
    "peer_dn42_ipv4": values.peer_dn42_ipv4, "peer_dn42_ipv6": values.peer_dn42_ipv6,
    "peer_link_address": values.peer_link_address, "bgp_extended": values.bgp_extended,
    "peering": preview["peering"],
}
```

它返回的是**归一化后的值**，不是用户输入。Bot 把这份值展示给用户确认，但真正创建时仍重新提交原始输入——因为 Bot 保存的是原始 payload（§8.5）。这看起来冗余，实际是必要的：预览不落库，归一化结果不能作为创建依据（否则等于信任客户端回传的归一化值）。

#### `POST /peer/create`

```python
user = get_user_by_telegram(db, payload.telegram_user_id)   # 404
node = enabled_node_by_name(db, payload.node)               # 404
peer = create_peer(db, user=user, node=node, ...)           # ValueError -> 400
return _peer_summary(peer)
```

`_peer_summary` 是创建/编辑的统一返回结构：

| 字段 | 说明 |
| --- | --- |
| `id`、`node`、`asn` | 标识 |
| `deploy_status` | `deploying`/`deployed`/`failed`/`removed` |
| `deploy_output` | 节点返回的完整输出 |
| `endpoint`、`peer_dn42_ipv4`、`peer_dn42_ipv6`、`peer_link_address`、`bgp_extended`、`wg_mtu` | 归一化后的存储值 |
| `peering` | 我方参数，`local_asn` 缺失时为 `<our-asn>` |

注意 `create_peer` 是**同步阻塞**的：它内部调用 `request_node_sync`，会等待节点完成 `wg-quick up`。这就是 Bot 的 POST 超时设为 40s 的原因。

#### `POST /peer/edit`

三态合并逻辑必须在 Handler 里完成：

```python
peer_dn42_ipv4 = payload.peer_dn42_ipv4 if payload.peer_dn42_ipv4 is not None else peer.peer_dn42_ipv4
peer_dn42_ipv6 = payload.peer_dn42_ipv6 if payload.peer_dn42_ipv6 is not None else peer.peer_dn42_ipv6
bgp_extended = payload.bgp_extended if payload.bgp_extended is not None else peer.bgp_extended
peer = update_peer(
    db, peer=peer, node=peer.node,
    endpoint=payload.endpoint, wg_public_key=payload.wg_public_key, wg_mtu=payload.wg_mtu,
    local_link_address=peer.local_link_address,
    peer_link_address=(payload.peer_link_address if payload.peer_link_address is not None else peer.peer_link_address),
    peer_dn42_ipv4=..., peer_dn42_ipv6=..., bgp_extended=...,
    status=peer.status, settings=settings, redeploy=True,
)
```

- `local_link_address` 永远取原值：Bot 无权改我方链路地址。
- `status` 永远取原值：Bot 无权审批。
- `node=peer.node`：Bot 不能迁移节点。
- `redeploy=True`：改完立刻重新下发，用户能马上看到新状态。

`_owned_peer` 封装了“账号必须存在 + peer 必须属于该账号”的双重校验，返回 404 而不是 403——避免泄露“这个 peer ID 存在但不属于你”。

#### `POST /peer/delete`

```python
peer = _owned_peer(db, payload.telegram_user_id, payload.peer_id)
delete_peer(db, peer=peer)
return {"ok": True, "id": payload.peer_id}
```

`delete_peer` 内部先 `teardown_peer_request`（节点拆除），再删数据库行。若拆除失败，`delete_peer` 仍会删除记录吗？原实现的行为是：`teardown_peer_request` 把 `deploy_status` 记为 `failed` 并保留记录，`delete_peer` 随后删除。这意味着**节点上可能残留配置**，但数据库已无记录，无法再自动清理。运维必须通过节点的 `wg show` / `/etc/bird/peers` 人工核对。这是原实现的已知取舍，复刻时至少要在文档里标注。

### 9.6 错误响应约定

FastAPI 默认返回：

```json
{"detail": "..."}
```

必须遵守：

- **400**：输入语义错误（`ValueError` 转换）。`detail` 直接来自异常文本，是可展示给用户的中文/英文短句。
- **401**：Bot 密钥错误。不要在 `detail` 里回显收到的密钥。
- **404**：账号未绑定、peer 不存在、节点不存在/禁用。Bot 会把“账号未绑定”的 404 替换成 `NOT_LINKED_MSG`。
- **422**：Pydantic 校验失败。Bot 不单独处理，会落进 `BackendStatusError` 并展示 `detail`（可能是结构化数组的字符串形式）。
- **500**：未捕获异常。Bot 显示 `HTTP 500`。生产中应通过日志定位。

### 9.7 `require_bot_secret` 的边界

- 它是 **router 级依赖**，挂在每个端点上，不是全局中间件。这样 Web 页面不会受影响。
- 它**不校验来源 IP**。安全边界是“共享密钥 + TLS”，不是网络位置。
- 它**不做限流**。Bot 是唯一合法调用方，且 `TELEGRAM_BACKEND_SECRET` 泄露前无法被滥用。若要防御密钥泄露后的滥用，应在反代层加 IP 白名单或额外限流。

### 9.8 实现陷阱

1. **不要在 `require_bot_secret` 里用 `!=`**。定时攻击在共享密钥场景是真实威胁，尤其当密钥可被逐字节猜测时。
2. **`telegram_user_id` 必须是字符串**。Telegram 用户 ID 已超过 32 位，JS/JSON 数字在某些客户端会丢精度；Pydantic 用 `str` 加正则强制。
3. **`challenge.telegram_user_id` 比较必须在消费之后**。顺序反了会让“已消费”的挑战在校验失败时仍然被标记为已用，造成用户无法重试。
4. **`consume_challenge` 必须区分 purpose**。Web 挑战若能被 Telegram 流程消费，等于绕过了“绑定 Telegram UID”这一环。
5. **`verify` 的 `params` 不能被 URL 解码二次处理**。它是 base64 字符串，签名针对**原始字符串**计算；任何 decode 都会破坏验签。
6. **`/findnoc/login` 的 `need_choice` 分支不写库**。只返回列表，等用户点选后再走带 `asn` 的路径；否则会在用户尚未选择时就把 UID 绑到第一个 ASN。
7. **`/status` 的节点并发不要加信号量**。节点侧已有 `max_concurrency`，Backend 再加一层会让“一个用户查 20 个 peer”变成串行。`asyncio.gather` 让节点侧自己去排队。
8. **`_peer_summary` 的 `local_asn` 兜底为 `<our-asn>`**。前端/ Bot 会原样展示这个占位符，因此 `peering_info_lines` 必须能处理它（§8.8）。
9. **`/peer/edit` 的 `endpoint` 是必填**。Bot 在编辑向导里把 `skip` 转成空串后提交，语义是“清空端点”；如果做成可选，Bot 无法表达“清空”。
10. **`/peer/delete` 返回 `ok` 而不是完整 peer**。Bot 删除后不再需要详情；返回完整对象会让 Bot 误以为还能展示。

## §10 认证流程

系统有三条登录路径，但最终都归一到同一个身份模型：**ASN → User**，并按需绑定 **Telegram UID**。

| 路径 | 入口 | 证明方式 | 产出 |
| --- | --- | --- | --- |
| Web（Kioubit） | `/login` → 外部 Kioubit → `/auth/kioubit/callback` | Kioubit 对 params 的 ECDSA 签名 | 浏览器 Session Cookie |
| Bot（Kioubit Mini App） | `/login` 命令 → Web App → `sendData` → `web_app_data` | 同一签名 + 挑战中的 Telegram UID | `TelegramBinding` |
| Bot（FindNOC 快速登录） | `/login` 命令 → Backend 直接查 FindNOC | 我们在服务端向 FindNOC 查询 UID→ASN | `TelegramBinding` |

### 10.1 Kioubit 令牌格式与验签

`params` 是 **base64(JSON)** 字符串，`signature` 是 **base64(ECDSA-SHA512 签名)**。JSON 至少包含：

| 字段 | 类型 | 用途 |
| --- | --- | --- |
| `time` | 数字（Unix 秒） | 重放窗口判断 |
| `domain` | 字符串 | 必须等于 `AUTH_DOMAIN` |
| `asn` | 字符串 | 裸数字或带 `AS`，后续由 `normalize_asn_number` 统一 |
| `mnt` | 列表或逗号串 | 维护者列表，写审计 |
| `effective_mnt` | 字符串 | 展示给用户 |
| `allowed4` / `allowed6` | 列表或逗号串 | 审计 |
| `authtype` | 字符串 | 展示与审计 |
| `first_email` | 字符串 | 可选，写入 User |
| `user_token` | 字符串 | 关联 `auth_challenges.token` |

验签步骤（顺序不可变）：

```python
if self.public_key is None:
    raise KioubitAuthError("Kioubit public key is not installed")
if not isinstance(self.public_key, ec.EllipticCurvePublicKey):
    raise KioubitAuthError("Kioubit public key is not an EC public key")
signature_bytes = base64.b64decode(signature)
self.public_key.verify(signature_bytes, params.encode(), ec.ECDSA(hashes.SHA512()))
decoded = base64.b64decode(params)
data = json.loads(decoded)
```

注意：

- 签名针对 **`params` 原始字符串的 UTF-8 字节**，不是解码后的 JSON。任何 `unquote`、`strip`、重新序列化都会破坏验签。
- 验签在解析 JSON **之前**。先解析再验签等于让攻击者用任意 JSON 触发解析器异常。
- `base64.b64decode` 默认不严格；若要更稳妥可加 `validate=True`，但会拒绝部分带换行的合法输入。原实现取宽松。

随后是三道语义校验：

```python
now = time.time()
auth_time = float(data.get("time", 0))
if abs(now - auth_time) > self.max_age_seconds:
    raise KioubitAuthError("Kioubit token has expired")

if str(data.get("domain", "")) != self.domain:
    raise KioubitAuthError("Kioubit token was issued for a different domain")

asn = str(data.get("asn", "")).strip()
if not asn:
    raise KioubitAuthError("Kioubit token did not include an ASN")
```

- **双向窗口**：`abs(now - auth_time) > 60`。允许 ±60s 时钟偏差，同时拒绝明显来自未来的令牌。
- **domain 精确匹配**：构造器里先剥掉 `https://`、`http://` 与尾斜杠，再与令牌里的 `domain` 比较。这样配置写 `https://dn42.example.com/` 也能匹配。
- **ASN 必填**：空 ASN 直接拒绝，避免后续 `normalize_asn_number("")` 抛错变成 500。

`_normalize_list` 处理三种形态：`None → []`、`list → 逐项 strip`、`str → 按逗号切`、其他 → 单元素。这容忍了 Kioubit 不同版本字段格式的差异。

### 10.2 Web 登录流程

```text
浏览器 GET /login
  → create_challenge(db, purpose="web")           # token, TTL 600s
  → 渲染 login.html，注入 return_url + token
  → <kioubit-auth-btn return="..." token="...">
  → 用户点击，组件 POST 表单到 https://dn42.g-load.eu/auth/
      表单字段：return=<return_url>、token=<token>
  → Kioubit 验明 ASN 后 302 回 return_url，带 ?params=...&signature=...
浏览器 GET /auth/kioubit/callback?params=&signature=
  → KioubitVerifier.verify()
  → consume_challenge(db, data["user_token"], purpose="web")
  → upsert_user_from_kioubit()
  → login_user(request, user)                     # session["user_id"] = user.id
  → 303 重定向 /portal
```

关键点：

- `return_url = f"{settings.base_url}/auth/kioubit/callback"`。必须使用配置的 `base_url`，不能用请求的 `Host`，否则反代配置错误时会生成错误回调地址。
- `consume_challenge` **没有**校验挑战与请求的其他绑定信息（Web 端没有 UID）。它的作用是确保“这次登录是从我们的 `/login` 页面发起的”，从而防止把别处获得的令牌直接贴到回调地址完成登录（CSRF/令牌注入）。
- 回调是 **GET**，因为 Kioubit 以 302 跳转带回参数。这意味着 URL 会出现在浏览器历史与反代日志里；`params` 里含有 ASN 与 mnt，不含密钥，可接受。
- 登录成功后不返回 HTML，而是 303 到 `/portal`，避免刷新重复提交。

`login_user` / `current_user` 的实现刻意极简：

```python
SESSION_USER_KEY = "user_id"

def login_user(request: Request, user: User) -> None:
    request.session[SESSION_USER_KEY] = user.id

def logout_user(request: Request) -> None:
    request.session.pop(SESSION_USER_KEY, None)

def current_user(request: Request, db: Session) -> User | None:
    user_id = request.session.get(SESSION_USER_KEY)
    if not user_id:
        return None
    return db.query(User).filter(User.id == int(user_id)).one_or_none()
```

- Session 由 `SessionMiddleware` 的签名 Cookie 承载，内容对客户端可见但不可篡改。因此只放 `user_id`，不放 ASN/角色。
- **每次请求都查库**，所以管理员被降权、用户被删除会立即生效。代价是每请求一次主键查询，可接受。
- `int(user_id)` 可能抛 `ValueError`（用户篡改 Cookie 但签名仍有效？实际不可能，除非密钥泄露）。若要更稳健可 try/except 返回 `None`。

### 10.3 Telegram Mini App 流程

这是“Web 登录 + Telegram 绑定”的组合，多了一步 **UID 一致性校验**。

```text
Bot /login
  → POST /api/telegram/challenge {uid, chat_id}
  → 返回 {token, url=https://<DOMAIN>/telegram/auth?token=...}
  → Bot 发 WebApp 按钮

用户在 Telegram 内打开 url
  → GET /telegram/auth?token=... 渲染 telegram_auth.html
  → 页面加载 telegram-web-app.js 与 kioubit-auth-button.js
  → <kioubit-auth-btn return="<同一个 url>" token="...">

用户点击，跳 Kioubit 验证
  → 302 回 /telegram/auth?token=...&params=...&signature=...
  → 页面检测到 URL 有 params，隐藏 UI，显示 loader
  → tg.sendData(JSON.stringify({params, signature}))

Telegram 把数据作为 web_app_data 消息发给 Bot
  → Bot json.loads → {params, signature}
  → POST /api/telegram/verify {uid, chat_id, username, params, signature}

Backend:
  → verify signature
  → consume_challenge(user_token, purpose="telegram")
  → challenge.telegram_user_id == payload.telegram_user_id   # 关键
  → upsert_user_from_kioubit + bind_telegram
```

`telegram_auth.html` 的关键逻辑（原文行为）：

```html
<script src="https://telegram.org/js/telegram-web-app.js"></script>
<script src="/static/kioubit-auth-button.js"></script>
<kioubit-auth-btn return="{{ return_url }}" token="{{ token }}"></kioubit-auth-btn>
<script>
  const tg = window.Telegram.WebApp;
  tg.ready();
  const params = new URLSearchParams(location.search);
  if (params.has("params")) {
    // 隐藏按钮，显示 loader
    tg.sendData(JSON.stringify({ params: params.get("params"), signature: params.get("signature") }));
  }
</script>
```

要点：

- `return_url` 必须**包含 token**，否则回调回来时页面无法把结果与挑战关联（虽然 `params` 里也有 `user_token`，但页面逻辑依赖 URL 的 token 判断是否处于回调态）。
- `sendData` 只接受字符串，且上限 4096 字节。Kioubit 的 params+signature 通常远小于此，但超长时会失败，需要提示。
- 页面不自己调用后端，所有验证都在 Bot 侧完成。原因是 Mini App 运行在 Telegram 的 WebView 里，无法安全持有 `X-Backend-Secret`。
- 若 `DOMAIN` 不是 https，Bot 在发按钮前就拦截（§8.7），因为 Telegram 拒绝打开非 https 的 WebApp。

### 10.4 FindNOC 快速登录

FindNOC 是一个“Telegram UID → 控制的 ASN”查询服务。它把认证简化为“你的 Telegram 账号已在 FindNOC 登记过”。

API 约定（`app/auth/findnoc.py`）：

| 端点 | 参数 | 返回 | 语义 |
| --- | --- | --- | --- |
| `GET {base}/queryUser` | `userid`、`token` | JSON 数组 | 该 UID 控制的 ASN 列表；404 表示未登记 |
| `GET {base}/verify` | `userid`、`ASN=AS<num>`、`token` | `{"result": bool}` | 该 UID 是否控制该 ASN |

实现约束：

- **API token 放在 query string**。这是 FindNOC 的接口设计，不是我们的选择。因此模块内**禁止记录完整 URL 或原始异常文本**：

```python
except (OSError, TimeoutError, ValueError) as exc:
    logger.warning("FindNOC %s request failed: %s", path, type(exc).__name__)
    raise FindNocError("FindNOC is unreachable") from None
```

只记录 `path` 与异常类型，避免 token 泄露进日志。

- 使用 `asyncio.to_thread` 包装同步 `urllib`，不阻塞事件循环。
- 超时 10s。
- `User-Agent: dn42-autopeer-findnoc/0.1` 便于对方识别流量来源。
- 403 单独处理：表示**我们的** token 无效，属于配置错误，应产生 `FindNocError` 并最终变成 503，而不是 404。

`findnoc_enabled` 的定义（`app/config.py`）：

```python
@property
def findnoc_enabled(self) -> bool:
    return bool(self.findnoc_api_url.strip() and self.findnoc_api_token.strip())
```

即：URL 与 token 都配置才启用。只配一个视为未启用，走 Kioubit。

### 10.5 身份归一与管理员规则

`_upsert_user_for_asn` 是三条路径的公共落点：

```python
user = db.query(User).filter(User.primary_asn == asn).one_or_none()
if user is None:
    user = User(primary_asn=asn)
    db.add(user)
if first_email:
    user.first_email = first_email
try:
    user.is_admin = normalize_asn_number(asn) == normalize_asn_number(settings.local_asn)
except ValueError:
    user.is_admin = False
user.last_login_at = utcnow()
db.commit()
```

必须理解的四点：

1. **`primary_asn` 是唯一键**。因此同一个 ASN 无论用 Kioubit 还是 FindNOC 登录，都会落到同一行 `User`，其 Peer 也就在两种登录方式间共享。
2. **管理员每次登录重算**。`is_admin` 不是永久授予：如果运营者把 `LOCAL_ASN` 改掉，下次登录时旧管理员的 `is_admin` 会被置为 `False`。这是刻意的“配置即真相”。
3. **`normalize_asn_number` 可能抛错**。`LOCAL_ASN` 写错时不能让登录失败，所以包在 try/except 里降级为 `is_admin=False`。
4. **`last_login_at` 每次登录刷新**。管理员用户列表用它判断活跃度。

两条 upsert 的差异：

| 函数 | 额外写入 |
| --- | --- |
| `upsert_user_from_kioubit` | `ASNIdentity` 含 `mnt_json`、`effective_mnt`、`allowed4_json`、`allowed6_json`、`authtype` |
| `upsert_user_from_findnoc` | `ASNIdentity` 仅 `asn` 与 `authtype="findnoc"` |

`ASNIdentity` 是**追加式审计**，不是当前状态：每次登录都会新增一行。查询时不要假设只有一行。

### 10.6 Telegram 绑定

```python
def bind_telegram(db, user, telegram_user_id, telegram_chat_id, username=None):
    binding = db.query(TelegramBinding).filter(
        TelegramBinding.telegram_user_id == telegram_user_id
    ).one_or_none()
    if binding is None:
        binding = TelegramBinding(
            user_id=user.id,
            telegram_user_id=telegram_user_id,
            telegram_chat_id=telegram_chat_id,
            username=username,
        )
        db.add(binding)
    else:
        binding.user_id = user.id
        binding.telegram_chat_id = telegram_chat_id
        binding.username = username
        binding.linked_at = utcnow()
    db.commit()
```

语义：

- **一个 Telegram UID 只能绑定一个 User**（`telegram_user_id` 唯一）。重复登录会把绑定改到新验证出的 ASN。
- **一个 User 可以有多个 Telegram UID 绑定**（表上没有 `user_id` 唯一约束）。这意味着同一个人可以用两个 Telegram 账号控制同一个 ASN。
- `linked_at` 在重新绑定时刷新，便于审计“最近一次绑定时间”。
- `telegram_chat_id` 跟着绑定一起更新，因为用户可能换私聊窗口。

`unbind_telegram` 只删绑定行，返回是否曾经存在：

```python
binding = db.query(TelegramBinding).filter(
    TelegramBinding.telegram_user_id == telegram_user_id
).one_or_none()
if binding is None:
    return False
db.delete(binding)
db.commit()
return True
```

### 10.7 `kioubit-auth-btn` 组件规范

这是一个 **closed shadow DOM 的 Web Component**，把“跳转 Kioubit”封装成一个标签。

必须实现的属性：

| 属性 | 作用 |
| --- | --- |
| `return` | 回调 URL。绝对 URL 原样使用；以 `/` 开头则拼 `location.origin`；否则拼 `location.pathname` 的目录 |
| `token` | 透传给 Kioubit 的挑战 token |

渲染出的表单固定指向：

```html
<form action="https://dn42.g-load.eu/auth/" method="post">
  <input type="hidden" name="return" value="...">
  <input type="hidden" name="token" value="...">
  <button type="submit">Authenticate with Kioubit.dn42</button>
</form>
```

实现要点：

- `attachShadow({mode: "closed"})`：外部脚本无法读取内部表单，减少令牌被第三方脚本抓取的风险。
- 样式与 SVG 以静态字段内联，避免额外请求。SVG 用 `btoa` 转成 data URI，避免引号转义问题。
- `observedAttributes = ["return", "token"]`，属性变化时重渲染。
- 硬编码 Kioubit 地址是**产品约束**，不是配置项。复刻时若 Kioubit 更换域名，必须改组件源码并更新前端缓存。

### 10.8 认证实现陷阱

1. **`params` 的 base64 解码必须用 `b64decode` 而不是 `urlsafe_b64decode`**。Kioubit 用标准 base64；用 urlsafe 会在含 `+`/`/` 的令牌上失败。
2. **`domain` 比较前只剥协议与尾斜杠**。不要做大小写归一（域名本就大小写不敏感，但 Kioubit 签发时用原样字符串；归一可能造成“看似相同却不匹配”）。原实现严格 `==`。
3. **挑战消费必须在 upsert 之前**。顺序反了会在挑战过期时仍然创建/更新 User，留下“登录过但没有绑定”的脏数据。
4. **`bind_telegram` 不校验 `user` 是否已验证**。它假设调用方已通过验签。不要把它暴露成独立端点。
5. **Web Session 的 `user_id` 是整数**。`current_user` 用 `int()` 转换；若 Cookie 被篡改（签名验证失败时 SessionMiddleware 会丢弃整个 session），不会走到这里。
6. **不要在 Web 回调里绑定 Telegram**。Web 流程没有 UID，绑定会让“任意浏览器登录”变成“绑定某个 Telegram”，语义错误。
7. **FindNOC 的 404 与 503 都要回退，但原因不同**。404 是“用户没登记”，503 是“服务不可用/未配置”。Bot 都回退 Kioubit，但运维排查时看日志要能区分。
8. **`verify_control` 的返回必须是严格布尔**。FindNOC 返回 `{"result": 1}` 或 `{"result": true}`，用 `bool()` 归一；若返回字符串 `"false"`，`bool("false")` 为真——这是潜在坑。原实现只接受 dict 并取 `result`，复刻时应额外判 `is True` 或显式处理字符串。
9. **`upsert_user_from_kioubit` 会 `commit` 两次**（一次在 `_upsert_user_for_asn`，一次在写 identity 后）。这不是 bug，但意味着 identity 写入失败时 User 已持久化；复刻时应接受这个“部分成功”语义，或在事务里包起来。
10. **`local_asn` 为空时 `is_admin` 恒为 False**。这是安全的默认值：未配置 LOCAL_ASN 的部署没有管理员，只能通过直接改库授予。

---

## 11. Web UI 规格

本章描述服务端渲染（SSR）的整套页面：路由、渲染管线、模板上下文、表单字段、文案与前端渐进增强脚本。所有页面都是 Jinja2 服务端渲染，没有 SPA、没有前端路由、没有打包工具。`app/static/app.js` 与 `app/static/kioubit-auth-button.js` 是仅有的两个 JS 文件，且都是**渐进增强**性质——关掉 JS，核心流程（登录、建 Peer、删 Peer、跑 LG）依然可用。

### 11.1 路由总表

下表是全部 Web 路由。分组：公开页 / 认证 / 用户门户 / Looking Glass / 管理后台。`依赖` 列写该路由在进入处理函数前必须满足的条件。

| # | 方法 | 路径 | 所属路由模块 | 依赖 | 响应 |
|---|------|------|--------------|------|------|
| 1 | GET | `/` | `app/web/pages.py` | 无 | HTML 首页 |
| 2 | GET | `/login` | `app/web/pages.py` | 无 | HTML 登录页 |
| 3 | GET | `/logout` | `app/web/pages.py` | 无（幂等） | 303 → `/` |
| 4 | GET | `/auth/kioubit/callback` | `app/web/pages.py` | 无（自校验） | 303 → `/portal` 或 `/login?error=...` |
| 5 | GET | `/telegram/auth` | `app/web/pages.py` | 无 | HTML Mini App 桥页 |
| 6 | GET | `/portal` | `app/web/portal.py` | 登录 | HTML 我的 Peer 列表 |
| 7 | GET | `/portal/new` | `app/web/portal.py` | 登录 | HTML 新建表单 |
| 8 | POST | `/portal/peers/confirm` | `app/web/portal.py` | 登录 | HTML 确认页（不落库） |
| 9 | POST | `/portal/peers` | `app/web/portal.py` | 登录 | 303 → `/portal/peers/{id}` 或回显错误 |
| 10 | GET | `/portal/peers/{peer_id}` | `app/web/portal.py` | 登录 + 归属 | HTML 详情（含实时状态） |
| 11 | POST | `/portal/peers/{peer_id}/delete` | `app/web/portal.py` | 登录 + 归属 | 303 → `/portal` |
| 12 | GET | `/portal/peers/{peer_id}/config` | `app/web/portal.py` | 登录 + 归属 | `text/plain` 配置全文 |
| 13 | GET | `/lg` | `app/web/lg.py` | 无 | HTML 查询表单 |
| 14 | POST | `/lg` | `app/web/lg.py` | 无（限流） | HTML 或 JSON（见 11.6.3） |
| 15 | GET | `/admin` | `app/web/admin.py` | 登录 + 管理员 | HTML 总览 |
| 16 | GET | `/admin/nodes` | `app/web/admin.py` | 登录 + 管理员 | HTML 节点列表 |
| 17 | GET | `/admin/nodes/{node_id}/edit` | `app/web/admin.py` | 登录 + 管理员 | HTML 节点编辑 |
| 18 | POST | `/admin/nodes` | `app/web/admin.py` | 登录 + 管理员 | 303 → 列表 |
| 19 | POST | `/admin/nodes/{node_id}/update` | `app/web/admin.py` | 登录 + 管理员 | 303 |
| 20 | POST | `/admin/nodes/{node_id}/refresh-pubkey` | `app/web/admin.py` | 登录 + 管理员 | 303（向节点发 `pubkey`） |
| 21 | POST | `/admin/nodes/{node_id}/reset-token` | `app/web/admin.py` | 登录 + 管理员 | 303（新 token 只显示一次） |
| 22 | POST | `/admin/nodes/{node_id}/delete` | `app/web/admin.py` | 登录 + 管理员 | 303（有 Peer 则拒绝） |
| 23 | GET | `/admin/peers` | `app/web/admin.py` | 登录 + 管理员 | HTML 全量 Peer 列表 |
| 24 | GET | `/admin/peers/{peer_id}/edit` | `app/web/admin.py` | 登录 + 管理员 | HTML Peer 编辑 |
| 25 | POST | `/admin/peers` | `app/web/admin.py` | 登录 + 管理员 | 303（可自动建 User） |
| 26 | POST | `/admin/peers/{peer_id}/update` | `app/web/admin.py` | 登录 + 管理员 | 303（不触发重部署） |
| 27 | POST | `/admin/peers/{peer_id}/redeploy` | `app/web/admin.py` | 登录 + 管理员 | 303（仅 `approved` 可） |
| 28 | POST | `/admin/peers/{peer_id}/delete` | `app/web/admin.py` | 登录 + 管理员 | 303 |
| 29 | GET | `/admin/peers/{peer_id}/config` | `app/web/admin.py` | 登录 + 管理员 | `text/plain` |
| 30 | GET | `/admin/peers/{peer_id}/status` | `app/web/admin.py` | 登录 + 管理员 | HTML 片段式状态页 |
| 31 | GET | `/admin/users` | `app/web/admin.py` | 登录 + 管理员 | HTML 用户列表 |
| 32 | POST | `/admin/users/{user_id}/toggle-admin` | `app/web/admin.py` | 登录 + 管理员 | 303（禁止自锁） |
| 33 | POST | `/admin/users/{user_id}/unlink-telegram` | `app/web/admin.py` | 登录 + 管理员 | 303 |
| 34 | GET | `/admin/lg-log` | `app/web/admin.py` | 登录 + 管理员 | HTML LG 审计日志 |
| 35 | GET | `/static/*` | Starlette StaticFiles | 无 | 静态文件 |

`/api/*` 与 `/api/nodes/ws` 不在本表，见第 5 章与第 9 章。

**必须**：路由注册顺序为 `pages` → `portal` → `lg` → `admin` → `telegram`(API) → `node_ws`。其中 `/api/telegram/*` 必须在 `node_ws` 之前注册，否则 WebSocket 路由的路径匹配可能抢先。`app/main.py` 的注册顺序见 3.3。

### 11.2 渲染管线：`render()` 与 base context

所有 SSR 页面都经过同一个 `render()`（`app/web/deps.py`）：

```python
def render(
    request: Request,
    name: str,
    context: dict | None = None,
    user: User | None = None,
    active: str | None = None,
) -> HTMLResponse:
    base = {
        "request": request,
        "settings": settings,
        "user": user,
        "active": active,
        "flashes": request.session.pop(_FLASH_KEY, []),
    }
    if context:
        base.update(context)
    return templates.TemplateResponse(request=request, name=name, context=base)
```

**必须注意签名**：`render` 是 `render(request, template_name, context_dict, user=..., active=...)`，**不是** `render(request, name, user=..., **context)`。`user` 必须由调用方显式传入（通常是 `current_user(request, db)`），`render` 自己不查库。这一点和很多 FastAPI 模板封装的习惯相反，复刻时极易写错。

要点：

1. **`user` 由调用方传入**。每个路由自己调 `current_user(request, db)`，也顺便用于鉴权分支。`render` 只负责塞进上下文。
2. **`active` 用于导航高亮**。`base.html` 里 topbar 的每个链接比对 `active` 值：`home` / `lg` / `portal` / `new` / `admin`。传 `None` 表示不高亮任何项（登录页、错误页）。注意 `/portal/new` 用的是 `new`（不是 `portal`），所以“New Peer”页不会高亮“My Peers”。
3. **`flashes` 是“取出即清空”**。`request.session.pop(_FLASH_KEY, [])` 在渲染时执行，因此一条 flash 只会显示一次。重定向不经过 `render`，所以 flash 能跨过一次 303 活到下一个页面——这正是“POST → 303 → 页面看到提示”的实现方式。
4. **`context` 可以覆盖 base 键**。`base.update(context)` 在后，所以调用方理论上可以覆盖 `user` 或 `flashes`（原实现没有用到）。
5. **`templates` 是模块级单例**，`Jinja2Templates(directory="app/templates")`。它依赖**进程工作目录**必须是仓库根目录；用 systemd 启动时要显式设 `WorkingDirectory`（见 2.5）。
6. **`settings` 也是模块级单例**（`get_settings()`），在 import 时求值一次。因此改 `.env` 必须重启进程。

**必须**：模板里的所有用户可控文本默认经过 Jinja2 自动转义。不要对用户输入使用 `|safe`。`code_block` 宏内部也只做转义后的 `<pre>` 包裹（见 11.9.1）。

### 11.3 `flash()` 一次性消息

```python
_FLASH_KEY = "_flash"

def flash(request: Request, message: str, category: str = "info") -> None:
    request.session.setdefault(_FLASH_KEY, []).append({"category": category, "message": message})
```

语义：

| 项 | 规则 |
|----|------|
| `category` 取值 | `info` / `success` / `error`（`error` 在模板中渲染为红色条） |
| 存储位置 | Starlette `SessionMiddleware` 的签名 Cookie，**明文可见**（只签名不加密） |
| 容量 | 未限制；但 Cookie 有 4KB 上限，一次塞超过约 30 条会静默失败 |
| 消费时机 | `render()` 里的 `pop` |
| 跨重定向 | 保留（重定向不经过 `render`） |
| 跨请求不渲染 | 若连续两次重定向，flash 会累积到下一次渲染 |

**必须**：flash 内容不得包含 secret（session 是签名不加密的 Cookie，用户可解码看到）。原实现只 flash 人类可读的短句，如 `Peer created. Deployment queued.`。

**建议**：写 flash 后立刻 `RedirectResponse(status_code=303)`，不要在同一个请求里既 flash 又渲染——否则 flash 会在当前页显示后又被清空，用户点刷新就看不到了。

### 11.4 `Pagination` 分页数学

```python
@dataclass
class Pagination:
    page: int
    per_page: int
    total: int

    def __post_init__(self) -> None:
        self.page = max(1, min(self.page, self.pages))

    @property
    def pages(self) -> int:
        return max(1, math.ceil(self.total / self.per_page))

    @property
    def offset(self) -> int:
        return (self.page - 1) * self.per_page

    @property
    def has_prev(self) -> bool:
        return self.page > 1

    @property
    def has_next(self) -> bool:
        return self.page < self.pages
```

调用方只需把原始 `page` 与总数传进来，夹紧在 `__post_init__` 里完成：

```python
pagination = Pagination(page=_page_param(request), per_page=LG_LOG_PER_PAGE, total=total)
rows = query.offset(pagination.offset).limit(pagination.per_page).all()
```

要点：

1. **`page` 越界在构造时被夹紧**，不会报错也不会返回空页。`?page=999` 会返回最后一页。
2. **`?page=abc` 静默回落到第 1 页**（`_page_param` 里 `int()` 失败即 1）。这是有意的宽松策略。
3. **`total` 来自独立的 `count` 查询**，`offset` 用于 `LIMIT/OFFSET`。
4. 每页条数：`LG_LOG_PER_PAGE = 50`、`PEERS_PER_PAGE = 50`。用户列表未分页（原实现全量，适合中小规模部署）。
5. 模板宏 `pagination(p)` 用 `pages`/`has_prev`/`has_next` 渲染；只有一页时返回空。
6. **`Pagination` 是普通 dataclass，不是 Pydantic 模型**，所以 `per_page=0` 会触发除零。调用方必须传正数常量。

### 11.5 `client_ip()` 与 `FORWARDED_IP_HEADER`

```python
def client_ip(request: Request) -> str:
    header = settings.forwarded_ip_header.strip()
    if header:
        value = request.headers.get(header, "")
        if value:
            return value.split(",")[0].strip()
    return request.client.host if request.client else "unknown"
```

用途：LG 限流键（见 12.4）与 LG 审计日志的 `client_ip` 字段。

要点：

1. **默认不信任任何转发头**。`FORWARDED_IP_HEADER` 为空时只用 TCP 对端地址。这是安全的默认值：绕过反代直连时无法伪造。
2. **只在可信反代后设置**。典型配置 `FORWARDED_IP_HEADER=X-Forwarded-For`。若反代不覆盖该头，客户端可以伪造——nginx 必须用 `proxy_set_header X-Forwarded-For $remote_addr;`（不是 `$proxy_add_x_forwarded_for`，后者会追加而非覆盖）。
3. **取首段**（`split(",")[0]`）。这假设反代把真实客户端放在最左。若有多层反代，需要改成取最后一跳，或让反代只写单值。
4. **兜底 `"unknown"`**。所有未知来源共用一个限流桶——这是有意的：宁可误伤也不放宽。

**必须**：若部署在 Cloudflare 等 CDN 后，不要直接把 `CF-Connecting-IP` 配成 `FORWARDED_IP_HEADER` 而不校验回源 IP，否则任何人都能伪造该头绕过限流。

### 11.6 管理员校验与公开页面

#### 11.6.1 `require_admin()`

```python
def require_admin(request: Request, db: Session = Depends(get_db)) -> User:
    user = current_user(request, db)
    if user is None or not user.is_admin:
        raise HTTPException(status_code=403, detail="Admin access required")
    return user
```

路由里以依赖方式使用：

```python
@router.get("/admin")
def admin_overview(request: Request, admin: User = Depends(require_admin),
                   db: Session = Depends(get_db)):
    ...
```

要点：

1. **未登录也返回 403，而不是 303 到登录页**。原实现的选择：匿名访问后台与“登录了但非管理员”得到同一个响应，不暴露差异。门户路由则相反，未登录 303 到 `/login`（见 11.7）。
2. **`get_db` 是请求级缓存的**。`require_admin` 声明了 `Depends(get_db)`，路由自己也声明 `Depends(get_db)`，两者共享同一个 Session，不会开两次连接。复刻时不要用 `SessionLocal()` 手工建库会话。
3. **`is_admin` 是持久化字段，且每次登录被重算**（见 10.5 的 `_upsert_user_for_asn`）。`current_user` 每请求查库，所以“管理员 A 把 B 降权”在下一次请求立即生效，不需要 B 重新登录。反过来有个更隐蔽的坑：**A 给非本 ASN 的 B 手工授予管理员，B 下次登录时 `is_admin = (B.asn == LOCAL_ASN)` 会把手工授予覆盖回 False**。原实现就是这个行为，复刻时要么接受（管理员只能是 LOCAL_ASN），要么把重算改成 `is_admin = existing or (asn == local)` 并明确记录这个决策。
4. 403 由 `app/main.py` 的 `HTTPException` 处理器渲染 `error.html`（见 3.3）。

#### 11.6.2 首页 `/`

`home` 处理函数：

```python
@router.get("/", response_class=HTMLResponse)
def home(request: Request, db: Session = Depends(get_db)) -> HTMLResponse:
    nodes = query_enabled_nodes(db).all()
    runtime = node_runtime_context(nodes)
    nodes_online = sum(1 for item in runtime.values() if item["online"])
    return render(
        request,
        "home.html",
        {"nodes": nodes, "node_runtime": runtime, "nodes_online": nodes_online},
        user=current_user(request, db),
        active="home",
    )
```

`node_runtime_context(nodes)` 返回 `dict[node_id, dict]`，每个值是 6.7 描述的结构（`online` / `system_summary` / `resource_metrics` / `last_seen_at` 等），**不是**对象。模板用 `{% set rt = node_runtime[node.id] %}` 然后 `rt.online` 访问——Jinja2 对 dict 的 `.` 访问等价于 `["key"]`，所以 `rt.online` 能取到 dict 里的 `"online"` 键。复刻时若改成 dataclass，模板不用改；但若改成 `SimpleNamespace` 以外的对象，要注意 `rt.get(...)` 之类写法不可用。

模板结构（`home.html`）：

- **hero 区**：`settings.app_name` 大标题；`settings.local_asn` 存在时显示 `AS{local_asn}` 徽标；tagline 两行（`Automated dn42 peering and a public looking glass across our nodes.` + `Bring your ASN, pick a node, and get a ready-to-use WireGuard + BGP config.`）；两个按钮：`Open Looking Glass`（→ `/lg`），登录后 `Create a peer`（→ `/portal/new`），未登录则 `Peer with us`（→ `/login`）。
- **How to peer with us**：4 步 `<ol>`（原文见附录 A）。
- **Nodes**：标题行右侧 `{nodes_online} / {nodes|length} online`；每个节点一张 `pop-card`：
  - `online-state is-online` / `is-offline` + `online-dot`
  - `pop-name` / `pop-loc`
  - 在线：`rt.system_summary` + `rt.resource_metrics` 列表（每项 `m.label` / `m.value`）
  - 离线：`Last seen {rt.last_seen_at:%Y-%m-%d %H:%M} UTC`；从未上线则 `No heartbeat yet`
- 无节点：`No nodes are configured yet.`

**必须**：首页数据全部来自**内存态**（`node_runtime_context`），离线节点照样渲染卡片，只是显示离线态。这保证节点宕机不会让首页出错或阻塞。

#### 11.6.3 Looking Glass 页面 `/lg`（GET）

见第 12 章。这里只记录路由归属：`/lg` 的 GET/POST 都在 `app/web/lg.py`，不属于 `portal`。

#### 11.6.4 登录页 `/login`

```python
@router.get("/login", response_class=HTMLResponse)
def login_page(request: Request, db: Session = Depends(get_db)) -> HTMLResponse:
    challenge = create_challenge(db, purpose="web")
    return render(
        request,
        "login.html",
        {
            "return_url": f"{settings.base_url}/auth/kioubit/callback",
            "token": challenge.token,
        },
        user=current_user(request, db),
    )
```

模板只有 10 行：标题 `Authenticate` + 说明 `Use Kioubit.dn42 to prove control of your dn42 ASN, then you'll be signed in to the portal.` + 加载 `kioubit-auth-button.js` + `<kioubit-auth-btn return="{{ return_url }}" token="{{ token }}">`。

**关键点：没有 `next` 参数**。登录成功一律跳 `/portal`。`return_url` 是**绝对 URL**（`{settings.base_url}/auth/kioubit/callback`），因为 Kioubit 站要拿它做重定向目标。`settings.base_url` 必须与实际对外访问的 scheme/host 完全一致，否则 Kioubit 回调会指向错误地址（见 3.2）。

回调端点：

```python
@router.get("/auth/kioubit/callback")
def kioubit_callback(request: Request, params: str, signature: str,
                     db: Session = Depends(get_db)) -> RedirectResponse:
    verifier = KioubitVerifier(settings.kioubit_public_key_path, settings.auth_domain)
    try:
        data = verifier.verify(params=params, signature=signature)
        consume_challenge(db, data.get("user_token", ""), purpose="web")
        user = upsert_user_from_kioubit(db, data, settings)
    except (KioubitAuthError, ValueError) as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    login_user(request, user)
    return RedirectResponse("/portal", status_code=303)
```

要点：

1. **失败返回 400**（渲染 `error.html`），不重定向回登录页。这会把验签失败的原因直接显示给用户，包括“令牌过期”“域名不匹配”等。复刻时若不想暴露细节，可改成通用文案，但要保留日志。
2. **两个查询参数都是必填**：`params` 与 `signature`。缺失时 FastAPI 返回 422 而不是 400。
3. **挑战消费在 upsert 之前**。这保证同一个 `user_token` 不能被用两次（重放）。即使随后 upsert 失败，挑战也已作废——这是安全的失败方向。
4. **没有同源重定向风险**，因为没有 `next` 参数。如果复刻时新增 `next`，必须做同源白名单校验（只允许单个 `/` 开头）。

#### 11.6.5 Telegram 桥页 `/telegram/auth`

```python
@router.get("/telegram/auth", response_class=HTMLResponse)
def telegram_auth_page(request: Request, token: str,
                       db: Session = Depends(get_db)) -> HTMLResponse:
    return render(
        request, "telegram_auth.html",
        {
            "return_url": f"{settings.base_url}/telegram/auth?token={token}",
            "token": token,
        },
        user=current_user(request, db),
    )
```

这是一个给 Telegram Mini App 用的最小页面：读取 `Telegram.WebApp.initData`，POST 到 `/api/telegram/verify`，然后显示结果（成功 → 提示回 Bot；失败 → 显示错误）。详细逻辑见 10.3。

要点：

1. **`token` 是必填查询参数**，缺失时 FastAPI 返回 422。
2. **`return_url` 是带 token 的绝对 URL**，与登录页同理。
3. **该页不需要登录**。它是认证入口本身。
4. **页面不写入 session**——会话建立发生在 Bot 侧（`web_app_data` 处理后的后续 API 调用），浏览器侧只负责把 `initData` 交给后端验签。

#### 11.6.6 退出 `/logout`

```python
@router.get("/logout")
def logout(request: Request):
    logout_user(request)
    return RedirectResponse("/", status_code=303)
```

**必须**：登出只清 session，**不删除** `telegram_bindings`、`peer_requests`、`asn_identities`。Peer 归属于 User 而非会话，登出再登录（同一 ASN）后 Peer 仍在。这是与“Telegram Bot 里 /logout”一致的设计（见 8.x 的 `logout_cmd`）。

### 11.7 用户门户

#### 11.7.1 `/portal`（我的 Peer 列表）

```python
@router.get("/portal", response_class=HTMLResponse)
def portal(request: Request, db: Session = Depends(get_db)) -> HTMLResponse:
    user = current_user(request, db)
    if user is None:
        return RedirectResponse("/login", status_code=303)
    peers = peers_for_user_with_nodes(db, user.id)
    return render(
        request,
        "portal.html",
        {"peers": peers, "peer_count": len(peers)},
        user=user,
        active="portal",
    )
```

注意 `peers_for_user_with_nodes` 用 `joinedload(PeerRequest.node)` 预加载节点，避免模板里 `peer.node.name` 触发 N+1 查询。

模板（`portal.html`）：

- 页头：`page_header("My Peers", "Signed in as AS{primary_asn}. You have N peer{s}.")`；复数处理为 `"" if peer_count == 1 else "s"`。
- 右上：`+ New Peer` 按钮（`href="/portal/new"`）。
- 表格列：`Peer`（`{{ peer.id[:8] }}…` 链接到详情）、`Node`（`peer.node.name`）、`Enabled`（`status_badge(peer.status)`）、`Deploy`（`deploy_badge(peer.deploy_status)`）、空列放 `Manage →`。
- 空态：`You have no peers yet. <a href="/portal/new">Create your first peer →</a>`。

**必须**：查询必须用 `peers_for_user_with_nodes(db, user.id)`，内部过滤 `user_id`。详情/删除/config 路由则用 `owned_peer_with_node(db, user.id, peer_id)`，找不到返回 `None` → 路由抛 404（不是 403），避免泄漏“这个 UUID 存在但不属于你”。

**注意**：`Enabled` 列显示的是 `peer.status`（`approved`/`disabled`），不是 `peer.enabled`——`PeerRequest` 上没有 `enabled` 字段。`peer.status == "approved"` 才代表启用（见 11.7.5 的 `enabled` 布尔值）。

#### 11.7.2 `/portal/new`（新建表单）

```python
@router.get("/portal/new", response_class=HTMLResponse)
def portal_new(request: Request, db: Session = Depends(get_db)) -> HTMLResponse:
    user = current_user(request, db)
    if user is None:
        return RedirectResponse("/login", status_code=303)
    nodes = query_enabled_nodes(db).all()
    try:
        default_peer_address = derive_peer_link_address(user.primary_asn)
    except ValueError:
        default_peer_address = ""
    return render(
        request,
        "portal_new.html",
        {
            "nodes": nodes,
            "default_peer_address": default_peer_address,
            "default_wireguard_mtu": DEFAULT_WIREGUARD_MTU,
            "wireguard_mtu_min": MIN_WIREGUARD_MTU,
            "wireguard_mtu_max": MAX_WIREGUARD_MTU,
        },
        user=user,
        active="new",
    )
```

表单（`portal_new.html`，**POST 到 `/portal/peers/confirm`**）：

| 字段名 | 控件 | 必填 | 默认 | 说明 |
|--------|------|------|------|------|
| `node_id` | `<select>` 节点 | 是 | 第一个 | 只列 `enabled` 节点 |
| `wg_public_key` | text | 是 | 空 | placeholder `44-char base64 key` |
| `endpoint` | text | 否 | 空 | placeholder `host:port (blank = peer dials us)` |
| `peer_dn42_ipv4` | text | 三者至少一 | 空 | placeholder `172.20.x.y or 172.20.x.y/32` |
| `peer_dn42_ipv6` | text | 三者至少一 | 空 | placeholder `fd00::1 or fd00::1/128` |
| `peer_link_address` | text | 否 | `default_peer_address` | placeholder `fe80::99 or a ULA`；实际为空时后端自动派生 |
| `wg_mtu` | number | 是 | `1420` | `min=1280` `max=1500` |
| `bgp_extended` | checkbox | — | 勾选 | `value="1"` |

页面文案：

- 页头副标题：`Pick a node and paste your WireGuard details. You will confirm the settings before deployment.`
- 底部说明：`Enter at least one of DN42 IPv4, DN42 IPv6, or link-local. Blank fields are skipped. BGP extensions enable multiprotocol BGP and extended nexthop.`
- 无可用节点时：`No nodes are available right now. Please check back later.`（且整个表单不渲染，只显示这一句）。
- 提交按钮文案：`Review peer`（不是 `Create`——下一步是确认页）。

**必须**：`wg_mtu` 必须同时有 HTML 的 `min`/`max` 约束**和**服务端 `normalize_wireguard_mtu` 校验，因为 HTML 约束可被绕过。

**⚠️ 陷阱**：`peer_link_address` 在 HTML 里**不是** `required`，但最终数据库要求它非空。后端 `normalize_peer_input` 的兜底顺序是：用户给的 → `peer_dn42_ipv6` → ASN 派生的 link-local。所以留空不一定报错，但派生结果可能与用户预期不同（尤其当用户填了 ULA IPv6 时，会拿 ULA 当 BGP 邻居地址）。

#### 11.7.3 `POST /portal/peers/confirm`（预览）

```python
@router.post("/portal/peers/confirm", response_class=HTMLResponse, response_model=None)
def confirm_peer_request(
    request: Request,
    node_id: str = Form(...),
    wg_public_key: str = Form(...),
    endpoint: str = Form(""),
    peer_dn42_ipv4: str = Form(""),
    peer_dn42_ipv6: str = Form(""),
    peer_link_address: str = Form(""),
    wg_mtu: str | None = Form(None),
    bgp_extended: str | None = Form(None),
    db: Session = Depends(get_db),
) -> HTMLResponse | RedirectResponse:
    user = current_user(request, db)
    if user is None:
        return RedirectResponse("/login", status_code=303)
    node = enabled_node_by_id(db, node_id)
    if node is None:
        flash(request, "Unknown or disabled node.", "error")
        return RedirectResponse("/portal/new", status_code=303)
    try:
        preview = preview_peer(
            user=user, node=node, endpoint=endpoint, wg_public_key=wg_public_key,
            wg_mtu=wg_mtu, peer_dn42_ipv4=peer_dn42_ipv4, peer_dn42_ipv6=peer_dn42_ipv6,
            peer_link_address=peer_link_address, bgp_extended=bgp_extended,
            settings=settings,
        )
    except ValueError as exc:
        flash(request, str(exc), "error")
        return RedirectResponse("/portal/new", status_code=303)
    return render(
        request, "portal_confirm.html",
        {"node": node, "values": preview["values"], "peering": preview["peering"]},
        user=user, active="new",
    )
```

要点：

1. **字段用 `Form(...)` 逐个声明**，不是 `await request.form()`。这样 FastAPI 自动做类型与存在性校验，缺失 `node_id`/`wg_public_key` 直接 422。
2. **校验失败 303 回 `/portal/new` 并 flash**，而不是重新渲染表单。代价是用户输入丢失（因为没有回填机制）——原实现接受这个取舍。
3. **`preview_peer` 返回 dict**：`{"values": NormalizedPeerInput, "peering": {...}}`。`peering` 是 `peering_info(peer, node, local_asn)` 的结果，含我们这侧的 ASN/IPv4/IPv6/link-local/endpoint/公钥。
4. **`response_model=None` 必须写**。返回类型注解是 `HTMLResponse | RedirectResponse`，FastAPI 无法从中推导 response_model，不写会报错。

`portal_confirm.html`（已在上下文中，51 行）结构：

- 表单 POST 到 `/portal/peers`，8 个 hidden：`node_id`、`endpoint`、`wg_public_key`、`wg_mtu`、`peer_dn42_ipv4`、`peer_dn42_ipv6`、`peer_link_address`、`bgp_extended`（`1`/`0`）。
- 左栏 **Interface helper**：`ASN`（`"AS" ~ peering.asn if peering.asn != "<our-asn>"`）、`IPv4`、`IPv6`、`Link-local`、`Endpoint`、`WireGuard Public Key`，每项带 `copy_button`。
- 右栏 **Your submitted details**：`Node`（含 location）、`Endpoint`（空则 `- (you dial us)`）、`DN42 IPv4`、`DN42 IPv6`、`BGP neighbor address`、`WireGuard MTU`、`BGP extensions`（`enabled`/`disabled`）。
- 按钮：`Create peer`（submit）/ `Back`（`href="/portal/new"`）。
- 副标题：`Review the settings before this peer is deployed.`；左栏小字：`Use these settings to configure your interface.`

**必须**：确认页**不能落库**，也不能调用节点。它只做校验与渲染。

**⚠️ 陷阱**：确认页用 hidden 字段回传，用户可以改。因此 `POST /portal/peers` **必须重新完整校验**，不能信任 hidden 值。原实现确实重新走 `create_peer` 的完整 `normalize_peer_input`，这是正确做法。

#### 11.7.4 `POST /portal/peers`（创建）

```python
@router.post("/portal/peers")
def create_peer_request(
    request: Request,
    node_id: str = Form(...),
    wg_public_key: str = Form(...),
    endpoint: str = Form(""),
    peer_dn42_ipv4: str = Form(""),
    peer_dn42_ipv6: str = Form(""),
    peer_link_address: str = Form(""),
    wg_mtu: str | None = Form(None),
    bgp_extended: str | None = Form(None),
    db: Session = Depends(get_db),
) -> RedirectResponse:
    user = current_user(request, db)
    if user is None:
        return RedirectResponse("/login", status_code=303)
    node = enabled_node_by_id(db, node_id)
    if node is None:
        flash(request, "Unknown or disabled node.", "error")
        return RedirectResponse("/portal/new", status_code=303)
    try:
        create_peer(
            db, user=user, node=node, endpoint=endpoint, wg_public_key=wg_public_key,
            wg_mtu=wg_mtu, peer_dn42_ipv4=peer_dn42_ipv4, peer_dn42_ipv6=peer_dn42_ipv6,
            peer_link_address=peer_link_address, bgp_extended=bgp_extended,
            settings=settings,
        )
    except ValueError as exc:
        flash(request, str(exc), "error")
        return RedirectResponse("/portal/new", status_code=303)
    flash(request, "Peer created and deployment requested.", "success")
    return RedirectResponse("/portal", status_code=303)
```

**关键：这个路由是同步 `def`**。`create_peer` → `deploy_peer_request` → `deploy_peer` → `request_node_sync`，后者用 `anyio.from_thread.run` 把同步调用桥接到事件循环里的 WSS Future（见 6.x）。FastAPI 会把同步路由放进线程池执行，所以这段阻塞不会卡住事件循环。

**必须**：不要在同步路由里直接 `asyncio.run` 或 `await`。要么全程同步 + `request_node_sync`，要么改成 `async def` + `await NodeClient()`。原实现的两套路径（同步的 deploy/remove、异步的 LG/status）并存，复刻时不要混用。

**必须**：创建成功后重定向到 `/portal`，不是详情页。原实现如此。

#### 11.7.5 `GET /portal/peers/{peer_id}`（详情 + 实时状态）

```python
@router.get("/portal/peers/{peer_id}", response_class=HTMLResponse)
async def peer_detail(peer_id: str, request: Request,
                      db: Session = Depends(get_db)) -> HTMLResponse:
    user = current_user(request, db)
    if user is None:
        return RedirectResponse("/login", status_code=303)
    peer = owned_peer_with_node(db, user.id, peer_id)
    if peer is None:
        raise HTTPException(status_code=404, detail="Peer not found")
    node = peer.node
    wg_status = bgp_status = None
    status_error = None
    try:
        result = await NodeClient().peer_status(node, peer_protocol_name(peer, node))
        bgp_status = summarize_peer_bird(str(result.get("output", "")))
        wg_status = summarize_wireguard(str(result.get("wireguard", "")))
    except Exception as exc:  # noqa: BLE001 - a dead node renders a notice, never a 500
        status_error = f"Live status unavailable: {exc}"
    return render(
        request, "peer_detail.html",
        {
            "peer": peer, "node": node,
            "peering": peering_info(peer, node,
                                     node_effective_asn(node, settings.local_asn) or "<our-asn>"),
            "node_asn": node_effective_asn(node, settings.local_asn),
            "enabled": peer.status == "approved",
            "wg_status": wg_status, "bgp_status": bgp_status,
            "status_error": status_error,
        },
        user=user, active="portal",
    )
```

三个**必须**记牢的细节：

1. **这是唯一的 `async def` 门户路由**，因为要 `await NodeClient().peer_status`。
2. **`enabled` 是派生值**：`peer.status == "approved"`，不是库里的独立列。
3. **`result["output"]` 是 BIRD 的原始输出，`result["wireguard"]` 是 WireGuard 的原始输出**。节点返回的是 `{"ok":..., "output": <bird text>, "wireguard": <wg text>}`（见 5.3）。不要想当然地以为 `output` 里同时包含两者。

页面卡片（`peer_detail.html`）：

1. **Peer**：`UUID`（带复制）、`Enabled`（`bool_pill(enabled, "enabled", "disabled")`）、`Deployment`（`deploy_badge`）。
2. **Configure your side**：`ASN`、`IPv4`、`IPv6`、`Link-local`、`Endpoint`、`WireGuard public key`、`WireGuard MTU`；副标题 `Use these "our side" details in your own WireGuard + BGP config.`；底部 `View full config` → `/portal/peers/{id}/config`。
3. **Node**：`Name`、`ASN`（`node_asn`）、`DN42 IPv4`、`DN42 IPv6`、`Link-local (our side)`（=`peer.local_link_address`）。
4. **Live status**：失败时 `<pre class="terminal bad">{status_error}</pre>`；成功时两行 `WireGuard` / `BGP session` 摘要；底部 `Refresh` 链接回本页。
5. **Your submitted details**：`peer.endpoint`（空显示 `- (you dial us)`）、IPv4/IPv6、link-local、MTU、bgp_extended。
6. **Danger zone**：删除按钮，`data-confirm="Delete this peer? This tears down the tunnel and BGP session on the node."`。

**必须**：状态查询失败**不能**让整个页面 500。原实现捕获 `Exception`（比 `NodeRequestError` 更宽），因为 `NodeClient` 内部还可能抛 `RuntimeError`/`ValueError`。复刻时至少捕获 `NodeRequestError`，建议同样宽。

#### 11.7.6 `POST /portal/peers/{peer_id}/delete`

```python
@router.post("/portal/peers/{peer_id}/delete")
def portal_delete_peer(peer_id: str, request: Request,
                       db: Session = Depends(get_db)) -> RedirectResponse:
    user = current_user(request, db)
    if user is None:
        return RedirectResponse("/login", status_code=303)
    peer = owned_peer_with_node(db, user.id, peer_id)
    if peer is None:
        raise HTTPException(status_code=404, detail="Peer not found")
    delete_peer(db, peer=peer)
    flash(request, "Peer deleted and torn down.", "success")
    return RedirectResponse("/portal", status_code=303)
```

**重要差异**：门户删除走 `delete_peer`，它是**硬删除**——先把节点 teardown（`remove_peer`，best-effort，失败只记 warning），再 `db.delete(...)` 并 commit。**不是**标记 `deploy_status="removed"` 的软删除。

原实现里还有 `teardown_peer_request`（软语义：保留行、置 `deploy_status` 为 `removed` 或 `failed`），但它被 `update_peer(status="disabled")` 使用，**不**被门户删除使用。复刻时不要混淆这两条路径：

| 入口 | 函数 | 行是否保留 | `deploy_status` |
|------|------|-----------|-----------------|
| 门户删除 | `delete_peer` | 删除 | 不存在（行已删） |
| 管理员删除 | 同 `delete_peer` | 删除 | 同上 |
| 编辑为 disabled / Bot 删除 | `teardown_peer_request` | 保留 | `removed`（成功）/ `failed`（失败） |

`delete_peer` 的节点失败**不会**阻止删除，只记 warning。这是有意的：节点永久下线时用户仍能清理记录。

#### 11.7.7 `GET /portal/peers/{peer_id}/config`

```python
@router.get("/portal/peers/{peer_id}/config", response_class=HTMLResponse)
def peer_config(peer_id: str, request: Request,
                db: Session = Depends(get_db)) -> HTMLResponse:
    user = current_user(request, db)
    if user is None:
        return RedirectResponse("/login", status_code=303)
    peer = owned_peer_with_node(db, user.id, peer_id)
    if peer is None:
        raise HTTPException(status_code=404, detail="Peer not found")
    node = peer.node
    return render(
        request, "config.html",
        {
            "title": "Your peer config",
            "subtitle": f"Your generated WireGuard config for AS{peer.asn} on {node.name}.",
            "config": render_user_config(
                peer, node, node_effective_asn(node, settings.local_asn) or "<our-asn>"
            ),
            "back_url": f"/portal/peers/{peer.id}",
        },
        user=user, active="portal",
    )
```

**注意：不是 `text/plain`，是 HTML 页面**（`config.html`，用 `code_block` 展示配置全文 + 复制按钮 + 返回链接）。原实现没有下载端点。复刻时若想加下载，可另开一个 `?download=1` 分支，但不要改变默认行为。

**必须**：`render_user_config` 需要第三个参数 `our_asn`（我们的 ASN），且必须映射 `"<our-asn>"` 占位符（节点未配置 ASN 时）。

### 11.8 管理后台

所有 `/admin/*` 路由都以 `user: User = Depends(require_admin)` 或 `_admin: User = Depends(require_admin)` 声明鉴权。POST 路由统一 **303 重定向 + flash**，不用 JSON 错误。

#### 11.8.1 `/admin`（总览）

`admin_overview` 用一个局部 `count(model, *filters)` 函数做 9 组聚合：

```python
def count(model, *filters) -> int:
    query = db.query(func.count(model.id))
    for f in filters:
        query = query.filter(f)
    return query.scalar() or 0

stats = {
    "nodes_total": count(Node),
    "nodes_enabled": count(Node, Node.enabled.is_(True)),
    "nodes_online": nodes_online,        # 来自 node_runtime_context，不是 SQL
    "peers_total": count(PeerRequest),
    "peers_deployed": count(PeerRequest, PeerRequest.deploy_status == "deployed"),
    "peers_failed": count(PeerRequest, PeerRequest.deploy_status == "failed"),
    "users_total": count(User),
    "users_admin": count(User, User.is_admin.is_(True)),
    "lg_total": count(LGQuery),
}
```

另有三块列表（都带 `joinedload`，限制条数）：

| 列表 | 条数 | 排序 | 用途 |
|------|------|------|------|
| `failed_peers` | 10 | `updated_at desc` | 最近部署失败，需人工介入 |
| `recent_peers` | 6 | `created_at desc` | 最近创建的 Peer |
| `recent_queries` | 8 | `created_at desc` | 最近 LG 查询 |

**必须**：`nodes_online` 来自内存态 `node_runtime_context(nodes_for_runtime)`，其余来自 SQL。不要把在线数写进数据库。

#### 11.8.2 `/admin/nodes` 与节点编辑

列表页 `admin_nodes`：全量 `Node` 按 `name` 排序 + `node_runtime`。模板 `admin/nodes.html` 的列：`Name`、`Location`、`ASN`、`Online`、`Enabled`、`Public key`、`Actions`（Edit / Refresh key / Reset token / Delete）。

编辑页 `admin_node_edit`：`node` + `runtime = node_runtime_context([node])[node.id]`。

节点表单字段（**注意字段名是 `url`，不是 `endpoint`**）：

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `name` | text | 是 | 唯一；必须与节点 `config.json` 的 `name` 完全一致 |
| `location` | text | 否 | 人类可读 |
| `url` | text | 是 | 后端基址，经 `normalize_node_host` 归一 |
| `asn` | text | 否 | 节点 ASN，经 `normalize_asn_number` |
| `dn42_ipv4` / `dn42_ipv6` | text | 否 | 经 `normalize_optional_ip` |
| `enabled` | checkbox | 否 | `enabled == "on"` |

`_clean_node_fields` 的实际签名是**三个字符串**，返回三元组：

```python
def _clean_node_fields(asn: str, dn42_ipv4: str, dn42_ipv6: str) -> tuple[str, str, str]:
    asn = asn.strip()
    if asn:
        asn = normalize_asn_number(asn)
    return (
        asn,
        normalize_optional_ip(dn42_ipv4, version=4),
        normalize_optional_ip(dn42_ipv6, version=6),
    )
```

**必须**：`wg_public_key` **不在**任何节点表单里。它的写入只有两条路径：

1. `POST /admin/nodes`（创建）只生成 `token = secrets.token_urlsafe(32)`，**公钥留空**，靠后续 refresh 填。
2. `POST /admin/nodes/{id}/update` 会在保存后自动 `fetch_node_public_key(node)`；拉取成功才覆盖，失败保留旧值。

```python
# admin_update_node 的关键片段
fetched = fetch_node_public_key(node)
if fetched is not None:
    node.wg_public_key = fetched
db.commit()
```

`fetch_node_public_key` 内部捕获 `NodeRequestError`/`RuntimeError`/`ValueError` 并返回 `None`，所以节点离线时保存仍然成功。

**⚠️ 陷阱**：更新节点 `url` 后会自动重新拉公钥。如果管理员把 URL 改错但节点仍连着旧地址，`fetch_node_public_key` 会因为新 URL 不可达而返回 `None`，旧公钥被保留——表面上看“保存成功”，实际上新 URL 是错的。复刻时可考虑在 URL 变更时给更强的警告。

#### 11.8.3 节点运维动作

| 动作 | 端点 | 实际行为 |
|------|------|----------|
| Create | `POST /admin/nodes` | 校验 name 非空、`url` 归一、`_clean_node_fields`；重名 flash `A node named '{name}' already exists.`；创建时生成随机 token，`enabled` 由复选框决定；flash `Node '{name}' created.` |
| Update | `POST /admin/nodes/{id}/update` | 同上 + 排除自身重名检查 + 自动拉公钥；flash `Node '{name}' saved.` |
| Refresh pubkey | `POST /admin/nodes/{id}/refresh-pubkey` | `fetch_node_public_key`；失败时 flash 一大段排查提示（WSS 连通性 / name+token / 节点配置里的 `wireguard_public_key`）；成功 flash `Refreshed WireGuard public key for '{node.name}'.` |
| Reset token | `POST /admin/nodes/{id}/reset-token` | `node.token = secrets.token_urlsafe(32)`，flash `Issued a new API token for '{node.name}'.`。**token 不会显示在页面上**，管理员需要自己去库里读或看日志 |
| Delete | `POST /admin/nodes/{id}/delete` | 若存在 `PeerRequest.node_id == node.id`，flash `Delete or move this node's peers before deleting it.`；否则删除并 flash `Deleted node '{name}'.` |

**⚠️ 重要**：reset-token 的 flash **不含新 token**。原实现只提示“已签发”。这意味着：如果你不是直接查库，就无法拿到新 token 配到节点上。复刻时建议改进（例如把 token 渲染到编辑页一次），但要意识到这是一个**已知的可用性缺口**，不是文档遗漏。

**⚠️ 陷阱**：节点删除后 `peer_requests.node_id` 会变成悬空值（SQLite 默认不强制外键）。原实现靠“有 Peer 就拒绝删除”规避。复刻时若启用 `PRAGMA foreign_keys=ON`，需要对应 `ON DELETE RESTRICT`。

#### 11.8.4 `/admin/peers` 与 Peer 管理

列表页 `admin_peers`：`page: int = 1` 作为查询参数，`Pagination(page, 50, total)`，`joinedload(PeerRequest.node)`，按 `created_at desc`。额外上下文：`nodes`（全部节点，含 disabled）、`default_local_link_address`（`asn_link_local_address(settings.local_asn)`，失败则空串）、MTU 三常量。

模板 `admin/peers.html` 含“新建 Peer”表单（管理员直接建）。列：`Peer`、`ASN`、`Node`、`Protocol`、`Status`、`Deploy`、`Actions`。

**`POST /admin/peers`（管理员建 Peer）**：

```python
@router.post("/admin/peers")
def admin_create_peer(
    request: Request,
    asn: str = Form(...),
    node_id: str = Form(...),
    endpoint: str = Form(""),
    wg_public_key: str = Form(...),
    wg_mtu: str | None = Form(None),
    local_link_address: str = Form(...),      # 注意：必填
    peer_link_address: str = Form(""),
    peer_dn42_ipv4: str = Form(""),
    peer_dn42_ipv6: str = Form(""),
    bgp_extended: str | None = Form(None),
    db: Session = Depends(get_db),
    _admin: User = Depends(require_admin),
) -> RedirectResponse:
    asn_number = normalize_asn_number(asn)
    node = db.query(Node).filter(Node.id == node_id).one_or_none()
    ...
    peer_user = db.query(User).filter(User.primary_asn == asn_number).one_or_none()
    if peer_user is None:
        try:
            is_admin = asn_number == normalize_asn_number(settings.local_asn)
        except ValueError:
            is_admin = False
        peer_user = User(primary_asn=asn_number, is_admin=is_admin)
        db.add(peer_user)
        db.flush()
        db.add(ASNIdentity(user_id=peer_user.id, asn=asn_number, authtype="admin-manual"))
    peer = create_peer(db, user=peer_user, node=node, ..., settings=settings)
    if peer.deploy_status == "deployed":
        flash(request, f"Peer for AS{asn_number} on {node.name} created and deployed.", "success")
    else:
        flash(request, f"Peer for AS{asn_number} created, deploy failed: {peer.deploy_output[:200]}", "error")
```

要点：

1. **`local_link_address` 在管理员表单里是必填**（`Form(...)`），与用户门户不同（门户留空会自动派生）。管理员必须显式给出我们这侧的 BGP 地址。
2. **自动建 User**：为尚未登录过的 ASN 建 Peer 时创建 `User` + `ASNIdentity(authtype="admin-manual")`。`is_admin` 复用同一规则（等于 `LOCAL_ASN`）。
3. **`db.flush()` 后才拿得到 `peer_user.id`**，然后才能写 `ASNIdentity`。不要先 commit 再写 identity（会多一次事务）。
4. **`node` 查询不过滤 `enabled`**。管理员可以往 disabled 节点建 Peer，但 `deploy_peer` 会因 `node.enabled == False` 抛 `PeerDeployError("Node is disabled")`，最终 `deploy_status="failed"`。
5. **重复检查用 `find_peer_on_node(db, node.id, asn_number)`**：同一 (node, asn) 只允许一个 Peer。
6. **部署失败不是 500**，而是 flash 里带 `deploy_output[:200]`。

**`POST /admin/peers/{id}/update`**：

```python
peer = update_peer(
    db, peer=peer, node=node, endpoint=endpoint, wg_public_key=wg_public_key,
    wg_mtu=wg_mtu, local_link_address=local_link_address,
    peer_link_address=peer_link_address, peer_dn42_ipv4=peer_dn42_ipv4,
    peer_dn42_ipv6=peer_dn42_ipv6, bgp_extended=bgp_extended,
    status=status, settings=settings, redeploy=False,
)
flash(request, "Peer saved.", "success")
```

- **`redeploy=False`**：只改库，不下发节点。
- **`status` 来自表单，默认 `approved`**，`update_peer` 只接受 `approved` / `disabled`，其他抛 `Unsupported peer status`。
- **`status="disabled"` 会触发 `teardown_peer_request`**（软拆除，保留行，`deploy_status="removed"`）。
- **节点变更会自动清理旧节点**（`update_peer` 内部的 `moved_from` 快照 + `_teardown_orphan_on_old_node`），best-effort。

**`POST /admin/peers/{id}/redeploy`**：

```python
if peer.status != "approved":
    flash(request, "Only approved peers can be deployed.", "error")
    return RedirectResponse(edit_url, status_code=303)
peer = deploy_peer_request(db, peer, settings)
if peer.deploy_status == "deployed":
    flash(request, "Peer redeployed.", "success")
else:
    flash(request, f"Peer deploy failed: {peer.deploy_output[:200]}", "error")
```

**必须**：只对 `approved` 开放。注意文案是 `Only approved peers can be deployed.`（不是 “redeployed”）。

**`POST /admin/peers/{id}/delete`**：与门户同函数 `delete_peer`（硬删除），flash `Deleted peer.`，重定向 `/admin/peers`。

**`GET /admin/peers/{id}/config`**：渲染 `config.html`，内容来自 **`render_operator_config(peer, peer.node, settings.local_asn or "<our-asn>")`**——注意是 **operator** 版（含我们这侧运维视角的完整片段），不是门户的 `render_user_config`。标题 `Operator config for AS{asn}`，副标题含节点名，返回链接指向编辑页。

**`GET /admin/peers/{id}/status`**：`async def`，`await NodeClient().peer_status(node, peer_protocol_name(peer, node))`，渲染 `admin/peer_status.html`，展示**完整未裁剪**的 BIRD 与 WireGuard 输出（`bird` / `wg` 两个字段），失败时 `error` 为 `Could not fetch live status from {node.name}: {exc}`。这是与门户“摘要视图”的关键差异。

#### 11.8.5 `/admin/users`

`admin_users` 用 `selectinload(User.telegram_bindings)` 预加载绑定，并用一条 `group_by` 查询拿到所有 Peer 计数：

```python
peer_counts = dict(
    db.query(PeerRequest.user_id, func.count(PeerRequest.id))
    .group_by(PeerRequest.user_id)
    .all()
)
```

模板列：`ASN`、`Admin`（badge）、`Peers`（`peer_counts.get(user.id, 0)`）、`Telegram`（绑定 UID 列表或 `-`）、`Last login`、`Actions`。**不分页**。

| 动作 | 端点 | 行为 |
|------|------|------|
| Toggle admin | `POST /admin/users/{user_id}/toggle-admin` | `user_id: int`；若 `user_id == admin.id` → flash `You can't change your own admin status.`；否则翻转 `is_admin`，flash `AS{asn} is now an admin.` / `... a regular user.` |
| Unlink Telegram | `POST /admin/users/{user_id}/unlink-telegram` | 查询该用户的全部 `TelegramBinding`；没有则 flash `That user has no linked Telegram account.`（info）；有则逐个 `unbind_telegram(db, binding.telegram_user_id)`，flash `Unlinked Telegram from AS{asn}.` |

**必须**：防自锁检查必须**在查询目标用户之前**也可以用 `admin.id` 比较，但原始顺序是先比较 `user_id == admin.id` 再查；这样即使目标用户不存在也会先报“不能改自己”（当 id 恰好等于自己时）。复刻时保持这个顺序，避免行为差异。

**⚠️ 陷阱**：`user_id` 是 `int` 路径参数，非数字会 422。`toggle-admin` 的提升会被下次登录的 `is_admin = (asn == local_asn)` 覆盖（见 11.6.1 第 3 点）。

#### 11.8.6 `/admin/lg-log`（LG 审计）

`admin_lg_log`：`page: int = 1`，`Pagination(page, 50, total)`，`joinedload(LGQuery.node)` + `joinedload(LGQuery.user)`，`created_at desc`。

列：`Time`、`User`（`query.user.primary_asn` 或 `anonymous`）、`Node`、`Type`、`Target`、`OK`、`Client IP`。

**注意**：`LGQuery` 表**没有** `client_ip` 列（见 4.2）——所以审计页面实际上无法显示来源 IP。原实现的 `client_ip` 只用于限流键。复刻时若需要 IP 审计，需要加列。

**必须**：`result` 字段可能很长，列表页不要渲染全文；只显示 `ok` 状态。原实现也没有详情页。

### 11.9 模板宏与前端脚本

#### 11.9.1 `macros.html`

| 宏 | 签名 | 输出与映射 |
|----|------|-------------|
| `badge` | `(text, tone="neutral")` | `<span class="badge badge-{tone}">{text}</span>` |
| `status_badge` | `(status)` | `approved`→`ok`、`disabled`→`bad`、`pending`→`warn`、其余`neutral` |
| `deploy_badge` | `(deploy_status)` | `deployed`→`ok`、`failed`→`bad`、`deploying`→`warn`、其余`neutral`；文本先 `replace("_", " ")`（所以 `not_deployed` 显示为 `not deployed`） |
| `bool_pill` | `(value, on="yes", off="no")` | 真→`badge(on,"ok")`，假→`badge(off,"neutral")` |
| `stat_card` | `(label, value, sub=None, tone="neutral", href=None)` | 有 `href` 渲染 `<a>`，否则 `<div>` |
| `page_header` | `(title, subtitle=None)` | `<div class="page-header"><h1>..</h1>` + 可选 `<p class="muted">` |
| `code_block` | `(content, ok=None)` | `<div class="codewrap">` + Copy 按钮（`data-copy-target=".codewrap pre"`）+ `<pre class="terminal{% if ok is true %} ok{% elif ok is false %} bad{% endif %}">{{ content }}</pre>` |
| `copy_button` | `(text, label="Copy")` | `<button type="button" class="copy-btn copy-inline" data-copy="{{ text }}">` |
| `pagination` | `(pg, base_path)` | `pg.pages > 1` 时渲染 `← Prev` / `Page X of Y · N total` / `Next →` |

**必须**：`code_block` 的 `{{ content }}` 依赖 Jinja2 自动转义。不要 `|safe`。LG 输出是任意命令回显，`|safe` 就是存储型 XSS。

**注意**：`deploy_badge` 的默认分支是 `neutral`，所以 `not_deployed`、`removed` 都显示为灰色。不要假设存在 `none` 这个值——模型默认是 `not_deployed`。

**注意**：`copy_button` 只认 `data-copy`；`code_block` 的按钮用的是 `data-copy-target` 加 `closest(".codewrap")` 找 `<pre>`。两套机制在 `app.js` 里由同一个 click 监听器处理。

#### 11.9.2 `app.js` 渐进增强项

| 功能 | 触发 | 行为 |
|------|------|------|
| 复制（字面值） | `.copy-btn[data-copy]` 点击 | `writeClipboard(text)`；成功按钮文案 1.4s 变 `Copied!`，失败变 `Press Ctrl+C` |
| 复制（配置块） | `.codewrap .copy-btn`（无 `data-copy`） | 取同 `.codewrap` 内 `<pre>` 的 `innerText` |
| 非安全上下文兜底 | 无 `navigator.clipboard` 或非 `isSecureContext` | 建临时 `<textarea>` + `document.execCommand("copy")` |
| 破坏性确认 | form submit 时取 `e.submitter[data-confirm]` 或 `form[data-confirm]` | `confirm(msg)`，取消则 `preventDefault()` |
| LG 异步查询 | `#lg-form` submit | `fetch("/lg", {method:"POST", body:new FormData(form), headers:{"X-Requested-With":"fetch","Accept":"application/json"}})`；按钮禁用并显示 `Running…`；返回 JSON 后渲染 `#lg-result` |
| LG 结果渲染 | JSON `{ok, output}` | 重建 `.codewrap` + `Copy` + `<pre class="terminal ok|bad">`；`output` 为空显示 `(no output)` |
| ASN → link-local | `#admin-peer-asn` 的 `input`/`change` + 初始化 | `peerLinkLocalFromAsn` 计算 `fe80::<suffix>`；仅当目标为空或等于上次自动填值时覆盖，并记 `dataset.autofilledValue` |
| flash 关闭 | `.flash-close` 点击 | 淡出 300ms 后 `remove()` |
| flash 自动消失 | `.flash:not(.flash-error)` | 6s 后淡出移除（**error 类不自动消失**） |

`peerLinkLocalFromAsn(value)` 的实现与后端 `normalize_dn42_asn_suffix` 必须保持一致：

```javascript
function peerLinkLocalFromAsn(value) {
  var asn = (value || "").trim().toUpperCase();
  if (asn.indexOf("AS") === 0) asn = asn.slice(2);
  if (!/^\d+$/.test(asn)) return "";
  var suffix;
  if (asn.length < 4) {
    suffix = asn;
  } else if (asn.indexOf("424242") === 0) {
    suffix = asn.slice(6);
  } else {
    suffix = asn.slice(-4);
  }
  suffix = suffix.replace(/^0+/, "") || "0";
  return "fe80::" + suffix.toLowerCase();
}
```

**必须**：LG 的 `fetch` 分支必须带 `X-Requested-With: fetch`，服务端靠它切 JSON（见 12.2）。不带头就返回整页 HTML，`.json()` 会失败并回落成 `Unexpected response (HTTP 200)`。

**必须**：ASN 自动填充的 `dataset.autofilledValue` 规则必须保留。没有它，用户手动改过的地址会在每次输入 ASN 时被覆盖。

**注意**：flash 自动消失只对非 error 生效。错误提示必须由用户手动关闭，避免错过。

#### 11.9.3 `kioubit-auth-button.js`

Web Component（`customElements.define('kioubit-auth-btn', ...)`），`attachShadow({mode:'closed'})`，内部渲染：

```html
<form action="https://dn42.g-load.eu/auth/">
  <input type="hidden" name="return" value="...">
  <input type="hidden" name="token" value="...">
  <button type="submit">Authenticate with Kioubit.dn42</button>
</form>
```

要点：

1. **表单没有 `method`，默认是 GET**。提交后浏览器跳到 `https://dn42.g-load.eu/auth/?return=<url>&token=<token>`。这与“POST”直觉不同，复刻时不要加 `method="post"`。
2. **`action` 是硬编码的** `https://dn42.g-load.eu/auth/`。复刻到自建 Kioubit 实例时必须改这里，否则登录必然失败。
3. **`observedAttributes = ['return', 'token']`**，属性变化时直接改 hidden input 的 `value`。`connectedCallback` 首次渲染。
4. **`getReturnUrl()` 的相对/绝对规则**：空 → `origin + pathname`；以 `http://`/`https://` 开头 → 原样；以 `/` 开头 → `origin + attr`；其他 → `origin + pathname + attr`。由于服务端传入的是绝对 URL（`settings.base_url + /auth/kioubit/callback`），走的是第二条。
5. **按钮文案与 logo**：`Authenticate with Kioubit.dn42` + 内联 base64 SVG 图标。`part="button"` 允许外部用 `::part(button)` 定制样式。

**⚠️ 陷阱**：`#render()` 用模板字符串把 `token` / `return` 直接插进 HTML 属性，没有转义。服务端的 token 是 `secrets.token_urlsafe(32)`（只含 URL 安全字符），所以安全；但如果复刻时把用户输入传进 `token` 属性，就是 DOM XSS。

### 11.10 实现陷阱（Web UI）

1. **`render()` 的 `flashes` 是 `pop` 语义**。任何绕过 `render()` 直接 `TemplateResponse` 的地方都不会清空 flash，导致它在下个页面重复出现。复刻时必须统一走 `render()`。
2. **`/portal/*` 的未登录处理是 303 到 `/login`**，而 `/admin/*` 是 403。两套策略混用是有意的（门户对匿名者友好，后台不暴露）。改一处要同步改测试。
3. **原实现没有 `next` / 回跳参数**。登录成功一律 303 到 `/portal`。若复刻时新增回跳，必须做同源白名单校验（只允许单个 `/` 开头，拒绝 `//`、`http://`、`\`）。
4. **确认页 hidden 字段可篡改**。`POST /portal/peers` 必须完整重校验（走 `create_peer` 内部的 `normalize_peer_input`），不要复用“预览时算好的结果”。
5. **`owned_peer_with_node` 返回 `None` → 路由抛 404 而非 403**。这是为了避免 UUID 枚举泄漏。复刻时保持一致。
6. **节点离线时详情页不能 500**。`peer_status` 必须包在 `try/except` 里（原实现捕获宽泛的 `Exception`）。
7. **门户删除是硬删除**（`delete_peer`），不是软删除。软语义只在 `update_peer(status="disabled")` 路径上。别把两者混在一起。
8. **`session` Cookie 是明文**。Starlette 的 `SessionMiddleware` 只签名不加密，`itsdangerous` 签名可被解码。不要把 secret、token、密码放进 session。
9. **`admin_delete_node` 的“有 Peer 就拒绝”是唯一的外键保护**。若复刻时启用了外键约束，必须同步加 `ON DELETE RESTRICT`。
10. **`toggle-admin` 必须防自锁**，且手工授予会被下次登录覆盖（见 11.6.1 第 3 点）。
11. **`/admin/peers/{id}/redeploy` 只对 `approved` 开放**。对 `disabled`/`removed` 重部署会造成节点/库不一致。
12. **`wg_public_key` 只在“拉取节点公钥”的场景写入**。不要在节点编辑表单里暴露它（见 11.8.2）。
13. **`client_ip` 只在可信反代后配置 `FORWARDED_IP_HEADER`**，且反代必须覆盖而非追加该头。
14. **LG 的 `X-Requested-With` 是唯一的分支键**。改名前端与服务端要同步。
15. **模板里不要用 `|safe`**。唯一例外是 `code_block` 的内部实现，且它自己会转义。
16. **同步路由与异步路由不能混用同一套节点调用**。deploy/remove 走 `request_node_sync`（同步），LG/status 走 `await NodeClient()`（异步）。在同步路由里 `await` 会直接报错。
17. **`render()` 的 `user` 参数不会自动填充**。忘记传 `user=current_user(request, db)` 时，模板里 `user` 为 `None`，导航栏会显示“Login”，即使会话有效。

---

## §12 Looking Glass（公开查询）

Looking Glass 是本仓库唯一**面向匿名用户**的功能面：任何人打开 `/lg` 都能对任意节点发起 ping / traceroute / mtr / route 查询。因此这一章的重点不是"功能怎么做"，而是"**在允许任意目标的前提下，如何不被滥用、不被当成跳板、不把路由器打挂**"。

原实现把防护拆成四层，缺任何一层都会出问题：

| 层 | 位置 | 防什么 | 失效后果 |
|---|---|---|---|
| 输入校验 | `app/lg/validation.py`（后端） | 命令注入、参数走私、非法查询类型 | 目标字符串进入固定 argv 或绕过类型白名单 |
| 目标校验 | `internal/runner/runner.go`（节点） | 纵深防御：即使后端被绕过也拒绝危险目标 | 节点侧成为命令注入的最后一道口子 |
| 限流 | `app/lg/ratelimit.py` + `POST /lg` | 单 IP 高频刷查询 | 路由器 CPU / 带宽被打满，BGP 抖动 |
| 并发上限 | `internal/api/server.go` 信号量 | 多 IP 同时打同一节点 | 子进程堆积、`birdc` 争锁、OOM |

另外还有一层**隐含**防护：节点侧 `Runner.Timeout`（默认 10s）+ 命令自身参数（`ping -c 4`、`mtr --report-cycles 4`、`traceroute -m 20`）保证单次查询有界。这四个参数决定了"一次查询最多消耗多少"，详见 12.6。

### 12.1 查询类型与目标校验

#### 12.1.1 白名单常量

```python
# app/lg/validation.py
ALLOWED_QUERY_TYPES = {"ping", "trace", "mtr", "route"}

# DELIBERATE: the looking glass accepts ANY IPv4/IPv6 target, not just dn42 space. This is an
# intentional product choice — do NOT narrow it back to dn42 ranges. Abuse of the public LG is
# bounded by the per-IP rate limit (LG_RATE_LIMIT) and the node service concurrency cap, not by target.
ALLOWED_NETWORKS = (
    ipaddress.ip_network("0.0.0.0/0"),
    ipaddress.ip_network("::/0"),
)

UNSAFE_TARGET_RE = re.compile(r"""[\s;&|`$<>\\\"'(){}\[\]!*?]""")

HOSTNAME_RE = re.compile(
    r"^(?=.{1,253}$)"
    r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?"
    r"(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$"
)
```

**必须注意**：`ALLOWED_NETWORKS` 的源码注释明确写了 "do NOT narrow it back to dn42 ranges"。这不是疏忽，而是产品决策——LG 的用途包括"从我们的路由器看公网到某个目标的路径"，限制成 dn42 会砍掉一半价值。滥用由**限流 + 并发**约束，不由目标范围约束。

复刻时若出于合规要求必须收窄，**必须在文档/配置里显式声明这是偏离原实现的定制**，不要偷偷改 `ALLOWED_NETWORKS` 而保留注释，否则后续维护者会以为可以放开。

#### 12.1.2 `validate_query_type`

```python
def validate_query_type(query_type: str) -> str:
    query_type = query_type.strip().lower()
    if query_type not in ALLOWED_QUERY_TYPES:
        raise ValueError("unsupported looking glass query")
    return query_type
```

三个细节：

1. **`strip().lower()`** —— 用户可能传 `Ping`、` ping `。归一化后再比对，避免大小写/空白绕过。
2. **返回归一化值而非原值** —— 调用方必须用返回值（`POST /lg` 里 `normalized_query_type`），否则 `lg.Ping` 这种值会拼出错误的 WSS 命令名。
3. **异常类型是 `ValueError`** —— 不是自定义异常。路由层用 `except ValueError` 统一捕获，把消息直接展示给用户。这意味着**错误文案就是用户可见文案**，任何新增校验都必须写英文、面向用户、不泄漏内部细节。

#### 12.1.3 `validate_target` 完整实现

```python
def _is_allowed_address(address: ipaddress.IPv4Address | ipaddress.IPv6Address) -> bool:
    return any(address in network for network in ALLOWED_NETWORKS)


def _is_allowed_network(target: ipaddress.IPv4Network | ipaddress.IPv6Network) -> bool:
    # subnet_of() raises across IP versions, so only compare same-version networks.
    return any(
        target.version == network.version and target.subnet_of(network)
        for network in ALLOWED_NETWORKS
    )


def validate_target(query_type: str, target: str) -> str:
    query_type = validate_query_type(query_type)
    target = target.strip()

    if not target or len(target) > 255:
        raise ValueError("invalid target length")
    if target.startswith("-") or UNSAFE_TARGET_RE.search(target):
        raise ValueError("target contains unsupported characters")

    if query_type == "route":
        try:
            network = ipaddress.ip_network(target, strict=False)
        except ValueError as exc:
            raise ValueError("route target must be an IP address or CIDR prefix") from exc
        if not _is_allowed_network(network):
            raise ValueError("target is outside the allowed address space")
        return target

    try:
        address = ipaddress.ip_address(target)
    except ValueError as exc:
        # Not an IP — accept a valid hostname (ping/traceroute resolve it on the node service).
        if HOSTNAME_RE.match(target):
            return target
        raise ValueError("target must be a valid IP address or hostname") from exc
    if not _is_allowed_address(address):
        raise ValueError("target is outside the allowed address space")
    return target
```

**校验顺序是有意义的，不能重排**：

| 步骤 | 检查 | 拒绝原因 | 为什么在这个位置 |
|---|---|---|---|
| 1 | 再调一次 `validate_query_type` | `unsupported looking glass query` | `validate_target` 可被单独调用（`NodeClient.query` 就这么做），必须自带类型校验 |
| 2 | `strip()` | — | 先去掉首尾空白，否则 `" -n"` 的前导空格会让第 4 步的 `startswith("-")` 失效 |
| 3 | 空 / 长度 > 255 | `invalid target length` | 长度限制在字符集检查之前，避免对超长串做正则 |
| 4 | 前导 `-` 或 `UNSAFE_TARGET_RE` | `target contains unsupported characters` | **必须在类型分支之前**：`route` 分支也会走 `ip_network()`，若不先拒绝，`-1.0.0.0/8` 这类串在某些解析器上会有意外行为 |
| 5 | `route` → `ip_network(strict=False)` + `_is_allowed_network` | 两种文案见下 | `strict=False` 允许 `1.1.1.1/24`（主机位非零）被解释成 `1.1.1.0/24`，对"我想到达这个地址"的语义是正确的 |
| 6 | 非 route → `ip_address()` | — | 先试 IP |
| 7 | IP 失败 → `HOSTNAME_RE` | `target must be a valid IP address or hostname` | 只有 ping/trace/mtr 接受主机名 |
| 8 | IP 成功 → `_is_allowed_address` | `target is outside the allowed address space` | 当前 `0.0.0.0/0` + `::/0` 恒真，但保留这层是为了将来收窄时不用改结构 |

#### 12.1.4 `UNSAFE_TARGET_RE` 的字符集

```python
re.compile(r"""[\s;&|`$<>\\\"'(){}\[\]!*?]""")
```

逐类拆解：

| 字符 | 拦截目的 |
|---|---|
| `\s` | 空白（空格、Tab、换行）——防止 `"1.1.1.1 -c 100000"` 这种把额外参数塞进单个"目标" |
| `;` `&` `\|` | shell 命令分隔 / 管道 |
| `` ` `` `$` | 命令替换、变量展开 |
| `<` `>` | 重定向 |
| `\\` `"` `'` | 引号与转义，用于构造畸形 argv |
| `()` `{}` `[]` | 子 shell、brace expansion、glob 字符集 |
| `!` `*` `?` | 历史展开、glob |

注意这里**用的是 Python `re` 的字符类**，`\[` `\]` 需要转义，源码里写的就是 `{}\[\]`。复刻时若用别的语言重写，务必逐字符核对——少转义一个 `]` 会导致字符类提前闭合，整个正则退化。

#### 12.1.5 `HOSTNAME_RE` 的语义

```python
r"^(?=.{1,253}$)"
r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?"
r"(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$"
```

| 组成 | 含义 |
|---|---|
| `(?=.{1,253}$)` | 总长 1–253（DNS 线格式上限 255，减去长度字节） |
| `[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?` | 单个 RFC-1123 标签：1–63 字符，首尾不得为 `-` |
| `(?:\.....)+` | **至少一个点**——`localhost` 被拒绝，只允许 FQDN 形态 |

**为什么至少一个点**：允许 `localhost` 会让 LG 变成"探测本机服务"的工具（`ping localhost`、`trace 127.0.0.1` 虽然 IP 分支也能过，但主机名形态更容易被用来做 SSRF 式的探测语义）。要求带点是一个弱约束，主要作用是减少误用。

**为什么主机名不会扩大攻击面**：源码注释已说明——IP 分支本来就允许任意地址，主机名只是让 `ping`/`traceroute` 在**节点侧**自行解析，解析结果必然落在同一个"任意地址"空间里。所以这不是放宽，是把"用户自己解析"变成"节点帮忙解析"。

**`route` 不接受主机名**：BIRD 的 `show route for` 不做 DNS 解析。源码注释明确："route stays IP/prefix only — BIRD does not resolve names"。

#### 12.1.6 节点侧的独立实现

`internal/runner/runner.go` 有**一套平行的校验**，不依赖后端：

```go
var (
	allowedIPv4Net = parseCIDR("0.0.0.0/0")
	allowedIPv6Net = parseCIDR("::/0")
	safeNameRE     = regexp.MustCompile(`^[A-Za-z0-9_][A-Za-z0-9_-]{0,79}$`)
	hostnameRE     = regexp.MustCompile(`^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$`)
	wgKeyRE        = regexp.MustCompile(`^[A-Za-z0-9+/]{43}=$`)
)

func ValidateHostTarget(target string) error {
	target = strings.TrimSpace(target)
	if target == "" || len(target) > 255 {
		return errors.New("invalid target length")
	}
	if hasUnsafeTargetChar(target) {
		return errors.New("target contains unsupported characters")
	}
	if ip := net.ParseIP(target); ip != nil {
		if isAllowedIP(ip) {
			return nil
		}
		return errors.New("target is outside the allowed address space")
	}
	if len(target) <= 253 && hostnameRE.MatchString(target) {
		return nil
	}
	return errors.New("target must be a valid IP address or hostname")
}
```

`hasUnsafeTargetChar` 逐字符检查（`ch < 33 || ch > 126` 拒绝控制符与非 ASCII，再查 shell 元字符集）：

```go
func hasUnsafeTargetChar(target string) bool {
	if strings.HasPrefix(target, "-") {
		return true
	}
	for _, ch := range target {
		if ch < 33 || ch > 126 {
			return true
		}
		if strings.ContainsRune(";&|`$<>\\\"'(){}[]!*?", ch) {
			return true
		}
	}
	return false
}
```

**两套校验的差异**（复刻时必须知道）：

| 项 | Python（后端） | Go（节点） |
|---|---|---|
| 长度上限 | `len(target) > 255`（**字符数**） | `len(target) > 255`（**字节数**） |
| 非 ASCII | `UNSAFE_TARGET_RE` 的 `\s` 不拦非 ASCII 字母 | `ch > 126` 显式拒绝 |
| 主机名长度 | 正则内 `(?=.{1,253}$)` | `len(target) <= 253` 单独判断（字节） |
| `route` 前缀 | `ip_network(strict=False)` + `subnet_of` | `net.ParseCIDR` + `containsPrefix`（首尾地址都必须在允许范围内） |

**这是纵深的代价**：两边对"中文域名"的处理不同（Python 会放过、Go 会拒），但由于后端先跑一遍，实际行为以后端为准；节点侧的差异只是"更严"。复刻时若要完全一致，可以把节点侧也改成按 rune 计数——但没必要，**宁可节点更严**。

#### 12.1.7 `route` 目标的节点侧判定

```go
func ValidateRouteTarget(target string) error {
	target = strings.TrimSpace(target)
	if target == "" || len(target) > 255 {
		return errors.New("invalid target length")
	}
	if hasUnsafeTargetChar(target) {
		return errors.New("target contains unsupported characters")
	}
	if ip := net.ParseIP(target); ip != nil {
		if isAllowedIP(ip) {
			return nil
		}
		return errors.New("target is outside the allowed address space")
	}
	_, network, err := net.ParseCIDR(target)
	if err != nil {
		return errors.New("route target must be an IP address or CIDR prefix")
	}
	if !isAllowedPrefix(network) {
		return errors.New("target is outside the allowed address space")
	}
	return nil
}
```

`isAllowedPrefix` → `containsPrefix(allowedIPv4Net, network) || containsPrefix(allowedIPv6Net, network)`，而 `containsPrefix` 检查**前缀的首地址和末地址都在父网段内**：

```go
func containsPrefix(parent *net.IPNet, child *net.IPNet) bool {
	return parent.Contains(child.IP) && parent.Contains(lastIP(child))
}

func lastIP(network *net.IPNet) net.IP {
	ip := network.IP
	if ip4 := ip.To4(); ip4 != nil {
		ip = ip4
	} else {
		ip = ip.To16()
	}

	last := make(net.IP, len(ip))
	copy(last, ip)
	for i := range last {
		last[i] |= ^network.Mask[i]
	}
	return last
}
```

**为什么两头都要查**：假设将来收窄成只允许 `172.20.0.0/14`，用户传 `0.0.0.0/0`。`parent.Contains(child.IP)` 会检查 `172.20.0.0` 是否在 `0.0.0.0/0` 内——真；但 `lastIP` 是 `255.255.255.255`，也在内。反过来，若用户传 `172.16.0.0/12`（包含 172.20 但更宽），首地址 `172.16.0.0` 不在 `172.20.0.0/14` 内→拒绝，这就对了。**只查首地址会漏掉"父网段在其中间"的情况**，所以必须查末地址。

Go 的 `net.IPNet.Mask` 与 `IP` 长度必须一致（IPv4 用 4 字节、IPv6 用 16 字节），所以 `lastIP` 里先做 `To4()`/`To16()` 归一化。**这是 Go 标准库的经典坑**：`net.ParseCIDR("1.1.1.0/24")` 返回的 `IP` 是 4 字节，`Mask` 也是 4 字节；但如果你自己构造 `IPNet` 用了 16 字节的 `IP` 配 4 字节 `Mask`，`^network.Mask[i]` 会在 `i >= 4` 时 panic（index out of range）。复刻时不要手搓 `IPNet`。

### 12.2 `POST /lg` 完整流程

#### 12.2.1 路由签名

```python
@router.post("/lg", response_class=HTMLResponse)
async def looking_glass(
    request: Request,
    node_id: str = Form(...),
    query_type: str = Form(...),
    target: str = Form(""),
    db: Session = Depends(get_db),
) -> Response:
```

三个要点：

1. **`async def`** —— 因为内部要 `await NodeClient().query(...)`。**不能写成同步 `def`**，否则 `await` 直接语法错误。这与 `POST /portal/peers`（同步，走 `request_node_sync`）形成对照。
2. **`target: str = Form("")`** —— 默认空串而非 `Form(...)`。为什么不设必填？因为 `route` 之外的查询在空目标时应给出"目标为空"的校验错误（走 `validate_target` 的 `not target` 分支），而不是 FastAPI 的 422。**422 的错误体是 JSON 数组，前端表单页无法展示**。
3. **`response_class=HTMLResponse`** —— 但实际可能返回 `JSONResponse`。FastAPI 的 `response_class` 只影响 OpenAPI 文档与默认序列化，手动 `return JSONResponse(...)` 会覆盖它。`-> Response` 的注解也是为此。

#### 12.2.2 完整代码

```python
    if not lg_rate_limiter.allow(client_ip(request)):
        raise HTTPException(
            status_code=429,
            detail="Too many looking glass queries. Please wait a moment and try again.",
        )
    node = query_enabled_nodes(db).filter(Node.id == node_id).one_or_none()
    if node is None:
        raise HTTPException(status_code=400, detail="Unknown or disabled node")
    result_text = ""
    ok = False
    normalized_query_type = query_type
    normalized_target = target.strip()
    try:
        normalized_query_type = validate_query_type(query_type)
        normalized_target = validate_target(normalized_query_type, target)
    except ValueError as exc:
        result_text = str(exc)
    else:
        try:
            result = await NodeClient().query(node, normalized_query_type, normalized_target)
            ok = bool(result.get("ok", False))
            result_text = str(result.get("output", result))
        except ValueError as exc:
            result_text = str(exc)
        except Exception as exc:
            logger.warning(
                "Looking glass query failed (node=%s, type=%s): %s",
                node.name,
                normalized_query_type,
                exc,
            )
            result_text = "Query failed: could not reach the looking glass node."
    user = current_user(request, db)
    db.add(
        LGQuery(
            user_id=user.id if user else None,
            node_id=node.id,
            query_type=normalized_query_type,
            target=normalized_target,
            ok=ok,
            result=result_text,
        )
    )
    db.commit()

    if request.headers.get("x-requested-with", "").lower() == "fetch":
        return JSONResponse({"ok": ok, "output": result_text, "query_type": normalized_query_type})

    nodes = query_enabled_nodes(db).all()
    return render(
        request,
        "lg.html",
        {
            "nodes": nodes,
            "lg_result": result_text,
            "lg_ok": ok,
            "last_query": normalized_query_type,
            "last_target": normalized_target,
        },
        user=user,
        active="lg",
    )
```

#### 12.2.3 逐段语义

##### (1) 限流在最前面

```python
if not lg_rate_limiter.allow(client_ip(request)):
```

**必须放在所有业务逻辑之前**，包括节点查询。理由：节点查询是一次 `SELECT`，如果先查再限流，攻击者仍能用高频请求打满数据库。限流键是 `client_ip(request)`，其实现见 §11.5（读 `Forwarded` 头 → 回退 `request.client.host` → `"unknown"`）。

⚠️ **`"unknown"` 会成为所有无法识别来源的请求的共享桶**。在缺少 `request.client` 且没有可信反代头的极端情况下，所有请求共享一个限流桶——这会误伤正常用户，但**不会**放过攻击者。宁可误伤不可放过，这个取舍是对的。

##### (2) 节点必须存在且 enabled

```python
node = query_enabled_nodes(db).filter(Node.id == node_id).one_or_none()
if node is None:
    raise HTTPException(status_code=400, detail="Unknown or disabled node")
```

`query_enabled_nodes(db)` 已经带了 `Node.enabled == True` 过滤（见 §11.6.1），所以"禁用节点"和"不存在"合并成一个 400。

**为什么是 400 而不是 404**：表单提交的是"参数错误"，不是"资源路径不存在"。用 400 让前端可以统一处理"表单校验失败"。文案 `Unknown or disabled node` 故意把两种情况混淆——不泄漏"该 ID 存在但被禁用"这一信息（虽然意义不大）。

**`node_id` 是 `str` 不是 `UUID`**：因为 `Node.id` 在模型里是字符串 UUID（见 §4.2），路由层不做类型转换，直接拿字符串比对。如果传入非法 UUID 字符串，`filter(Node.id == "abc")` 会返回 `None` → 400，不会抛异常。

##### (3) 校验失败与执行失败共用 `result_text`

```python
result_text = ""
ok = False
normalized_query_type = query_type
normalized_target = target.strip()
try:
    normalized_query_type = validate_query_type(query_type)
    normalized_target = validate_target(normalized_query_type, target)
except ValueError as exc:
    result_text = str(exc)
else:
    ...
```

三个**必须照抄**的细节：

- `normalized_query_type` 与 `normalized_target` **先赋初值**，因为校验失败时 `LGQuery` 仍要写入（审计"有人尝试了非法查询"）。若校验失败就 `return`，审计日志会丢失攻击痕迹。
- `normalized_target = target.strip()` 的初值与 `validate_target` 内部的 `strip()` 重复，但这是**有意的**：校验失败时 `LGQuery.target` 至少是去空白的原值，而不是 `""`。
- `ok = False` 的初值 —— 校验失败、节点失败、节点返回 `ok=false` 三种情况都是 `False`。只有节点明确返回 `ok=true` 才置真。

**校验失败的 `result_text` 直接就是 `ValueError` 的文案**，且会被写入数据库、展示在页面上。所以 §12.1 里那 6 条英文错误消息**是用户可见文案**，不能随意改写成中文或包含内部变量名。

##### (4) 节点执行的两种异常分开处理

```python
except ValueError as exc:
    result_text = str(exc)
except Exception as exc:
    logger.warning(...)
    result_text = "Query failed: could not reach the looking glass node."
```

| 异常 | 来源 | 文案 | 是否记日志 |
|---|---|---|---|
| `ValueError` | `NodeClient.query` 里的 `if not node.enabled: raise ValueError("Node is disabled")`，或 `validate_*` 二次校验 | 异常原文 | 否 |
| 其他 `Exception` | `NodeRequestError`（超时/离线/节点忙）、`RuntimeError`、任何未预期错误 | 固定文案 `Query failed: could not reach the looking glass node.` | 是，`logger.warning` 带 node/type |

**为什么区分**：`ValueError` 是"用户或状态问题"，消息已经面向用户；其他异常可能包含内部信息（节点名、URL、超时秒数），**不能直接展示**。固定文案既不泄漏内部结构，也给了用户一个可理解的结论。

**`logger.warning` 的参数是 `node.name` 而非 `node.id`** —— 运维看日志时认名字，不认 UUID。

**为什么 `except Exception` 这么宽**：LG 是公开入口，任何未预期的节点侧异常都不应导致 500 页面。宽捕获 + 固定文案是"公开接口的最后兜底"。

##### (5) `result.get("output", result)` 的兜底

```python
ok = bool(result.get("ok", False))
result_text = str(result.get("output", result))
```

节点返回的是 `{"ok": bool, "output": str}`（Go 侧 `runner.Result` 的 JSON 形态）。但若节点返回了别的结构（版本不匹配），`output` 键可能不存在，此时把整个 dict 字符串化展示。**这是兼容性兜底，不是正常路径**。

`bool(result.get("ok", False))` —— 显式 `bool()` 是因为节点可能返回 `"true"`（字符串）或 `1`。`bool("false")` 是 `True`，这是个坑，但 Go 的 `bool` 字段序列化一定是 JSON `true`/`false`，所以实际不会出问题。

##### (6) 审计写入在响应构造之前

```python
user = current_user(request, db)
db.add(LGQuery(...))
db.commit()
```

**`db.commit()` 必须在这里**，不能等到响应之后。理由：如果节点查询成功但审计写入失败，用户看到了结果而库里没有记录——审计的目的就落空了。反过来，先 commit 再构造响应，即使响应构造失败（比如模板渲染报错），审计也已落盘。

**`user_id=user.id if user else None`** —— 匿名用户也能查，`user_id` 可空（见 §4.2 `LGQuery.user_id` nullable）。

⚠️ **`LGQuery` 没有 `client_ip` 列**（见 §11.8.6）。这意味着审计日志**无法回答"是哪个 IP 刷的"**，只能在限流层实时拦截、无法事后追溯。这是已知缺口，复刻时建议加一列（见 §18 改进建议）。

##### (7) HTML / JSON 双分支

```python
if request.headers.get("x-requested-with", "").lower() == "fetch":
    return JSONResponse(...)
```

**契约**：前端 `app.js` 在 `fetch` 时设置 `X-Requested-With: fetch`；后端用这个头区分"表单提交"与"页内异步"。

| 分支 | 触发 | 响应 | 用途 |
|---|---|---|---|
| JSON | `X-Requested-With` 归一化后等于 `fetch` | `{"ok": bool, "output": str, "query_type": str}` | 前端不刷新页面，用 JS 替换结果区域 |
| HTML | 其他所有情况（包括无该头、大小写不同、值不是 `fetch`） | 渲染 `lg.html`，带 `lg_result`/`lg_ok`/`last_query`/`last_target` | 无 JS 时的降级路径 |

**`.lower()` 是必须的**：HTTP 头名本身大小写不敏感，但值不敏感的标准没有；原作者选择对值也做小写归一，避免前端写 `Fetch` 时行为不一致。

**HTML 分支必须回传 `nodes`** —— 因为模板要重新渲染节点下拉框。`last_query`/`last_target` 用于回填表单（用户查询后表单不清空）。

#### 12.2.4 状态码与文案总表

| 场景 | 状态码 | 响应体 | 来源 |
|---|---|---|---|
| 超过限流 | 429 | `{"detail": "Too many looking glass queries. Please wait a moment and try again."}` | `HTTPException` |
| 节点不存在/禁用 | 400 | `{"detail": "Unknown or disabled node"}` | `HTTPException` |
| 查询类型非法 | **200** | HTML 或 `{"ok": false, "output": "unsupported looking glass query"}` | 校验失败，走正常响应 |
| 目标长度非法 | **200** | 同上，`output = "invalid target length"` | 同上 |
| 目标含危险字符 | **200** | `output = "target contains unsupported characters"` | 同上 |
| route 目标非 IP/前缀 | **200** | `output = "route target must be an IP address or CIDR prefix"` | 同上 |
| 目标非 IP 且非主机名 | **200** | `output = "target must be a valid IP address or hostname"` | 同上 |
| 节点执行失败 | **200** | `output = "Query failed: could not reach the looking glass node."` | 宽捕获 |
| 节点忙（信号量满） | **200** | `output = "node is busy, try again shortly"`，`ok = false` | Go 侧 `limitedResult` |
| 查询成功 | **200** | `output = 命令输出`，`ok = true` | 正常 |

⚠️ **注意"校验失败仍是 200"**。这是原实现的选择：校验错误被当成"查询结果"展示（红色结果框），而不是错误页。好处是用户体验连续（停留在 LG 页、表单不清空），坏处是**监控无法用状态码区分"用户输错了"与"查询成功"**。复刻时若需要可观测性，可以在 `LGQuery` 里加 `error_kind` 列，而不是改状态码（改状态码会破坏前端 fetch 分支）。

### 12.3 限流

#### 12.3.1 完整实现

```python
# app/lg/ratelimit.py
import threading
import time
from collections import defaultdict, deque


class SlidingWindowRateLimiter:
    def __init__(self, limit: int, window_seconds: float) -> None:
        self.limit = limit
        self.window = float(window_seconds)
        self._hits: dict[str, deque[float]] = defaultdict(deque)
        self._lock = threading.Lock()

    def allow(self, key: str) -> bool:
        """Record a hit for ``key`` and return whether it is within the limit."""
        if self.limit <= 0 or self.window <= 0:
            return True
        now = time.monotonic()
        with self._lock:
            hits = self._hits[key]
            cutoff = now - self.window
            while hits and hits[0] < cutoff:
                hits.popleft()
            if len(hits) >= self.limit:
                return False
            hits.append(now)
            self._prune(cutoff)
            return True

    def _prune(self, cutoff: float) -> None:
        if len(self._hits) <= 2048:
            return
        stale = [k for k, dq in self._hits.items() if not dq or dq[-1] < cutoff]
        for k in stale:
            del self._hits[k]
```

#### 12.3.2 算法语义

**滑动窗口（sliding window）**，不是固定窗口。每个 `key` 维护一个**单调递增的时间戳队列**：

1. 计算 `cutoff = now - window`。
2. 从队头弹出所有 `< cutoff` 的时间戳（它们已滑出窗口）。
3. 若队列长度 `>= limit` → 拒绝（**注意：拒绝时不记录本次请求**，所以被拒的请求不会延长封锁——这是对用户友好的设计）。
4. 否则追加 `now`，返回 `True`。

**为什么用滑动窗口而非固定窗口**：固定窗口在边界处可以双倍突发（第 59 秒 20 次 + 第 61 秒 20 次 = 2 秒内 40 次）。滑动窗口严格保证"任意 60 秒内不超过 20 次"。

#### 12.3.3 参数与配置

| 项 | 值 | 来源 |
|---|---|---|
| `limit` | `settings.lg_rate_limit`，默认 20 | `.env` 的 `LG_RATE_LIMIT` |
| `window` | `settings.lg_rate_window_seconds`，默认 60 | `.env` 的 `LG_RATE_WINDOW_SECONDS` |
| 实例 | 模块级单例 `lg_rate_limiter`（`app/web/deps.py`） | import 时创建 |
| 键 | `client_ip(request)` | 见 §11.5 |

**`limit <= 0` 或 `window <= 0` 直接放行** —— 这是"关闭限流"的配置开关。⚠️ 生产环境不要设成 0。

#### 12.3.4 `time.monotonic()` 而非 `time.time()`

`monotonic` 不受系统时钟跳变（NTP 校时、手动改时间）影响。若用 `time.time()`，时钟回拨会导致队列里的时间戳"在未来"，`now - window` 变小，所有旧记录留在窗口内，用户被永久封锁直到时钟追平。**这是限流器的经典 bug**。

#### 12.3.5 内存边界

`_hits` 是一个 `defaultdict(deque)`，键为 IP 字符串。**没有上限**，但有 `_prune`：

- **触发条件**：`len(self._hits) > 2048`。
- **清理条件**：该键的队列为空，**或**最后一个时间戳 `< cutoff`（即该 IP 在最近一个窗口内无请求）。
- **调用时机**：只在 `allow()` 通过限流后调用（拒绝时不调，避免被拒绝的请求触发 O(n) 扫描）。

⚠️ **`_prune` 的复杂度是 O(键数)**，在 2048 个键时约几毫秒。攻击者可以用大量源 IP 把 `_hits` 撑大，导致每次 `allow` 都做一次全量扫描。这是**已知的 DoS 面**，但在单机 LG 场景下可接受（见 §18 改进建议）。

#### 12.3.6 多 worker 语义

源码注释明确：

> Process-local: when running multiple workers each keeps its own counters, which is acceptable for the looking glass abuse-prevention use case.

**若用 `uvicorn --workers 4`（或 gunicorn 多 worker），实际限流阈值是 `limit × worker 数`**。例如 4 worker + `limit=20` → 每 IP 每 60 秒最多 80 次。

**这不是 bug，是有意的**：LG 的限流目的是"防止把路由器打挂"，配合节点侧并发上限（§13）已经足够；引入 Redis 做全局计数属于过度工程。

⚠️ **复刻时必须知道这个语义**。如果只起 1 个 worker，阈值就是配置值；如果起 N 个，实际是 N 倍。不要把 `LG_RATE_LIMIT=20` 理解成"全局限流 20/分钟"。

#### 12.3.7 与 `FORWARDED_IP_HEADER` 的配合

限流键来自 `client_ip(request)`，而它对 `Forwarded` 头的信任**完全取决于 `FORWARDED_IP_HEADER` 是否配置**：

| `FORWARDED_IP_HEADER` | `client_ip` 取值 | 安全性 |
|---|---|---|
| 未配置（默认） | `request.client.host`（TCP 对端） | **安全**：用户无法伪造 |
| 配置为 `X-Forwarded-For` | 该头第一段 | **仅在反代覆盖该头时安全** |

⚠️ **若反代用"追加"而非"覆盖"语义**（如 nginx 的 `proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for`），攻击者可以自带 `X-Forwarded-For: 1.2.3.4`，反代变成 `1.2.3.4, <真实IP>`，`client_ip` 取第一段 = `1.2.3.4` → **限流被完全绕过**。

正确配置见 §2.6：

```nginx
proxy_set_header X-Forwarded-For $remote_addr;
```

`$remote_addr` 是覆盖，`$proxy_add_x_forwarded_for` 是追加。**必须用前者**。

### 12.4 审计日志

#### 12.4.1 `LGQuery` 表结构

| 列 | 类型 | 可空 | 说明 |
|---|---|---|---|
| `id` | UUID | 否 | 主键 |
| `user_id` | UUID FK → `users.id` | **是** | 匿名查询为 NULL |
| `node_id` | UUID FK → `nodes.id` | 否 | 查询目标节点 |
| `query_type` | str | 否 | **归一化后**的类型（`Ping` → `ping`）；校验失败时是原始输入 |
| `target` | str | 否 | **`strip()` 后**的目标；校验失败时是原始输入去空白 |
| `ok` | bool | 否 | 节点明确返回成功才为 True |
| `result` | text | 否 | 输出或错误文案（可能很长） |
| `created_at` | datetime | 否 | UTC |

⚠️ **没有 `client_ip` 列**。这导致：

1. 审计页无法显示"谁查的"（只能显示"是否登录用户"）。
2. 无法事后统计"哪个 IP 在刷"。
3. 无法做"封禁"。

**为什么原实现没有**：`LGQuery` 的设计目标是"记录查了什么、结果如何"，而不是"记录谁查的"。实名信息由 `user_id` 承担（登录用户），匿名用户则完全无痕。这在 GDPR 意义上更友好，但在滥用治理上是短板。

#### 12.4.2 审计写入时机

**无论成功还是失败都写**，且写入发生在响应构造之前（见 12.2.3(6)）。这保证了：

- 非法查询（注入尝试）留下痕迹 → 可分析攻击模式。
- 节点离线时的失败也记录 → 可统计节点可用性。

#### 12.4.3 管理端查看

`GET /admin/lg-log`（见 §11.8.6）分页展示，`LG_LOG_PER_PAGE=50`，按 `created_at` 倒序（最新在前）。展示列：时间、节点、类型、目标、结果（截断）、用户。

⚠️ **`result` 可能包含大段命令输出**（`traceroute -m 20` 约 2KB），50 条/页的列表页若不加截断会很慢。原实现在模板里截断（见 `admin/lg_log.html`），而不是在 SQL 里截断——这意味着查询仍然取全量 `result`。数据量大时建议改成 `SELECT` 时截断或分表（见 §18）。

### 12.5 状态摘要

#### 12.5.1 为什么需要摘要

节点侧 `peers.status` 返回的是 `birdc show protocols all <name>` + `wg show <iface>` 的**完整原文**，动辄 100+ 行。门户详情页和 Bot 的 `/listpeers` 只需要回答三个问题：

1. BGP 起来了吗？
2. 路由收/发了多少？
3. WireGuard 有握手吗？多久前？

`app/lg/summary.py` 就是做这件事的"人类可读压缩层"。**它运行在服务端**，因此 Web 与 Bot 展示一致（源码注释明确这一点）。

⚠️ **`NodeClient.peer_status` 返回的是原文，不摘要**（见 `app/lg/client.py` 的 docstring）。摘要由**调用方**决定：
- 门户详情页 → `summarize_peer_bird` + `summarize_wireguard`
- Bot `/listpeers` → 同上
- 管理端 `/admin/peers/{id}/status` → **不摘要**，展示完整原文（运维排障需要）

#### 12.5.2 `_capped` 兜底

```python
_ROUTES_RE = re.compile(r"(\d+)\s+imported.*?(\d+)\s+exported")


def _capped(text: str, *, max_lines: int = 6, max_chars: int = 400) -> str:
    """The trimmed text capped to a few lines/chars — the fallback when parsing fails."""
    text = (text or "").strip()
    if not text:
        return "(no output)"
    lines = text.splitlines()
    clipped = "\n".join(lines[:max_lines])
    if len(lines) > max_lines or len(clipped) > max_chars:
        clipped = clipped[:max_chars].rstrip() + " …"
    return clipped
```

三个细节：

- **空输出返回 `(no output)`** 而非空串。空串在页面上显示为空白，用户会以为"页面坏了"。
- **先按行裁，再按字符裁**。只按字符裁会把最后一行切成半个单词。
- **截断后缀是 `" …"`**（前有空格）。这是视觉提示"还有更多"。

**为什么需要兜底**：`birdc`/`wg` 的输出格式会随版本变化，或出现未预期的错误消息。此时**宁可展示原始前 6 行**，也不能返回空/错——"为什么 down" 的线索可能就藏在那几行里（源码注释：`the reason something is down is never hidden`）。

#### 12.5.3 `summarize_peer_bird`

```python
def summarize_peer_bird(output: str) -> str:
    text = output or ""
    state_match = re.search(r"BGP state:\s*(\S+)", text)
    if not state_match:
        return _capped(text)
    state = state_match.group(1)
    if state.lower() == "established":
        pairs = _ROUTES_RE.findall(text)
        if pairs:
            imported = sum(int(imp) for imp, _ in pairs)
            exported = sum(int(exp) for _, exp in pairs)
            return f"Established · routes {imported} in / {exported} out"
        return "Established"
    error = re.search(r"Last error:\s*(.+)", text)
    reason = error.group(1).strip() if error else ""
    return f"{state} — {reason}" if reason else state
```

**分支表**：

| 输入特征 | 输出 | 例 |
|---|---|---|
| 无 `BGP state:` | `_capped(text)` | `birdc: command not found` |
| `BGP state: Established` + 有 Routes 行 | `Established · routes <sum in> in / <sum out> out` | `Established · routes 12 in / 3 out` |
| `BGP state: Established` + 无 Routes 行 | `Established` | — |
| 其他 state + 有 `Last error:` | `<state> — <reason>` | `Active — Connection refused` |
| 其他 state + 无 `Last error:` | `<state>` | `Idle` |

**`_ROUTES_RE` 的跨行匹配**：`(\d+)\s+imported.*?(\d+)\s+exported` 中的 `.*?` **不匹配换行**（Python `re` 默认 `re.S` 未开），所以它只在**同一行**内匹配。`birdc show protocols all` 的 IPv4/IPv6 通道各有一行 `Routes: X imported, Y filtered, Z exported, W preferred`，因此 `findall` 会拿到多组，**求和**是正确的。

⚠️ **`.*?` 不跨行是依赖而非巧合**。若某天 BIRD 版本的输出把 `imported` 和 `exported` 分到两行，这个正则就失效 → 回退到只显示 `Established`（不算错，只是信息变少）。

**`state.lower() == "established"`** —— BIRD 输出里是大写 `Established`，但做小写归一更稳。

**`—` 是 em dash（U+2014）**，两侧各有一个空格。不是 `-`。复刻时若用 ASCII 连字符，视觉上会不一致，但不影响功能。

#### 12.5.4 `summarize_wireguard`

```python
def summarize_wireguard(output: str) -> str:
    text = (output or "").strip()
    if not text or "No such device" in text or "Unable to access interface" in text:
        return "interface down"
    if "interface:" not in text and "peer:" not in text:
        return _capped(text)
    endpoint = re.search(r"endpoint:\s*(\S+)", text)
    handshake = re.search(r"latest handshake:\s*(.+)", text)
    transfer = re.search(r"transfer:\s*(.+)", text)
    age = handshake.group(1).strip() if handshake else ""
    if not age or age.lower() == "(none)":
        suffix = f" · endpoint {endpoint.group(1)}" if endpoint else ""
        return f"no handshake yet{suffix}"
    state = "stale" if re.search(r"\b(hour|day)", age) else "up"
    parts = [f"{state} · handshake {age}"]
    if transfer:
        xfer = transfer.group(1).strip()
        amounts = re.match(r"(.+?)\s+received,\s*(.+?)\s+sent", xfer)
        parts.append(f"{amounts.group(1)} rx / {amounts.group(2)} sent" if amounts else xfer)
    return " · ".join(parts)
```

**分支表**：

| 输入特征 | 输出 |
|---|---|
| 空 / `No such device` / `Unable to access interface` | `interface down` |
| 无 `interface:` 也无 `peer:` | `_capped(text)` |
| 无 `latest handshake:` 或值为 `(none)` | `no handshake yet` 或 `no handshake yet · endpoint 1.2.3.4:51820` |
| 握手时长含 `hour` 或 `day` | `stale · handshake 2 hours ago` + 传输量 |
| 其他 | `up · handshake 12 seconds ago · 1.2 KiB rx / 3.4 KiB sent` |

**为什么 `stale` 判定用 `hour|day`**：`wg show` 的握手时长格式是 `1 minute ago`、`2 hours ago`、`3 days ago`。一个健康的隧道有 keepalive（默认 25 秒），握手时间应始终在分钟级。出现 `hour`/`day` 说明对端已断但接口还在 → **隧道假活**，这是最需要告警的状态。

⚠️ **`\b(hour|day)` 带词边界**，避免把 `hours` 以外的东西误判。但注意 `1 day ago` 与 `2 days ago` 都命中 `day`（`\b` 在 `s` 前不成立——`day` 后面是 `s`，不是词边界……实际 `\bday` 只是前缀绑定，`days` 里 `day` 后跟 `s`，`\b` 在 `day` 之后不要求，所以 `\b(hour|day)` 能匹配 `days` 中的 `day`）。结论：`hours`/`days` 都能命中，这是对的。

**`transfer` 的正则 `(.+?)\s+received,\s*(.+?)\s+sent`** —— `wg` 的输出是 `1.23 KiB received, 4.56 KiB sent`。`(.+?)` 非贪婪，`\s+` 分隔。若格式不匹配（版本差异），退化为展示 `xfer` 原文。

**返回值用 ` · ` 连接** —— 与 `summarize_peer_bird` 一致，便于模板统一渲染。

#### 12.5.5 端到端示例

节点返回的 `birdc show protocols all DN42_0090_0001`（节选）：

```
BIRD 2.0.12 ready.
dn42_0090_0001 BGP        --- up        00:12:34  Established
  BGP state:          Established
  Neighbor address:   fe80::99%dn42_0090_0001
  Neighbor AS:        4242420099
  Last error:         No error
  Routes:             12 imported, 3 filtered, 5 exported, 2 preferred
```

→ `summarize_peer_bird` 输出：`Established · routes 12 in / 5 out`

节点返回的 `wg show DN42_0090_0001`（节选）：

```
interface: DN42_0090_0001
  public key: abc...
  private key: (hidden)
  listening port: 20090

peer: xyz...
  endpoint: 198.51.100.7:51820
  allowed ips: fe80::99/128, fd00::99/128
  latest handshake: 42 seconds ago
  transfer: 1.23 MiB received, 4.56 MiB sent
  persistent keepalive: every 25 seconds
```

→ `summarize_wireguard` 输出：`up · handshake 42 seconds ago · 1.23 MiB rx / 4.56 MiB sent`

门户详情页最终展示两行徽章 + 摘要（见 §11.7.5）。

### 12.6 节点侧命令映射

后端只发 `lg.<type>` 命令，节点侧 `internal/api/server.go` 的 `Command()` 把它映射到具体的 `Runner` 方法，再由 `Runner` 拼装**固定 argv**。

#### 12.6.1 映射表

| 后端命令 | payload | Go 方法 | 最终 argv（默认路径） |
|---|---|---|---|
| `lg.ping` | `{"target": "..."}` | `Runner.Ping` | `/bin/ping -c 4 -W 3 <target>` |
| `lg.trace` | 同上 | `Runner.Trace` | `/usr/bin/traceroute -n -q 1 -w 2 -m 20 [ -6 ] <target>` |
| `lg.mtr` | 同上 | `Runner.Mtr` | `/usr/bin/mtr --report --report-cycles 4 --no-dns --report-wide [ -6 ] <target>` |
| `lg.route` | 同上 | `Runner.Route` | `/usr/bin/birdc show route for <target>` |
| `pubkey` | 无 | 直接返回 | **不起进程**，返回配置里的 `WireGuardPublicKey` |
| `peers.status` | `{"protocol_name": "..."}` | `Runner.PeerStatus` + `Runner.PeerWireGuard` | `birdc show protocols all <name>` / `wg show <name>` |
| `peers.deploy` | `DeployRequest` | `Runner.DeployPeer` | `wg-quick down/up` + 原子写文件（见 §13） |
| `peers.remove` | `RemoveRequest` | `Runner.RemovePeer` | 删文件 + `wg-quick down` + reload |

#### 12.6.2 为什么这些参数是这些值

| 命令 | 参数 | 取值 | 理由 |
|---|---|---|---|
| `ping` | `-c 4` | 4 个包 | 够判断连通性，不会跑太久 |
| `ping` | `-W 3` | 每包 3 秒超时 | 4 包最坏 12 秒，仍在 `Runner.Timeout`（10s？见下）内——**实际会先被总超时打断** |
| `traceroute` | `-n` | 不反解 DNS | 避免依赖节点 DNS、避免慢 |
| `traceroute` | `-q 1` | 每跳 1 个探测 | 4 倍速于默认 3 |
| `traceroute` | `-w 2` | 每跳等 2 秒 | 20 跳最坏 40 秒，但总超时会更早打断 |
| `traceroute` | `-m 20` | 最多 20 跳 | dn42 内部路径一般 < 10 跳，公网 < 20 |
| `mtr` | `--report` | 非交互模式 | API 唯一可用的形式 |
| `mtr` | `--report-cycles 4` | 4 轮 | 与 `ping -c 4` 对齐 |
| `mtr` | `--no-dns` | 数字输出 | 同 `traceroute -n` |
| `mtr` | `--report-wide` | 宽输出 | 防 IPv6 长地址被截断 |
| `birdc route` | `show route for` | 最长前缀查找 | 主机 IP 无精确表项时也能返回"实际用到的路由" |
| `birdc protocols` | `show protocols all <name>` | 单协议全量 | 含 `BGP state`、`Routes`、`Last error` |

⚠️ **`Runner.Timeout` 默认值与命令参数的矛盾**：`ping -c 4 -W 3` 最坏 12 秒，`traceroute -w 2 -m 20` 最坏 40 秒，但 `Runner.Timeout` 默认是 **10 秒**（见 `internal/config`）。这意味着**远端不可达时，traceroute 几乎总会先被总超时杀掉**，返回 `output + "\ncommand timed out"` 且 `ok=false`。

这不是 bug，而是有意的取舍：**LG 是公开的，宁可让查询快速失败，也不能让一个 40 秒的子进程占着信号量**。复刻时若把 `Timeout` 调到 45 秒，请同步评估并发上限——12 秒的子进程 × 4 并发还好，40 秒 × 4 并发就会明显挤占路由器。

#### 12.6.3 IPv6 的 `-6` 判定

```go
if ip := net.ParseIP(target); ip != nil && ip.To4() == nil {
    args = append(args, "-6")
}
```

**只有 IPv6 字面量才加 `-6`**：

| target | `net.ParseIP` | `To4()` | 加 `-6`？ |
|---|---|---|---|
| `1.1.1.1` | 非 nil | 非 nil | 否 |
| `2606:4700::1111` | 非 nil | nil | **是** |
| `example.com` | nil | — | 否（交给程序自己解析） |
| `::ffff:1.1.1.1`（IPv4-mapped） | 非 nil | **非 nil** | 否（按 IPv4 处理） |

**为什么主机名不加 `-6`**：主机名可能同时有 A 和 AAAA 记录，强制 `-6` 会让只有 A 记录的域名直接失败。交给 `traceroute`/`mtr` 自己决定。

**为什么 IPv4-mapped 按 IPv4**：`::ffff:1.1.1.1` 在双栈环境下应走 IPv4 路径。`To4()` 正是这个语义。

#### 12.6.4 `route` 的 `for` 关键字

```go
return r.run(r.BirdcPath, "show", "route", "for", target)
```

| 写法 | 语义 | 主机 IP `1.1.1.1` 的结果 |
|---|---|---|
| `show route 1.1.1.1` | **精确前缀匹配** | 无此表项 → 空 |
| `show route for 1.1.1.1` | **最长前缀转发查找** | 返回覆盖 `1.1.1.1` 的那条路由 |

这是 LG 的核心价值：用户想知道"到 1.1.1.1 走哪条路"，精确匹配会返回空。**`for` 不能省**。

#### 12.6.5 节点侧的 `Result` 语义

```go
type Result struct {
	OK     bool   `json:"ok"`
	Output string `json:"output"`
}
```

`run()` 的返回逻辑：

```go
func (r Runner) run(args ...string) Result {
	if len(args) == 0 {
		return Result{OK: false, Output: "missing command"}
	}
	ctx, cancel := context.WithTimeout(context.Background(), r.Timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, args[0], args[1:]...)
	out, err := cmd.CombinedOutput()
	output := string(out)
	if ctx.Err() == context.DeadlineExceeded {
		return Result{OK: false, Output: output + "\ncommand timed out"}
	}
	if err != nil {
		return Result{OK: false, Output: strings.TrimSpace(output + "\n" + err.Error())}
	}
	return Result{OK: true, Output: strings.TrimSpace(output)}
}
```

| 情况 | `OK` | `Output` |
|---|---|---|
| 命令成功 | `true` | `strings.TrimSpace(stdout+stderr)` |
| 超时 | `false` | `已产生的输出 + "\ncommand timed out"` |
| 非零退出 | `false` | `输出 + "\n" + err.Error()`，整体 trim |
| `args` 为空 | `false` | `missing command` |

**`CombinedOutput()` 把 stderr 并进 stdout** —— 因为 `ping`/`traceroute` 的进度信息走 stderr，只取 stdout 会丢内容。

**超时时保留已产生的输出** —— 这对于 traceroute 很重要：即使被超时杀掉，用户仍能看到走到哪一跳。

**`strings.TrimSpace` 只在成功和非零退出时做**，超时分支不 trim（因为中间有换行）。复刻时不必纠结这点差异。

⚠️ **`exec.CommandContext` 超时后会 `SIGKILL` 整个进程，但不保证杀死其子进程**（如果命令自己 fork 了）。`traceroute`/`mtr` 不 fork，`wg-quick` 会调用 `wg`/`ip`——所以 `DeployPeer` 用了更长的超时且**不能**依赖 `CommandContext` 的树杀（见 §13）。

### 12.7 实现陷阱

1. **`ALLOWED_NETWORKS` 是刻意放开到全网**。注释明确不许收窄。复刻时若要收窄，请显式记录为定制偏离，并同步修改 `internal/runner` 的同名常量，否则后端放行、节点拒绝，用户会看到莫名其妙的 `target is outside the allowed address space`。
2. **校验顺序不能重排**。`strip()` 必须在危险字符检查之前，危险字符检查必须在类型分支之前。把 `route` 分支放在字符检查前面，`-1.0.0.0/8` 会先被 `ip_network` 处理。
3. **`UNSAFE_TARGET_RE` 的 `\s` 是关键**。少了它，`"1.1.1.1 -c 1000000"` 会把参数走私进单次查询。虽然 `exec argv` 不做 shell 解析，但这里的目标字符串是**作为单个 argv 元素**传的——`ping` 收到含空格的目标会报错，不会真的执行 `-c`。不过 `mtr`/`traceroute` 某些版本会做参数再解析，所以 `\s` 是必要的纵深层。
4. **限流失败时不记录命中**。`len(hits) >= limit` 直接 `return False`，不 `append(now)`。若改成先记录再判断，被拒的请求会不断延长封锁窗口，用户永远解不开。
5. **限流用 `time.monotonic()`**。换成 `time.time()` 会在 NTP 校时后出现"窗口永久填满"的 bug。
6. **限流是进程内计数**。多 worker 时阈值是配置值的 N 倍。不要把 `LG_RATE_LIMIT` 当全局限流。
7. **`client_ip` 的信任完全取决于 `FORWARDED_IP_HEADER`**。反代必须**覆盖**而非追加 `X-Forwarded-For`，否则限流可被伪造头绕过。
8. **`POST /lg` 是 `async def`，必须 `await NodeClient().query`**。改成同步 `def` 会直接语法错误；改成 `request_node_sync` 会阻塞事件循环。
9. **校验失败也返回 200 并写审计**。不要"优化"成抛 400——那会破坏前端 fetch 分支（它会尝试 `res.json()` 解析错误页 HTML）。也不要"优化"成不写审计——那会丢失攻击痕迹。
10. **`LGQuery` 没有 `client_ip`**。审计页无法追溯来源 IP。若需要，先加列再改 `POST /lg` 的写入，注意旧数据该列为 NULL。
11. **`NodeClient.peer_status` 返回原文，不摘要**。摘要由调用方决定。管理端故意展示全文；门户/Bot 才摘要。
12. **`summarize_peer_bird` 的 `.*?` 不跨行**。这是依赖 `birdc` 把 `imported`/`exported` 放同一行的实现细节。跨行会退化为只显示 `Established`。
13. **`summarize_wireguard` 的 `stale` 判定是 `hour|day`**。不要改成"超过 5 分钟"——`wg` 的 handshake 时间戳精度只有秒/分/小时/天，无法做分钟级判断。
14. **节点忙的文案是 `node is busy, try again shortly`**，且 `ok=false`、状态码 200。它和"节点离线"（`Query failed: could not reach the looking glass node.`）是两种不同情况，运维排查时要区分。
15. **`Runner.Timeout` 默认 10 秒小于 `traceroute -m 20 -w 2` 的最坏 40 秒**。远端不可达时 traceroute 几乎必然超时。这是有意的：LG 宁可快速失败，也不让慢查询占着并发槽。
16. **`route` 必须用 `show route for`**。用 `show route` 对主机 IP 会返回空，用户会以为"路由表里没有到 1.1.1.1 的路由"——实际上是查询方式错了。
17. **`-6` 只对 IPv6 字面量加**。对主机名加 `-6` 会让只有 A 记录的域名失败。
18. **`exec.CommandContext` 的超时杀不保证杀子进程**。`wg-quick` 会 fork `wg`/`ip`，所以部署路径不能用短超时硬杀（见 §13.3.6）。

---

## §13 Go Node 实现规格

节点服务是整个系统里**唯一以 root 运行**的组件。它同时承担四件事：

1. **主动拨出**到后端的 WSS（不监听任何端口，§13.3）；
2. 执行**外部命令**（`ping`/`traceroute`/`mtr`/`birdc`/`wg`/`wg-quick`）；
3. **写文件**（WireGuard 与 BIRD 的对等配置）；
4. **上报主机指标**（心跳里的 `system`）。

这四件事的任何一件做错都会导致"节点挂掉"或"被当成提权跳板"。因此 §13 的重点是**边界**：哪些字符串可以进 argv、哪些路径可以写、哪些调用必须串行。

### 13.1 模块划分

```
cmd/node/main.go          启动、配置校验、装配
internal/config/config.go  JSON 配置加载 + 默认值 + 指针语义
internal/backend/client.go WSS 客户端（手写握手/帧）+ 心跳 + 指标采集
internal/api/server.go     命令分发 + 并发信号量 + 部署串行锁
internal/runner/runner.go  外部命令执行 + 校验 + 原子写 + chown
```

**依赖方向是单向的**：`main` → `backend`/`api`/`runner`/`config`；`backend` → `api` + `runner` + `config`；`api` → `runner`；`runner` → `config`。没有环。`config` 不 import 任何内部包。

`go.mod` 只有两行：

```
module dn42-autopeer-node

go 1.22
```

**没有任何第三方依赖**。WebSocket 是手写的（§13.3），JSON 用标准库，进程调用用 `os/exec`。这不是为了炫技，而是**为了可审计**：节点以 root 跑在生产路由器上，一个第三方 WS 库的 CVE 就是一次 root 提权。

### 13.2 启动与配置

#### 13.2.1 `main.go` 完整逻辑

```go
func main() {
	configPath := flag.String("config", "config.json", "path to the node config JSON file")
	flag.Parse()

	cfg, err := config.Load(*configPath)
	if err != nil {
		log.Fatal(err)
	}

	if !runner.ValidWireGuardKey(cfg.WireGuardPublicKey) {
		log.Fatal("wireguard_public_key is required and must be a 44-character base64 WireGuard key")
	}
	if cfg.BackendWSURL == "" {
		log.Fatal("backend_wss_url is required")
	}
	if cfg.Name == "" {
		log.Fatal("name is required when backend_wss_url is set")
	}

	r := runner.New(cfg)
	server := api.New(r, cfg.Concurrency())
	client := backend.New(cfg, server)
	client.Run(context.Background())
}
```

**四项启动前校验，缺一不可**：

| 校验 | 失败消息 | 为什么必须在启动时做 |
|---|---|---|
| `ValidWireGuardKey(cfg.WireGuardPublicKey)` | `wireguard_public_key is required and must be a 44-character base64 WireGuard key` | 这个公钥会**原样发给每个对等端**。若格式错误，对等端会生成一份连不上的配置，且错误会在对端才暴露——极难排查 |
| `BackendWSURL != ""` | `backend_wss_url is required` | 本版本**不再监听端口**，没有 URL 就等于进程空转 |
| `Name != ""` | `name is required when backend_wss_url is set` | 后端用 `?name=` 认节点。空名字会被后端拒绝（见 §13.4.2） |
| `config.Load` 成功 | `read config ... / parse config ...` | 未知键会被拒绝（`DisallowUnknownFields`），避免拼写错误静默生效 |

**`context.Background()` 是根 context** —— `client.Run` 内部靠它传取消。原实现没有接 `signal.Notify`，靠 systemd 的 `SIGTERM` → 进程直接退出。复刻时若想优雅退出（发 WS close 帧），需要改这里。

⚠️ **`log.Fatal` 走的是 `os.Exit(1)`，不执行 defer**。这对启动期是可接受的（还没建任何资源），但**不要**在运行期用 `log.Fatal`——会导致 WS 连接不被关闭、临时文件不清理。

#### 13.2.2 `Config` 结构体与指针语义

```go
type Config struct {
	Name  string `json:"name"`
	Token string `json:"token"`
	BackendWSURL string `json:"backend_wss_url"`

	MaxConcurrency *int `json:"max_concurrency"`
	CommandTimeoutSeconds int `json:"command_timeout_seconds"`

	BirdcPath      string `json:"birdc_path"`
	PingPath       string `json:"ping_path"`
	TraceroutePath string `json:"traceroute_path"`
	MtrPath     string `json:"mtr_path"`
	WgPath      string `json:"wg_path"`
	WgQuickPath string `json:"wg_quick_path"`

	WireGuardPeerDir string `json:"wireguard_peer_dir"`
	BirdPeerDir      string `json:"bird_peer_dir"`
	BirdPeerGroup   *string `json:"bird_peer_group"`
	DeployReloadCmd string  `json:"deploy_reload_cmd"`

	WireGuardPrivateKey string `json:"wireguard_private_key"`
	WireGuardPublicKey  string `json:"wireguard_public_key"`
}
```

**两个 `*int` / `*string` 不是随手为之**：

```go
func (c Config) Concurrency() int {
	if c.MaxConcurrency == nil || *c.MaxConcurrency < 0 {
		return defaultMaxConcurrency
	}
	return *c.MaxConcurrency
}

func (c Config) BirdGroup() string {
	if c.BirdPeerGroup == nil {
		return defaultBirdPeerGroup
	}
	return strings.TrimSpace(*c.BirdPeerGroup)
}
```

| 字段 | JSON 缺失（nil） | 显式 `0` / `""` | 负数 |
|---|---|---|---|
| `max_concurrency` | 默认 **4** | **0 = 不限制** | 退回默认 4 |
| `bird_peer_group` | 默认 **`"bird"`** | **`""` = 完全不 chown** | — |

**为什么不能用普通 `int`/`string`**：普通类型无法区分"未设置"与"显式设成零值"。而这两个字段的零值语义**恰好相反**：

- `max_concurrency = 0` 表示"关闭并发限制"（运维明确要求不限制）；
- `bird_peer_group = ""` 表示"不要 chown"（BIRD 以 root 跑，或用 setgid 目录管理组）。

若用普通 `int`，`max_concurrency` 缺失时就是 `0` → 误判为"不限制"，一个配置遗漏就把并发保护关掉了。**这是本仓库最容易被复刻者写错的地方之一**。

#### 13.2.3 默认值表

| 字段 | 默认值 | 说明 |
|---|---|---|
| `max_concurrency` | `4` | LG 命令并发上限 |
| `command_timeout_seconds` | `12` | 单命令超时（`<= 0` 退回默认） |
| `birdc_path` | `"birdc"` | 裸名，走 `PATH` |
| `ping_path` | `"ping"` | 同上 |
| `traceroute_path` | `"traceroute"` | 同上 |
| `mtr_path` | `"mtr"` | 同上 |
| `wg_path` | `"wg"` | 同上（读状态用） |
| `wg_quick_path` | `"wg-quick"` | 同上（改接口用） |
| `wireguard_peer_dir` | `"/etc/wireguard"` | wg-quick 惯例位置 |
| `bird_peer_dir` | `"/etc/bird/peers"` | BIRD `include` 目录 |
| `bird_peer_group` | `"bird"` | BIRD 守护进程用户所属组 |
| `deploy_reload_cmd` | `""` | 空 = 不执行 reload |

⚠️ **`command_timeout_seconds` 默认 12 秒**（不是 §12.6.2 里提到的 10 秒）。请以本表为准——`defaultTimeoutSeconds = 12`。`traceroute -m 20 -w 2` 的最坏 40 秒仍会超时，结论不变。

**工具路径用裸名而非绝对路径**：systemd 单元里 `Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin` 保证能解析。好处是不同发行版的路径差异（`/bin/ping` vs `/usr/bin/ping`）不用改配置；坏处是**若 `PATH` 被污染，可能执行到恶意同名程序**。root 进程 + 干净 `PATH` 是可接受的取舍；复刻时若追求极致，可以改成绝对路径。

#### 13.2.4 `Load` 的严格解析

```go
func Load(path string) (Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return Config{}, fmt.Errorf("read config %s: %w", path, err)
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	var cfg Config
	if err := decoder.Decode(&cfg); err != nil {
		return Config{}, fmt.Errorf("parse config %s: %w", path, err)
	}
	cfg.applyDefaults()
	return cfg, nil
}
```

**`DisallowUnknownFields()` 是刻意的**：配置文件里出现未知键（拼错 `bird_peer_dir` 成 `bird_peer_dirs`）时直接报错，而不是静默用默认值。**配置文件的静默降级是运维事故的头号来源**。

⚠️ **它没有检查"尾部多余数据"**。`json.Decoder` 只解第一个 JSON 值，后面的内容被忽略。若配置是 `{"name":"a"}{"name":"b"}`，第二个对象被静默丢弃。复刻时若要严格，可以仿照 `decodeCommandPayload` 再 `Decode` 一次并要求 `io.EOF`（见 §13.5.4）。

**`applyDefaults` 只 trim 字符串 + 填默认值**，不校验语义。`wireguard_private_key` 的格式**不在这里校验**（只有公钥在 `main` 里校验）。原因：私钥只在部署含 `{{WIREGUARD_PRIVATE_KEY}}` 占位符的配置时才用到（§13.6.5），不用可以留空。

### 13.3 WSS 客户端（手写 WebSocket）

#### 13.3.1 常量

```go
const (
	defaultReconnectDelay = 5 * time.Second
	heartbeatInterval     = 20 * time.Second
	statusSampleInterval = 60 * time.Second
	maxFramePayload      = 1 << 20
	maxStatusOutput      = 65536
	websocketGUID        = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
)
```

| 常量 | 值 | 作用 |
|---|---|---|
| `defaultReconnectDelay` | 5s | 断线后固定等 5 秒重连（无指数退避） |
| `heartbeatInterval` | 20s | 心跳周期 |
| `statusSampleInterval` | 60s | `wg`/`birdc` 输出重采样周期 |
| `maxFramePayload` | 1 MiB | 单帧上限，超了直接断 |
| `maxStatusOutput` | 64 KiB | 心跳里状态输出截断上限 |
| `websocketGUID` | RFC 6455 固定串 | 计算 `Sec-WebSocket-Accept` |

**心跳 20s vs 状态采样 60s 的设计**：每 20 秒发一次心跳（让后端知道节点活着），但 `wg show` / `birdc` 每 60 秒才真正跑一次。这样：

- 存活检测延迟 ≤ 20 秒（后端用 `last_seen_at` 判断，见 §5.6）；
- 子进程开销降为原来的 1/3。

**若两者相同**，每 20 秒就要 fork 两个进程（`wg` + `birdc`），在低配路由器上是可观的固定开销。**若采样间隔更长**（如 300 秒），首页的"节点状态摘要"会明显滞后。60 秒是折中。

#### 13.3.2 重连循环

```go
func (c *Client) Run(ctx context.Context) {
	if c.cfg.BackendWSURL == "" {
		return
	}
	for {
		if err := c.runOnce(ctx); err != nil && !errors.Is(err, context.Canceled) {
			log.Printf("backend websocket disconnected: %v", err)
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(defaultReconnectDelay):
		}
	}
}
```

**固定 5 秒重连，没有指数退避**。这是刻意的：

- 后端重启后所有节点会在 5 秒内回来，恢复快；
- 节点数量有限（一个部署通常 < 20 个节点），不会形成惊群。

⚠️ **若复刻到大规模场景（> 100 节点），固定 5 秒会造成"后端重启瞬间 100 个连接同时涌入"**。此时应加 jitter（`5s + rand(0..5s)`）和指数退避。原实现不需要，但要知道这个前提。

**`errors.Is(err, context.Canceled)` 不打日志** —— 正常退出（systemd stop）不算错误。

#### 13.3.3 URL 归一化

```go
func (c *Client) endpoint() (string, error) {
	if c.cfg.Name == "" {
		return "", errors.New("name is required when backend_wss_url is set")
	}
	u, err := url.Parse(c.cfg.BackendWSURL)
	if err != nil {
		return "", err
	}
	switch u.Scheme {
	case "https":
		u.Scheme = "wss"
	case "http":
		u.Scheme = "ws"
	case "ws", "wss":
	default:
		return "", fmt.Errorf("backend_wss_url must use ws, wss, http, or https")
	}
	if u.Path == "" || u.Path == "/" {
		u.Path = "/api/nodes/ws"
	}
	q := u.Query()
	if q.Get("name") == "" {
		q.Set("name", c.cfg.Name)
	}
	u.RawQuery = q.Encode()
	return u.String(), nil
}
```

**允许 `http://`/`https://` 是为了配置友好**：运维写 `https://dn42.example.com` 比写 `wss://dn42.example.com/api/nodes/ws` 更不容易错。四种 scheme 都接受，内部归一到 `ws`/`wss`。

**默认路径 `/api/nodes/ws`** —— 只有路径为空或 `/` 时才补。若运维显式写了 `/api/nodes/ws`，保持不变。

**`name` 参数只在缺失时补** —— 允许运维在 URL 里写死 `?name=xxx`（此时配置里的 `name` 只用于日志）。但 `main` 里仍要求 `cfg.Name != ""`，所以两条路都得有名字。

⚠️ **`u.Host` 在 `writeHandshake` 里用作 `Host:` 头**。若 URL 是 `wss://dn42.example.com`，`u.Host` = `dn42.example.com`（无端口）；若显式写了 `:8443`，`Host` 含端口。这与 HTTP/1.1 的 Host 头语义一致（非默认端口必须带端口）。

#### 13.3.4 拨号与 TLS

```go
func dialWebSocket(ctx context.Context, rawURL string, token string) (*wsConn, error) {
	u, err := url.Parse(rawURL)
	if err != nil {
		return nil, err
	}
	address := net.JoinHostPort(u.Hostname(), websocketPort(u))
	dialer := &net.Dialer{Timeout: 10 * time.Second}
	var conn net.Conn
	switch u.Scheme {
	case "wss":
		conn, err = tls.DialWithDialer(
			dialer,
			"tcp",
			address,
			&tls.Config{MinVersion: tls.VersionTLS12, ServerName: u.Hostname()},
		)
	case "ws":
		conn, err = dialer.DialContext(ctx, "tcp", address)
	default:
		err = fmt.Errorf("unsupported websocket scheme %q", u.Scheme)
	}
	...
}
```

| 细节 | 值 | 为什么 |
|---|---|---|
| `net.JoinHostPort(u.Hostname(), websocketPort(u))` | — | `Hostname()` 会**去掉方括号**，`JoinHostPort` 再**加回来**。IPv6 字面量必须这样处理 |
| `dialer.Timeout` | 10s | TCP 建连超时 |
| `tls.Config.MinVersion` | `TLS1.2` | 拒绝 TLS 1.0/1.1 |
| `ServerName` | `u.Hostname()` | SNI + 证书校验的主机名 |
| 证书校验 | **默认开启**（未设 `InsecureSkipVerify`） | 必须如此 |

⚠️ **`tls.DialWithDialer` 不接收 `ctx`**，所以 TLS 握手**不受 `ctx` 取消控制**，只受 `dialer.Timeout`。若后端在 TLS 握手阶段 hang 住，最坏等 10 秒。`ws://` 分支用 `dialer.DialContext(ctx, ...)` 则受 `ctx` 控制。**这个不对称是原实现的现状**，复刻时若要求严格取消，需要自己用 `tls.Client` + `HandshakeContext`。

**没有证书固定（certificate pinning）**。节点信任系统 CA。若后端用自签证书，节点会连不上——这是有意的安全默认（宁可连不上，不要静默接受坏证书）。

#### 13.3.5 握手报文

```go
func writeHandshake(conn net.Conn, u *url.URL, key string, token string) error {
	requestURI := u.RequestURI()
	if requestURI == "" {
		requestURI = "/"
	}
	var buf bytes.Buffer
	fmt.Fprintf(&buf, "GET %s HTTP/1.1\r\n", requestURI)
	fmt.Fprintf(&buf, "Host: %s\r\n", u.Host)
	fmt.Fprintf(&buf, "Upgrade: websocket\r\n")
	fmt.Fprintf(&buf, "Connection: Upgrade\r\n")
	fmt.Fprintf(&buf, "Sec-WebSocket-Key: %s\r\n", key)
	fmt.Fprintf(&buf, "Sec-WebSocket-Version: 13\r\n")
	fmt.Fprintf(&buf, "User-Agent: dn42-autopeer-node\r\n")
	if token != "" {
		fmt.Fprintf(&buf, "Authorization: Bearer %s\r\n", token)
	}
	fmt.Fprintf(&buf, "\r\n")
	_, err := conn.Write(buf.Bytes())
	return err
}
```

**手写 HTTP 请求而不是用 `http.Request.Write`**：后者会自动加 `Accept-Encoding`、`Content-Length: 0` 等，对 WS 升级请求没必要且可能干扰。手写 8 行头更可控。

**`Sec-WebSocket-Key` 生成**：

```go
func websocketKey() (string, error) {
	nonce := make([]byte, 16)
	if _, err := rand.Read(nonce); err != nil {
		return "", err
	}
	return base64.StdEncoding.EncodeToString(nonce), nil
}
```

16 字节随机 → base64（24 字符）。RFC 6455 要求的就是这个。

**`Authorization: Bearer <token>`** —— 与后端 §5.1 的认证一致。`token == ""` 时**不发该头**（后端会因空 token 直接拒绝，见 §13.4.2）。

#### 13.3.6 响应校验

```go
func verifyHandshake(resp *http.Response, key string) error {
	if resp.StatusCode != http.StatusSwitchingProtocols {
		return fmt.Errorf("websocket upgrade failed with HTTP %s", resp.Status)
	}
	if !headerHasToken(resp.Header, "Upgrade", "websocket") {
		return errors.New("websocket upgrade response missing Upgrade: websocket")
	}
	if !headerHasToken(resp.Header, "Connection", "upgrade") {
		return errors.New("websocket upgrade response missing Connection: upgrade")
	}
	if got, want := resp.Header.Get("Sec-WebSocket-Accept"), websocketAccept(key); got != want {
		return errors.New("websocket upgrade response has invalid accept key")
	}
	return nil
}
```

**四项校验**：状态码 101、`Upgrade: websocket`、`Connection: upgrade`、`Sec-WebSocket-Accept` 正确。

```go
func websocketAccept(key string) string {
	sum := sha1.Sum([]byte(key + websocketGUID))
	return base64.StdEncoding.EncodeToString(sum[:])
}
```

**`Sec-WebSocket-Accept` 的计算是 RFC 6455 规定的**：`base64(sha1(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))`。这个校验能防止"连到了一个普通 HTTP 端点却没报错"。

**`headerHasToken` 处理逗号分隔的多值**：

```go
func headerHasToken(header http.Header, key string, token string) bool {
	for _, value := range header.Values(key) {
		for _, part := range strings.Split(value, ",") {
			if strings.EqualFold(strings.TrimSpace(part), token) {
				return true
			}
		}
	}
	return false
}
```

`Connection: keep-alive, Upgrade` 这种值必须能识别出 `Upgrade`。**直接比较整个字符串会失败**。

#### 13.3.7 帧读取

```go
func (c *wsConn) readFrame() (byte, []byte, error) {
	var header [2]byte
	if _, err := io.ReadFull(c.reader, header[:]); err != nil {
		return 0, nil, err
	}
	fin := header[0]&0x80 != 0
	opcode := header[0] & 0x0f
	masked := header[1]&0x80 != 0
	length := uint64(header[1] & 0x7f)
	switch length {
	case 126:
		var extended [2]byte
		if _, err := io.ReadFull(c.reader, extended[:]); err != nil {
			return 0, nil, err
		}
		length = uint64(binary.BigEndian.Uint16(extended[:]))
	case 127:
		var extended [8]byte
		if _, err := io.ReadFull(c.reader, extended[:]); err != nil {
			return 0, nil, err
		}
		length = binary.BigEndian.Uint64(extended[:])
	}
	if !fin {
		return 0, nil, errors.New("fragmented websocket frames are not supported")
	}
	if length > maxFramePayload {
		return 0, nil, errors.New("websocket frame is too large")
	}
	var mask [4]byte
	if masked {
		if _, err := io.ReadFull(c.reader, mask[:]); err != nil {
			return 0, nil, err
		}
	}
	payload := make([]byte, int(length))
	if _, err := io.ReadFull(c.reader, payload); err != nil {
		return 0, nil, err
	}
	if masked {
		for i := range payload {
			payload[i] ^= mask[i%4]
		}
	}
	return opcode, payload, nil
}
```

**帧头解析逐位拆解**：

| 字节 | 位 | 含义 | 本实现 |
|---|---|---|---|
| `header[0]` | `0x80` | FIN（是否最后一片） | 必须为 1，否则报"不支持分片" |
| `header[0]` | `0x70` | RSV1-3 | 忽略（不校验） |
| `header[0]` | `0x0f` | opcode | 1=文本 8=关闭 9=ping 10=pong |
| `header[1]` | `0x80` | MASK（客户端→服务端必须为 1） | 有则解掩码 |
| `header[1]` | `0x7f` | payload 长度或扩展标记 | 126→2 字节，127→8 字节 |

**三个关键约束**：

1. **不支持分片**（`!fin` → 报错）。后端（Starlette/uvicorn）发送小 JSON 时不会分片，所以够用。⚠️ 若某天一个响应超过 WS 单帧实际限制（理论上 1 MiB 以内都 OK），而服务端选择分片，节点会直接断连。
2. **`maxFramePayload = 1 MiB`** —— 在**读长度之后、分配内存之前**检查。这一点**极其重要**：如果先 `make([]byte, length)` 再检查，一个声明 4GB 长的帧会直接 OOM。**这是 WS 实现的经典 DoS 洞**。
3. **`length` 用 `uint64` 累加，最后 `int(length)`** —— 在 32 位平台上 `int(length)` 会溢出，但因为前面已限 1 MiB，实际安全。

⚠️ **没有校验 `masked` 必须为 true**。RFC 6455 规定客户端发给服务端的帧必须掩码，服务端发给客户端的不许掩码。这里**双向都接受掩码与非掩码**——因为节点既当客户端（发给后端）又当"服务端"（读后端发来的帧，实际后端是 WS 服务端，不应掩码）。宽松处理在这里没有安全风险（掩码只是防止缓存投毒，节点不经过代理）。

**`c.reader` 是 `bufio.Reader`** —— 必须复用同一个 reader，因为 `http.ReadResponse` 之后缓冲区里可能已有 WS 帧数据。**重新用 `conn` 读会丢数据**。这是握手实现最常见的 bug：

```go
reader := bufio.NewReader(conn)
resp, err := http.ReadResponse(reader, &http.Request{Method: http.MethodGet})
...
return &wsConn{conn: conn, reader: reader}, nil
```

#### 13.3.8 帧写入

```go
func (c *wsConn) writeFrame(opcode byte, payload []byte) error {
	c.writeMu.Lock()
	defer c.writeMu.Unlock()

	var buf bytes.Buffer
	buf.WriteByte(0x80 | opcode)
	length := len(payload)
	switch {
	case length < 126:
		buf.WriteByte(0x80 | byte(length))
	case length <= 65535:
		buf.WriteByte(0x80 | 126)
		var extended [2]byte
		binary.BigEndian.PutUint16(extended[:], uint16(length))
		buf.Write(extended[:])
	default:
		buf.WriteByte(0x80 | 127)
		var extended [8]byte
		binary.BigEndian.PutUint64(extended[:], uint64(length))
		buf.Write(extended[:])
	}
	var mask [4]byte
	if _, err := rand.Read(mask[:]); err != nil {
		return err
	}
	buf.Write(mask[:])
	for i, b := range payload {
		buf.WriteByte(b ^ mask[i%4])
	}
	_, err := c.conn.Write(buf.Bytes())
	return err
}
```

**四个要点**：

1. **`0x80 | opcode`** —— FIN 恒为 1（不分片）。
2. **`0x80 | length`** —— MASK 位恒为 1。**客户端发帧必须掩码**，否则严格的服务端会断连。
3. **长度编码**：`< 126` 用 7 位；`126..65535` 用 `126` + 2 字节；`> 65535` 用 `127` + 8 字节。**边界条件容易写错**：`length == 126` 必须走扩展分支（7 位只能表示 0–125）。
4. **`writeMu` 保护整帧写入** —— 因为 `handleRequest` 是 `go c.handleRequest(...)` 启动的（§13.3.10），多个响应会并发写同一个连接。**不加锁会导致帧交错，后端收到乱码**。

**掩码是逐字节 `payload[i] ^ mask[i%4]`** —— 这就是 RFC 6455 的算法，没有别的花样。

**整个帧在内存里拼好再 `Write` 一次** —— 避免多次 `Write` 导致 TCP 分段（虽然语义上 WebSocket 不依赖分段，但一次写完更简单）。

#### 13.3.9 `ReadJSON` 的 opcode 分发

```go
func (c *wsConn) ReadJSON(dst any) error {
	for {
		opcode, payload, err := c.readFrame()
		if err != nil {
			return err
		}
		switch opcode {
		case 1:
			return json.Unmarshal(payload, dst)
		case 8:
			_ = c.writeFrame(8, nil)
			return io.EOF
		case 9:
			_ = c.writeFrame(10, payload)
		case 10:
			continue
		default:
			return fmt.Errorf("unsupported websocket opcode %d", opcode)
		}
	}
}
```

| opcode | 处理 | 说明 |
|---|---|---|
| 1（文本） | `json.Unmarshal` 后返回 | 正常业务帧 |
| 8（关闭） | 回一个空 close 帧，返回 `io.EOF` | `io.EOF` 让上层走"正常断开"路径 |
| 9（ping） | 回 pong（opcode 10）带原 payload | RFC 要求 pong 带回 ping 的 payload |
| 10（pong） | `continue`（丢弃） | 不需要 pong 内容 |
| 2（二进制） | **报错** | 协议只用文本 JSON |
| 其他 | **报错** | — |

⚠️ **opcode 2（二进制）不处理**。若后端某天用二进制帧发 JSON，节点会断连。原实现两边都是文本帧，所以没问题。

⚠️ **返回 `io.EOF` 而非 `nil`** —— `runOnce` 的 `conn.ReadJSON(&req)` 拿到 `io.EOF` 会走 `return err` → 触发重连。若返回 `nil`，`req` 是零值，会被 `if req.Type != "request"` 跳过，然后**死循环读（永远阻塞）**其实也还好，但语义混乱。

#### 13.3.10 主循环与并发处理

```go
func (c *Client) runOnce(ctx context.Context) error {
	endpoint, err := c.endpoint()
	if err != nil {
		return err
	}
	conn, err := dialWebSocket(ctx, endpoint, c.cfg.Token)
	if err != nil {
		return err
	}
	defer conn.Close()
	log.Printf("connected to backend websocket %s", endpoint)

	if err := conn.WriteJSON(c.heartbeat("hello")); err != nil {
		return err
	}

	heartbeatErr := make(chan error, 1)
	go c.heartbeatLoop(ctx, conn, heartbeatErr)

	for {
		select {
		case err := <-heartbeatErr:
			return err
		default:
		}
		var req requestEnvelope
		if err := conn.ReadJSON(&req); err != nil {
			return err
		}
		if req.Type != "request" || req.ID == "" {
			continue
		}
		go c.handleRequest(conn, req)
	}
}
```

**`hello` 是连接后的第一条消息**，`Type="hello"`，负载与心跳相同（含 `public_key` 与 `system`）。后端靠它把连接与节点绑定（见 §5.1）。

**主循环是"读请求 → 派发 goroutine"**：

```go
go c.handleRequest(conn, req)
```

⚠️ **这是"每个请求一个 goroutine"的无界并发模型**。真正的并发保护在**下游**：

- LG 命令 → `api.Server` 的信号量（`max_concurrency`）；
- `peers.deploy`/`peers.remove` → `deployMu` 串行；
- 其他（`pubkey`）→ 瞬时完成。

**如果没有这两层保护，一个后端 bug 或恶意节点就能 fork 出无数进程**。复刻时**不要**把 `go` 去掉改成串行——那会让一个慢查询阻塞所有请求（包括心跳响应）。保持"goroutine 无界 + 下游限流"是正确结构。

**`heartbeatErr` 是 `chan error` 容量 1**：

- 心跳写失败 → `errs <- err` → 主循环 select 到 → `return err` → 重连；
- 容量 1 保证心跳 goroutine **不会因为主循环没在读而永远阻塞**（如果容量 0，且主循环正好阻塞在 `ReadJSON`，心跳 goroutine 会泄漏）。

⚠️ **主循环的 `select` 是 `default` 分支**，所以每轮读之前**非阻塞地**检查一次心跳错误。这意味着：若主循环正阻塞在 `conn.ReadJSON`，心跳失败**不会立即**被感知——要等下一条请求或连接断开。

**为什么不会卡死**：心跳写失败通常意味着连接已断，`ReadJSON` 也会很快返回错误。所以这个"延迟感知"在实践中不构成问题。

⚠️ **`defer conn.Close()` 会发 close 帧** —— 若连接已断，`writeFrame` 失败被忽略（`_ = c.writeFrame(8, nil)`）。这是对的：清理路径不能因为发不出 close 帧而 panic。

#### 13.3.11 请求处理

```go
func (c *Client) handleRequest(conn *wsConn, req requestEnvelope) {
	result, err := c.server.Command(req.Command, req.Payload)
	resp := responseEnvelope{Type: "response", ID: req.ID, Result: result}
	if err != nil {
		resp.Result = nil
		resp.Error = err.Error()
	}
	if err := conn.WriteJSON(resp); err != nil {
		log.Printf("write websocket response failed: %v", err)
	}
}
```

**`ID` 原样回传** —— 后端用 `asyncio.Future` 按 `id` 匹配（见 §5.2）。**丢失或改写 ID 会导致后端请求超时**。

**错误走 `Error` 字段，`Result` 置 nil** —— 与后端的 `response` 信封约定一致（§5.2）。

⚠️ **`err.Error()` 会原样发给后端**。`decodeCommandPayload` 的错误是固定的 `"invalid json"`，`Command` 的 default 分支是 `unknown command %q`——**都不含内部细节**。但若将来新增一个直接返回 `err.Error()`（如 `os` 错误），可能泄漏服务器路径。**新增命令时必须审查错误文案**。

#### 13.3.12 心跳循环

```go
func (c *Client) heartbeatLoop(ctx context.Context, conn *wsConn, errs chan<- error) {
	ticker := time.NewTicker(heartbeatInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			_ = conn.Close()
			errs <- ctx.Err()
			return
		case <-ticker.C:
			if err := conn.WriteJSON(c.heartbeat("heartbeat")); err != nil {
				_ = conn.Close()
				errs <- err
				return
			}
		}
	}
}
```

**心跳与主循环共用同一个 `conn`**，靠 `writeMu` 保证不交错。

**`ctx.Done()` 时主动 `conn.Close()`** —— 让阻塞在 `ReadJSON` 的主循环立即返回。

**`errs` 只写一次然后 return** —— goroutine 正常退出，不泄漏。

⚠️ **`errs <- ctx.Err()` 在 `ctx` 取消时执行**。若主循环已经因为读错误返回，`errs` 可能没人读——但容量 1 保证不阻塞。**容量 1 在这里是必需的**。

### 13.4 命令分发（`internal/api`）

#### 13.4.1 `Server` 结构

```go
type Server struct {
	Runner   runner.Runner
	sem      chan struct{}
	deployMu sync.Mutex
}

func New(r runner.Runner, maxConcurrency int) *Server {
	s := &Server{Runner: r}
	if maxConcurrency > 0 {
		s.sem = make(chan struct{}, maxConcurrency)
	}
	return s
}
```

**`maxConcurrency <= 0` → `sem` 为 nil（不限制）**。这与 `Config.Concurrency()` 的语义衔接：显式 `0` 表示"不限制"。

**`deployMu` 是普通互斥锁，不是信号量** —— 部署必须**完全串行**（一次一个），因为两次并发 `wg-quick up` 会争抢接口名与路由表。**没有并发部署的正当理由**。

#### 13.4.2 八命令分发

```go
func (s *Server) Command(command string, payload json.RawMessage) (any, error) {
	switch command {
	case "pubkey":
		return pubkeyResponse{PublicKey: s.Runner.WireGuardPubKey}, nil
	case "lg.ping":
		return s.targetCommand(payload, s.Runner.Ping)
	case "lg.trace":
		return s.targetCommand(payload, s.Runner.Trace)
	case "lg.mtr":
		return s.targetCommand(payload, s.Runner.Mtr)
	case "lg.route":
		return s.targetCommand(payload, s.Runner.Route)
	case "peers.status":
		var req peerStatusRequest
		if err := decodeCommandPayload(payload, &req); err != nil {
			return nil, err
		}
		return s.limitedPeerStatus(req.ProtocolName), nil
	case "peers.deploy":
		var req runner.DeployRequest
		if err := decodeCommandPayload(payload, &req); err != nil {
			return nil, err
		}
		return s.deployPeer(req), nil
	case "peers.remove":
		var req runner.RemoveRequest
		if err := decodeCommandPayload(payload, &req); err != nil {
			return nil, err
		}
		return s.removePeer(req), nil
	default:
		return nil, fmt.Errorf("unknown command %q", command)
	}
}
```

**`pubkey` 不起进程** —— 直接返回配置里的 `WireGuardPublicKey`。这是**最高频的命令**（每次新建节点、每次刷新公钥），必须零开销。

**`unknown command %q`** —— `%q` 会把命令名加引号，防止命令名里的特殊字符干扰日志。**但也会把用户（后端）提供的字符串原样放进错误里**，若命令名超长会撑大日志。当前后端只发固定 8 个命令，无风险。

#### 13.4.3 非阻塞信号量

```go
func (s *Server) tryAcquire() (func(), bool) {
	if s.sem == nil {
		return func() {}, true
	}
	select {
	case s.sem <- struct{}{}:
		return func() { <-s.sem }, true
	default:
		return nil, false
	}
}
```

**`select` + `default` = 非阻塞获取**。拿不到立即返回 `false`，**不排队等待**。

**为什么不等**：LG 是公开的，若允许排队，100 个请求会各自占着一个 WS 请求的 goroutine 等 12 秒，内存与延迟都爆炸。**立即返回"节点忙"是最优解**。

**`s.sem == nil` 返回 `func(){}` 空释放函数** —— 让调用方可以无条件 `defer release()`，不用判空。

⚠️ **`release` 是闭包捕获 `s.sem`**。若在 `defer` 里执行两次会 panic（从空 channel 接收会阻塞，但 `<-s.sem` 在已空时会阻塞而非 panic——**实际上会死锁**）。**必须保证 `release()` 只调用一次**，`defer` 天然保证。

#### 13.4.4 忙与限流的统一返回值

```go
func (s *Server) limitedResult(fn func() runner.Result) runner.Result {
	release, ok := s.tryAcquire()
	if !ok {
		return runner.Result{OK: false, Output: "node is busy, try again shortly"}
	}
	defer release()
	return fn()
}
```

**"忙"用 `OK: false` + 固定文案表达，而不是抛错**。原因：

- 抛错会走 `response.Error`，后端 `NodeRequestError` 的语义是"节点异常"，会触发告警；
- "忙"是**正常状态**，应该像一次失败的查询那样展示给用户。

⚠️ **`defer release()` 在 `return fn()` 之后执行** —— Go 的 `defer` 在函数返回前执行，所以 `fn()` 的返回值先算出，再 `release`，再真正返回。顺序正确。

#### 13.4.5 部署串行化

```go
func (s *Server) deployPeer(req runner.DeployRequest) runner.DeployResult {
	s.deployMu.Lock()
	defer s.deployMu.Unlock()
	return s.Runner.DeployPeer(req)
}

func (s *Server) removePeer(req runner.RemoveRequest) runner.DeployResult {
	s.deployMu.Lock()
	defer s.deployMu.Unlock()
	return s.Runner.RemovePeer(req)
}
```

**deploy 与 remove 共用同一把锁** —— 因为两者都会操作同一个 `.conf` 文件与同一个接口。**若分开两把锁，deploy A 与 remove A 并发会互相踩**。

⚠️ **部署不受 `sem` 限制**。这是有意的：`sem` 只保护 LG（高频、公开）；部署是低频、需要授权的高价值操作，且已被 `deployMu` 串行化。**若把部署也放进 `sem`，一个卡住的 `wg-quick` 会永久占住一个 LG 槽位**。

#### 13.4.6 `targetCommand`

```go
func (s *Server) targetCommand(
	payload json.RawMessage,
	fn func(string) runner.Result,
) (runner.Result, error) {
	var req lgRequest
	if err := decodeCommandPayload(payload, &req); err != nil {
		return runner.Result{}, err
	}
	return s.limitedResult(func() runner.Result { return fn(strings.TrimSpace(req.Target)) }), nil
}
```

**`strings.TrimSpace(req.Target)`** —— 后端已经 `strip` 过，这里再 strip 是纵深防御。

**`fn` 是方法值** —— `s.Runner.Ping` 的类型是 `func(string) runner.Result`，直接传。

#### 13.4.7 严格 JSON 解码

```go
func decodeCommandPayload(payload json.RawMessage, dst any) error {
	if trimmed := bytes.TrimSpace(payload); len(trimmed) == 0 || bytes.Equal(trimmed, []byte("null")) {
		payload = []byte("{}")
	}
	decoder := json.NewDecoder(bytes.NewReader(payload))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(dst); err != nil {
		return errors.New("invalid json")
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return errors.New("invalid json")
	}
	return nil
}
```

**三层严格性**：

1. **空 / `null` → `{}`** —— 允许无 payload 的命令（虽然当前 8 个命令都有 payload；`pubkey` 不走这个函数）。`json.RawMessage` 缺失时是 `nil`，`len(nil) == 0`。
2. **`DisallowUnknownFields()`** —— 后端多发一个字段直接报错。防止"我以为这个字段生效了但实际被忽略"。
3. **第二次 `Decode` 必须返回 `io.EOF`** —— 拒绝尾部多余数据（`{"a":1}garbage` 或 `{"a":1}{"b":2}`）。

⚠️ **错误文案统一是 `"invalid json"`**，不区分"字段未知"与"语法错误"。这是**有意的**：后端不需要知道细节，且避免把 Go 的 JSON 错误消息（含字段名）传给后端。调试时只能看节点日志——但 `decodeCommandPayload` **不记日志**。这是排障的一个盲点（见 §18 改进建议）。

⚠️ **`decoder.Decode(&struct{}{})` 的写法** —— 用匿名空结构体接收第二次解码。若尾部是 `{}`，会成功（返回 nil）→ `!errors.Is(nil, io.EOF)` 为真 → 报错。正确。

#### 13.4.8 `peerStatus` 的两段拼接

```go
type peerStatusResponse struct {
	OK        bool   `json:"ok"`
	Output    string `json:"output"`
	WireGuard string `json:"wireguard"`
}

func (s *Server) peerStatusForProtocol(protocolName string) peerStatusResponse {
	bird := s.Runner.PeerStatus(protocolName)
	wg := s.Runner.PeerWireGuard(protocolName)
	return peerStatusResponse{OK: bird.OK, Output: bird.Output, WireGuard: wg.Output}
}
```

**`OK` 只反映 BIRD 的成功与否**，WireGuard 的输出放在独立字段 `WireGuard`。原因：

- 隧道未起时 `wg show` 会以非零退出（`No such device`），但那是**有用的状态**，不该让整个请求 `ok=false`；
- 门户/管理页需要分别展示"BGP 状态"与"隧道状态"，合并成一个 `Output` 会丢失结构。

⚠️ **`WireGuard` 字段只传 `Output`，不传 `wg.OK`**。所以后端无法区分"wg 命令失败"与"隧道不存在"——两者都是输出文本，交给 `summarize_wireguard` 用文本判断（`No such device` → `interface down`）。**这是文本耦合**：若 `wg` 版本的错误消息变了（例如改成 `Unable to access interface`，`summarize_wireguard` 里已兼容），摘要会退化。

### 13.5 Runner：外部命令执行

#### 13.5.1 `run` 的统一封装

（完整代码见 §12.6.5。）关键点回顾：

- `context.WithTimeout(r.Timeout)` 给每个命令设上限；
- `CombinedOutput()` 合并 stdout + stderr；
- 超时保留已产生的输出；
- 所有命令都以**固定 argv** 调用，`exec.CommandContext(ctx, args[0], args[1:]...)`，**不经 shell**。

⚠️ **`r.Timeout` 对所有命令生效，包括 `wg-quick`**。`wg-quick up` 在慢速接口上可能要 2–3 秒，12 秒够用。但 `DeployPeer` 里连续调用了 `wg-quick down` + `wg-quick up` + `deploy_reload_cmd`，**每个都各自 12 秒**，总耗时最坏 36 秒。而后端 `request_node_sync` 的部署超时是 **20 秒**（见 §7.6）。**这可能导致后端先超时、节点仍在部署**。

这是**已知的时序鸿沟**：

| 层 | 超时 |
|---|---|
| 后端 `deploy_peer` → `request_node_sync` | 20s（§7.6 `deploy_peer`） |
| 节点 `wg-quick down` | 12s |
| 节点 `wg-quick up` | 12s |
| 节点 `deploy_reload_cmd`（如 `birdc configure`） | 12s |
| **节点侧最坏总计** | **36s** |

后端超时后会把 `deploy_status` 置为 `failed`，但节点可能稍后部署成功。**复刻时必须保证 `request_node_sync` 的超时 ≥ `3 × command_timeout_seconds`**，或让节点把整体部署也包在一个总 deadline 里。

#### 13.5.2 `safeNameRE` 的应用面

```go
safeNameRE = regexp.MustCompile(`^[A-Za-z0-9_][A-Za-z0-9_-]{0,79}$`)
```

**用在三处**：

| 用途 | 位置 | 不校验的后果 |
|---|---|---|
| `birdc show protocols all <name>` | `PeerStatus` | 名称含空格/`-` 开头 → 参数注入 birdc，或 birdc 报错 |
| `wg show <iface>` | `PeerWireGuard` | 同上 |
| 文件名 `<name>.conf` | `DeployPeer` / `RemovePeer` | 路径穿越（`../../etc/passwd`） |

**正则语义**：

| 部分 | 含义 |
|---|---|
| `[A-Za-z0-9_]` | 首字符：字母/数字/**下划线**（不许 `-`，避免被当成选项） |
| `[A-Za-z0-9_-]{0,79}` | 其余 0–79 字符 |
| 总长 | 1–80 |

**80 字符上限** 远低于 Linux `IFNAMSIZ`（15），但这里的 name 不只是接口名——它是"协议名 + 文件名前缀"。实际生成的名字是 `DN42_<4位>_<4位>`（14 字符），80 是宽松上限。**接口名本身的 15 字符限制由后端 `peer_protocol_name` 保证**（§7.4），不是这里。

⚠️ **`safeNameRE` 允许 `_` 在首位**，但**不允许 `-` 在首位**。这挡住了 `--help` 这类被当作选项的参数。

#### 13.5.3 `DeployPeer` 完整流程

```go
func (r Runner) DeployPeer(req DeployRequest) DeployResult {
	req.ASN = strings.TrimSpace(req.ASN)
	req.Node = strings.TrimSpace(req.Node)
	req.ProtocolName = strings.TrimSpace(req.ProtocolName)
	req.WireGuardConfig = strings.TrimSpace(req.WireGuardConfig)
	req.BirdConfig = strings.TrimSpace(req.BirdConfig)
	if err := validateDeployRequest(req); err != nil {
		return DeployResult{OK: false, Applied: false, Output: err.Error()}
	}

	files := []string{
		filepath.Join(r.WireGuardPeerDir, req.ProtocolName+".conf"),
		filepath.Join(r.BirdPeerDir, req.ProtocolName+".conf"),
	}
	wireGuardConfig, err := r.renderWireGuardConfig(req.WireGuardConfig)
	if err != nil {
		return DeployResult{OK: false, Output: err.Error(), Files: files}
	}

	if err := ensureChildPath(r.WireGuardPeerDir, files[0]); err != nil {
		return DeployResult{OK: false, Output: err.Error()}
	}
	if err := ensureChildPath(r.BirdPeerDir, files[1]); err != nil {
		return DeployResult{OK: false, Output: err.Error()}
	}
	if err := writeConfigFile(files[0], wireGuardConfig+"\n"); err != nil {
		return DeployResult{OK: false, Output: err.Error(), Files: files}
	}
	if err := writeConfigFile(files[1], req.BirdConfig+"\n"); err != nil {
		return DeployResult{OK: false, Output: err.Error(), Files: files}
	}
	if err := chownToGroup(r.BirdPeerDir, r.BirdPeerGroup); err != nil {
		return DeployResult{OK: false, Output: err.Error(), Files: files}
	}
	if err := chownToGroup(files[1], r.BirdPeerGroup); err != nil {
		return DeployResult{OK: false, Output: err.Error(), Files: files}
	}

	output := "deployed peer config"
	down := r.run(r.WgQuickPath, "down", files[0])
	if down.Output != "" {
		output = strings.TrimSpace(output + "\nwg-quick down:\n" + down.Output)
	}
	up := r.run(r.WgQuickPath, "up", files[0])
	output = strings.TrimSpace(output + "\nwg-quick up:\n" + up.Output)
	if !up.OK {
		return DeployResult{OK: false, Applied: true, Output: output, Files: files}
	}
	if r.DeployReloadCmd != "" {
		reload := r.run(strings.Fields(r.DeployReloadCmd)...)
		output = strings.TrimSpace(output + "\n" + reload.Output)
		if !reload.OK {
			return DeployResult{OK: false, Applied: true, Output: output, Files: files}
		}
	}
	return DeployResult{OK: true, Applied: true, Output: output, Files: files}
}
```

**执行顺序与每一步的失败语义**：

| 步 | 动作 | 失败时 `OK` | 失败时 `Applied` | 含义 |
|---|---|---|---|---|
| 1 | `validateDeployRequest` | false | **false** | 参数非法，什么都没做 |
| 2 | `renderWireGuardConfig`（替换私钥占位符） | false | **false** | 缺私钥，什么都没写 |
| 3 | `ensureChildPath` ×2 | false | **false** | 路径穿越，什么都没写 |
| 4 | `writeConfigFile` WG | false | **false** | 写文件失败（第一条还没写成功） |
| 5 | `writeConfigFile` BIRD | false | **false** | **⚠️ WG 已写、BIRD 未写 → 半成品状态** |
| 6 | `chownToGroup` ×2 | false | **false** | 同上，半成品 |
| 7 | `wg-quick down`（失败**不中止**） | — | — | down 失败是常态（接口本来就没起） |
| 8 | `wg-quick up` | false | **true** | 文件已写、接口没起 |
| 9 | `deploy_reload_cmd` | false | **true** | 文件已写、接口起了、BIRD 没 reload |

⚠️ **第 5/6 步的 `Applied: false` 是不准确的**。此时 WG 文件可能已写入磁盘。但 `Applied` 的语义是"**接口已生效**"，文件落盘不算。后端 `apply_deploy_result` 只看 `OK`（§7.10），所以实际影响有限——但若运维靠 `Applied` 判断"要不要清理残留文件"，会误判。

**`Applied` 的真正含义**：`wg-quick up` 至少在尝试之后才可能为 `true`。所以：

- `Applied: false` → **接口状态未改变**（可能留了文件）；
- `Applied: true` → **接口状态可能已改变**（up 执行过）。

⚠️ **`wg-quick down` 的失败被完全忽略**（只把输出拼进 `output`）。这是对的：首次部署时接口不存在，`down` 必然失败。但如果 `down` 失败是因为**接口被别的进程占着**，随后的 `up` 也会失败——错误会体现在第 8 步。

**`writeConfigFile` 先写 WG 再写 BIRD** —— 顺序不是随意的：WG 文件含私钥，写失败的概率（权限/磁盘）应在 BIRD 之前暴露。**但实际上这个顺序也有问题**：若 BIRD 写失败，WG 文件留着，`wg-quick` 未被调用（接口未起），是一个"孤儿文件"。`RemovePeer` 可以清理它。

#### 13.5.4 `validateDeployRequest`

```go
func validateDeployRequest(req DeployRequest) error {
	if req.RequestID == "" {
		return errors.New("request_id is required")
	}
	if req.ASN == "" || len(req.ASN) > 32 || hasUnsafeTargetChar(req.ASN) {
		return errors.New("invalid asn")
	}
	if req.Node == "" || len(req.Node) > 64 || strings.ContainsAny(req.Node, "/\\") {
		return errors.New("invalid node")
	}
	if !safeNameRE.MatchString(req.ProtocolName) {
		return errors.New("invalid protocol_name")
	}
	if err := validateConfigSnippet("wireguard_config", req.WireGuardConfig); err != nil {
		return err
	}
	if err := validateConfigSnippet("bird_config", req.BirdConfig); err != nil {
		return err
	}
	return nil
}

func validateConfigSnippet(name string, value string) error {
	if value == "" {
		return fmt.Errorf("%s is required", name)
	}
	if len(value) > 16*1024 {
		return fmt.Errorf("%s is too large", name)
	}
	if strings.ContainsRune(value, '\x00') {
		return fmt.Errorf("%s contains invalid data", name)
	}
	return nil
}
```

| 字段 | 校验 | 为什么 |
|---|---|---|
| `request_id` | 非空 | 幂等性线索；后端用它关联部署 |
| `asn` | 非空、≤32、无危险字符 | 仅用于日志/审计，不参与文件名，但仍拒注入 |
| `node` | 非空、≤64、不含 `/` `\` | 同上；不含路径分隔符 |
| `protocol_name` | `safeNameRE` | **直接成为文件名** |
| `wireguard_config` | 非空、≤16 KiB、无 NUL | 防止空文件与超大文件 |
| `bird_config` | 同上 | 同上 |

**`node` 字段在节点侧几乎无用** —— 它只是请求里的元数据（后端传的节点名）。但仍做校验，因为**它会被写进日志**（若将来加日志）。**纵深防御的原则是"每个进入信任边界的字符串都要校验"，而不是"反正不用"**。

⚠️ **配置片段只做"大小 + NUL"检查，不做内容解析**。这意味着**后端生成的 BIRD 配置语法错误会原样写入文件**，然后 `birdc configure` 失败 → `Applied: true, OK: false`。这是有意的：节点不该理解 BIRD 语法（那是后端 `render_bird_peer_config` 的职责），否则两处语法逻辑会漂移。

#### 13.5.5 私钥占位符替换

```go
func (r Runner) renderWireGuardConfig(config string) (string, error) {
	const placeholder = "{{WIREGUARD_PRIVATE_KEY}}"
	if strings.Contains(config, placeholder) {
		if r.WireGuardKey == "" {
			return "", errors.New("wireguard_private_key is required in the node service config for WireGuard deployment")
		}
		return strings.ReplaceAll(config, placeholder, r.WireGuardKey), nil
	}
	return config, nil
}
```

**私钥永不出节点** —— 后端渲染的 WG 配置里只有占位符（§7.3），真正的私钥由节点在写盘前替换。这是本架构**最重要的安全属性之一**：即使后端数据库被拖库，攻击者也拿不到任何节点的 WG 私钥。

**只在 `strings.Contains` 时才要求私钥** —— 兼容"配置里已写死私钥"的场景（不推荐，但允许）。

⚠️ **`strings.ReplaceAll` 会替换所有出现** —— 若配置里有多处占位符（正常，一个文件只有一个 `PrivateKey`），全部替换。**不会**替换成 `$` 或 `\` 的特殊含义（Go 的 `ReplaceAll` 不做正则解释）。

#### 13.5.6 路径穿越防护

```go
func ensureChildPath(parent string, child string) error {
	parentAbs, err := filepath.Abs(parent)
	if err != nil {
		return err
	}
	childAbs, err := filepath.Abs(child)
	if err != nil {
		return err
	}
	rel, err := filepath.Rel(parentAbs, childAbs)
	if err != nil {
		return err
	}
	if rel == "." || strings.HasPrefix(rel, ".."+string(os.PathSeparator)) || rel == ".." {
		return fmt.Errorf("refusing to write outside %s", parentAbs)
	}
	return nil
}
```

**用 `filepath.Rel` 而非字符串前缀比较** —— 这是正确写法。字符串比较 `strings.HasPrefix(childAbs, parentAbs)` 会把 `/etc/wireguard-evil/x.conf` 误判为 `/etc/wireguard` 的子路径（前缀相同）。

**三种拒绝**：`rel == "."`（就是目录本身）、`rel` 以 `../` 开头（逃逸）、`rel == ".."`（父目录）。

⚠️ **`ensureChildPath` 不防符号链接攻击**。若 `/etc/wireguard` 下有指向 `/etc/shadow` 的符号链接，`filepath.Abs` 不会解析它（`Abs` 只做词法归一化，`EvalSymlinks` 才解析）。**但攻击者需要先在节点上以 root 创建符号链接**——那时已经 root 了。所以这个缺口在实践中不可利用。**若复刻到多租户场景，必须改用 `EvalSymlinks` + 二次比较**。

⚠️ **`safeNameRE` 已经排除了 `/` 与 `..`**，所以 `protocol_name` 本身无法穿越。`ensureChildPath` 是**纵深防御**——万一将来放宽了 `safeNameRE`，这一层还能兜住。

#### 13.5.7 原子写

```go
func writeConfigFile(path string, content string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0750); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".autopeer-*.tmp")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)
	if _, err := tmp.WriteString(content); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Chmod(0640); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmpName, path)
}
```

**为什么必须原子写**：

- BIRD 会周期性扫描 `include` 目录。若配置写了一半被读到，`birdc configure` 会因语法错误失败。
- `wg-quick` 读取 `.conf` 时若文件不完整，会创建错误的接口。

**`os.CreateTemp` 在同目录创建临时文件** —— 同目录保证 `os.Rename` 是**同文件系统的原子操作**。跨文件系统 `rename` 会退化为"复制 + 删除"，不原子。

**权限 0640** —— 属主 root 读写，属组读。WG 文件也 0640（属组是 root，因为不 chown），所以**只有 root 能读**。

⚠️ **`os.CreateTemp` 默认权限是 0600**，然后 `Chmod(0640)`。**这个顺序是对的**：先创建为最严格，再放宽。反过来（先 0640 再降）会有短暂窗口。

⚠️ **`defer os.Remove(tmpName)` 在 `Rename` 成功后是空操作**（文件已不在原名）。这是安全的写法，保证失败路径清理临时文件。

⚠️ **没有 `fsync`**。断电时可能丢内容。对配置文件这类可重建的数据，可接受。若要求强持久化，需 `tmp.Sync()` + 目录 `fsync`。

#### 13.5.8 组权限修正

```go
func chownToGroup(path string, group string) error {
	if group == "" {
		return nil
	}
	g, err := user.LookupGroup(group)
	if err != nil {
		return fmt.Errorf("bird_peer_group %q not found: %w", group, err)
	}
	gid, err := strconv.Atoi(g.Gid)
	if err != nil {
		return fmt.Errorf("bird_peer_group %q has invalid gid %q: %w", group, g.Gid, err)
	}
	if err := os.Chown(path, -1, gid); err != nil {
		return fmt.Errorf("set group %q on %s: %w", group, path, err)
	}
	return nil
}
```

**`os.Chown(path, -1, gid)`** —— 用户属主传 `-1` 表示"不改"，只改组。**这是 GO 的约定**（`chown(2)` 的 uid=-1）。

**为什么需要**：node service 以 root 写文件，属主是 root；BIRD 以 `bird` 用户跑，读不了 root 的文件（0640 + root:root）。把组改成 `bird` 后，`bird` 用户能读（组权限是 4）。

**为什么不直接把文件权限放宽成 0644**：那样任何用户都能读 BIRD 配置（含对端公钥、内部 IP 规划）。**改组的权限暴露面最小**。

**`group == ""` 直接返回** —— 对应 `bird_peer_group` 显式设为 `""` 的配置（BIRD 以 root 跑，或用 setgid 目录）。

⚠️ **`user.LookupGroup` 失败是硬错误**（不是 warning）。这是刻意的：配置写错组名应在部署时立即暴露，而不是留到几小时后 `birdc configure` 报 `Permission denied` 才发现。**错误消息里带上了 group 名与原因**，便于定位。

⚠️ **`chownToGroup(r.BirdPeerDir, ...)` 会改变整个目录的组**，不只是新文件。这是有意的：目录本身若是 root:root 0750，`bird` 用户无法进入，即使文件是 bird:bird 也读不到。

### 13.6 `RemovePeer`

```go
func (r Runner) RemovePeer(req RemoveRequest) DeployResult {
	req.ProtocolName = strings.TrimSpace(req.ProtocolName)
	if req.RequestID == "" {
		return DeployResult{OK: false, Output: "request_id is required"}
	}
	if !safeNameRE.MatchString(req.ProtocolName) {
		return DeployResult{OK: false, Output: "invalid protocol_name"}
	}

	files := []string{
		filepath.Join(r.WireGuardPeerDir, req.ProtocolName+".conf"),
		filepath.Join(r.BirdPeerDir, req.ProtocolName+".conf"),
	}
	if err := ensureChildPath(r.WireGuardPeerDir, files[0]); err != nil {
		return DeployResult{OK: false, Output: err.Error()}
	}
	if err := ensureChildPath(r.BirdPeerDir, files[1]); err != nil {
		return DeployResult{OK: false, Output: err.Error()}
	}

	output := "removed peer config"
	if _, err := os.Stat(files[0]); err == nil {
		down := r.run(r.WgQuickPath, "down", files[0])
		if down.Output != "" {
			output = strings.TrimSpace(output + "\nwg-quick down:\n" + down.Output)
		}
	}
	for _, file := range files {
		if err := os.Remove(file); err != nil && !errors.Is(err, os.ErrNotExist) {
			return DeployResult{OK: false, Applied: true, Output: strings.TrimSpace(output + "\n" + err.Error()), Files: files}
		}
	}
	if r.DeployReloadCmd != "" {
		reload := r.run(strings.Fields(r.DeployReloadCmd)...)
		output = strings.TrimSpace(output + "\n" + reload.Output)
		if !reload.OK {
			return DeployResult{OK: false, Applied: true, Output: output, Files: files}
		}
	}
	return DeployResult{OK: true, Applied: true, Output: output, Files: files}
}
```

**与 `DeployPeer` 的关键差异**：

| 项 | `DeployPeer` | `RemovePeer` |
|---|---|---|
| `os.Stat` 前置检查 | 无 | **有**（只有 `.conf` 存在才 `wg-quick down`） |
| `wg-quick down` 失败 | 忽略 | 忽略 |
| 文件删除 | 覆盖写 | `os.Remove`，`IsNotExist` 视为成功 |
| `deploy_reload_cmd` | 执行 | 执行 |
| `Applied` 初值 | false | **true**（从删文件开始就认为"已生效"） |

**为什么 remove 要先 `os.Stat`**：若文件已不存在，`wg-quick down /etc/wireguard/X.conf` 会因为文件不存在而报错，产生噪音输出。**`DeployPeer` 不需要这个检查**，因为那时文件刚写完，必然存在。

⚠️ **`RemovePeer` 的 `Applied: true` 从第一次删文件成功就开始**。若删 WG 成功、删 BIRD 失败，返回 `OK: false, Applied: true`——**部分删除**。此时接口可能还在（`wg-quick down` 已执行），BIRD 配置残留在磁盘。

⚠️ **`wg-quick down` 传的是**
```
r.run(r.WgQuickPath, "down", files[0])
```

—— 注意是**文件路径**而非接口名。`wg-quick` 接受文件名，并从中推导接口名（basename 去 `.conf`）。这与 `wg show <name>` 不同（后者要接口名）。**混用会失败**。

### 13.7 状态采集

#### 13.7.1 状态缓存

```go
func (c *Client) commandStatuses() (status, status) {
	now := time.Now()
	c.statusMu.Lock()
	defer c.statusMu.Unlock()
	if c.lastStatus.valid && now.Sub(c.lastStatus.at) < statusSampleInterval {
		return c.lastStatus.wireguard, c.lastStatus.bird
	}
	c.lastStatus = statusSample{
		at:        now,
		wireguard: commandStatus(c.server.Runner.WireGuardStatus()),
		bird:      commandStatus(c.server.Runner.BirdStatus()),
		valid:     true,
	}
	return c.lastStatus.wireguard, c.lastStatus.bird
}
```

**缓存 60 秒，期间所有心跳复用同一份输出**。这是 §13.3.1 里"子进程开销降 1/3"的实现。

⚠️ **锁在整个"跑命令"期间持有**。注释说"心跳是串行的，所以没有争用"——**这依赖 `heartbeatLoop` 只有一个 goroutine**。若将来加多个心跳源（例如同时上报给两个后端），会串行化并显著拖慢。复刻时若要并行心跳，需改成"单飞（singleflight）"模式。

#### 13.7.2 状态截断

```go
func commandStatus(result runner.Result) status {
	output := result.Output
	if len(output) > maxStatusOutput {
		output = output[:maxStatusOutput] + "\n[truncated]"
	}
	return status{OK: result.OK, Output: output}
}
```

**64 KiB 上限** —— `birdc show protocols all` 在几百个 peer 的节点上可能超过这个量。截断后加 `[truncated]` 标记。

⚠️ **`output[:maxStatusOutput]` 按字节切** —— 可能把一个 UTF-8 字符切成两半，产生无效字符串。JSON 序列化时 Go 会用 `\ufffd` 替换，不会报错，但显示会有一个乱码字符。可接受。

#### 13.7.3 资源指标

**CPU**：读 `/proc/stat` 第一行（`cpu` 汇总），算出 `total`（所有字段和）与 `idle`（第 4 个字段 + 第 5 个 `iowait`）。**两次采样求差**得到百分比。

```go
idle := values[3]
if len(values) > 4 {
    idle += values[4]
}
```

⚠️ **把 `iowait` 计入 idle** —— 这是"CPU 不忙"的常见近似。严格来说 `iowait` 不是 idle，但在路由器场景（IO 少）差异可忽略。

**内存**：读 `/proc/meminfo`，用 `MemTotal - MemAvailable` 作为已用。**用 `MemAvailable` 而非 `MemFree`** 是关键——`MemFree` 不含可回收的 page cache，会显示"内存 90% 已用"的假警报。

**网络**：读 `/proc/net/dev`，跳过 `lo`，累加所有接口的 rx/tx 字节。**两次采样求差 ÷ 时间**得到速率。

⚠️ **网卡重置或计数器回绕会导致 `rxBytes < previous.rxBytes`**，代码里用 `if network.rxBytes >= previous.network.rxBytes` 保护，此时**跳过本次速率**（置 nil），而不是报一个负数。

**首次采样返回空**：`previous.at.IsZero()` 时直接返回不含 CPU/网络速率的 `resourceUsage` —— 因为没有基准。

#### 13.7.4 心跳结构

```go
type systemStatus struct {
	Hostname                string   `json:"hostname"`
	OS                      string   `json:"os"`
	Arch                    string   `json:"arch"`
	UptimeSeconds           int64    `json:"uptime_seconds,omitempty"`
	Load1                   float64  `json:"load_1,omitempty"`
	Load5                   float64  `json:"load_5,omitempty"`
	Load15                  float64  `json:"load_15,omitempty"`
	CPUPercent              *float64 `json:"cpu_percent,omitempty"`
	MemoryPercent           *float64 `json:"memory_percent,omitempty"`
	MemoryUsedBytes         int64    `json:"memory_used_bytes,omitempty"`
	MemoryTotalBytes        int64    `json:"memory_total_bytes,omitempty"`
	NetworkRxBytesPerSecond *float64 `json:"network_rx_bytes_per_second,omitempty"`
	NetworkTxBytesPerSecond *float64 `json:"network_tx_bytes_per_second,omitempty"`
	Goroutines              int      `json:"goroutines"`
	WireGuard               status   `json:"wireguard"`
	Bird                    status   `json:"bird"`
}
```

**为什么 CPU/内存/网络用 `*float64` 而非 `float64`**：

| 场景 | `float64` 会怎样 | `*float64` 会怎样 |
|---|---|---|
| 首次心跳（无基准） | 上报 `0` → 后端显示"CPU 0%" | 字段被 `omitempty` 省略 → 后端显示"—" |
| `/proc/stat` 读失败 | 上报 `0` | 省略 |
| 计数器回绕 | 上报 `0` 或负数 | 省略 |

**`0%` 与"未知"是完全不同的语义**。首页的 `resource_metrics`（§11.6.2）靠"字段是否存在"决定是否显示该项。**用 `float64` 会让运维看到"CPU 0%"而误以为系统空闲**。

⚠️ **`omitempty` 对 `*float64` 生效的条件是 nil**。若指针非 nil 但值为 `0`，`omitempty` **不会**省略（因为指针本身非 nil）。所以"CPU 恰好是 0%"会上报 `0`——这是正确的（真的空闲）。

⚠️ **`UptimeSeconds` / `Load*` 是 `int64`/`float64` + `omitempty`**，所以 `0` 会被省略。`Load1 == 0` 在真实系统上罕见（总有背景负载），`UptimeSeconds == 0` 只会在读 `/proc/uptime` 失败时出现。**这个设计有轻微精度损失，但无实际影响**。

**后端如何处理这些字段**：`_persist_seen_if_needed` 把 `system_status_json` 存成 JSON 字符串（§6.6），`node_runtime_context` 解析后供模板用。**白名单过滤**在 §6.5。

### 13.8 实现陷阱

1. **`MaxConcurrency` 与 `BirdPeerGroup` 必须用指针**。普通类型无法区分"未设置"与"显式零值"，而这两个字段的零值语义相反（0 = 不限制 / `""` = 不 chown）。写错会让一个配置遗漏静默关掉并发保护。
2. **`CommandTimeoutSeconds` 默认 12 秒，不是 10 秒**。且它是**单命令**超时；`DeployPeer` 会串行跑 3 个命令，节点侧最坏 36 秒，超过后端 `request_node_sync` 的 20 秒。
3. **`readFrame` 必须在分配内存前检查 `length > maxFramePayload`**。顺序反了就是一个声明 4GB 帧即可 OOM 的 DoS。
4. **握手后必须复用同一个 `bufio.Reader`**。`http.ReadResponse` 之后缓冲区里可能已有 WS 帧数据，重新从 `conn` 读会丢。
5. **`writeFrame` 必须加 `writeMu`**。`handleRequest` 是 goroutine 启动的，不加锁会帧交错。
6. **`writeFrame` 的 MASK 位必须置 1**（`0x80 | length`）。客户端不发掩码帧会被严格的服务端断连。
7. **长度 126 必须走 2 字节扩展分支**（7 位只能表示 0–125）。`length == 126` 是边界。
8. **`heartbeatErr` 容量必须是 1**。容量 0 时，若主循环正阻塞在 `ReadJSON`，心跳 goroutine 会永远阻塞泄漏。
9. **`heartbeatLoop` 与主循环共用 `conn`**，靠 `writeMu` 保证不交错。不要给心跳单独连接。
10. **`tryAcquire` 是非阻塞的**（`select` + `default`）。改成阻塞等待会让公开 LG 请求堆积，内存爆炸。
11. **`deployMu` 是 deploy 与 remove 共用的**。分成两把锁会让同一 peer 的部署与删除互相踩。
12. **部署不进 `sem`**。部署已由 `deployMu` 串行化；放进 `sem` 会让一个卡住的 `wg-quick` 永久占住 LG 槽位。
13. **`decodeCommandPayload` 要检查尾部 `io.EOF`**，否则 `{"a":1}{"b":2}` 会被静默接受。
14. **`peerStatusResponse.OK` 只反映 BIRD**。隧道未起时 `wg` 非零退出是正常状态，不该让整个请求 `ok=false`。
15. **`ensureChildPath` 用 `filepath.Rel` 而非字符串前缀**。前缀比较会把 `/etc/wireguard-evil/` 误判为 `/etc/wireguard` 的子路径。
16. **`writeConfigFile` 的临时文件必须与目标同目录**，否则 `os.Rename` 跨文件系统不原子。
17. **`writeConfigFile` 先 `CreateTemp`（0600）再 `Chmod(0640)`**，不要反过来。
18. **`chownToGroup` 要同时改目录和文件**。只改文件，`bird` 用户进不了 root:root 0750 的目录。
19. **`chownToGroup` 失败是硬错误**。降级成 warning 会让配置错误延后到 `birdc configure` 才暴露。
20. **WG 文件永不 chown**。它含私钥，必须只 root 可读。
21. **私钥占位符替换只在节点侧做**。后端永远不持有明文私钥（§13.5.5），这是本架构最重要的安全属性。
22. **`wg-quick down/up` 传文件路径，`wg show` 传接口名**。两者不通用。
23. **`RemovePeer` 的 `wg-quick down` 要先 `os.Stat`**。文件不存在时 `down` 会报错产生噪音。
24. **`RemovePeer` 的 `Applied: true` 从第一次删文件成功就开始**，部分删除时 `OK: false, Applied: true`。
25. **`safeNameRE` 不许 `-` 开头**，防 `--help` 被当选项。
26. **CPU/内存/网络用 `*float64` + `omitempty`**。用 `float64` 会把"未知"显示成 `0`。
27. **内存已用要用 `MemTotal - MemAvailable`**，不是 `MemFree`。
28. **网络计数器回绕时跳过本次速率**，不要上报负数。
29. **`commandStatuses` 的锁在整个跑命令期间持有**，依赖"心跳串行"这一前提。
30. **`log.Fatal` 不要用在运行期**，它不执行 `defer`，会泄漏连接与临时文件。

---

## §14 安全要求

这一章不是"安全最佳实践清单"，而是**这套架构里真实存在的信任边界、秘密流向、以及每一处防护为什么必须这么写**。复刻时如果把某一条当成"可选的加固"，就会留下实际可被利用的口子。

### 14.1 威胁模型

#### 14.1.1 资产

| 资产 | 泄露后果 | 篡改后果 |
|---|---|---|
| 节点 WG **私钥**（`wireguard_private_key`） | 攻击者可在该节点上冒充它建立隧道，进入 dn42 内网 | 隧道全断 |
| 节点 **Bearer token** | 攻击者可冒充后端，向节点下发任意 `peers.deploy` → **root 级任意文件写** | 节点被完全接管 |
| `BOT_SECRET` | 攻击者可调用 Bot-only API，创建/删除任意用户的 Peer | 全站 Peer 被清空 |
| `SESSION_SECRET` | 攻击者伪造任意用户的会话 Cookie（含管理员） | 全站提权 |
| 用户的 **Kioubit 签名** | 可重放 → 冒充该 ASN（受 60 秒窗口限制） | — |
| **WG 公钥** | 无直接危害（公开信息） | 对端连不上 |
| **Peer 的 BGP 配置** | 暴露 IP 规划与对端公钥 | 路由劫持（需要节点 root） |

**最关键的判断**：`Bearer token` 的泄露比私钥更危险。私钥只能用来"成为这条隧道"，而 token 能下发 `peers.deploy`，而 `peers.deploy` 会在节点上以 **root 写文件**（`/etc/wireguard/*.conf`、`/etc/bird/peers/*.conf`）。虽然有 `safeNameRE` 与 `ensureChildPath` 兜底，但**攻击者仍能覆盖任意已存在 peer 名的配置**，进而篡改 BGP 宣告。

#### 14.1.2 攻击者画像

| 攻击者 | 能力 | 目标 |
|---|---|---|
| **匿名公网用户** | 访问 `/`、`/lg`、`/login` | 把 LG 当跳板、刷爆路由器 |
| **持有任意 dn42 ASN 的人** | 通过 Kioubit 登录，成为普通用户 | 越权访问他人 Peer、探测系统信息 |
| **恶意节点运维**（持有 token） | 可对后端发任意 WSS 响应 | 伪造心跳、伪造 peer 状态 |
| **拿到后端数据库的人** | 读 `users`/`peers`/`nodes` | 找 token、找私钥（**找不到**，见 §14.2） |
| **拿到后端进程权限的人** | 读 `.env`、连节点 | 完全控制 |

**注意最后一行的区别**：**拖库 ≠ 拿进程权限**。私钥不在库里（§14.2），所以拖库拿不到私钥。但 token 在库里，所以拖库能接管所有节点。

#### 14.1.3 不在威胁模型内

以下场景**原实现明确不防**，复刻时不要假装它防了：

| 场景 | 为什么不做 |
|---|---|
| 恶意节点伪造 `peers.status` 输出 | 节点运维本来就能直接改路由器，伪造状态没有额外收益 |
| 后端管理员作恶 | 管理员本来就能删所有 Peer；防"管理员"没有意义，只有审计 |
| 节点侧本地提权 | 节点以 root 跑，本地已有 root 的人无需提权 |
| 供应链攻击（Go/Python 依赖） | Go 侧零依赖；Python 侧依赖数量有限，靠 `pip` 锁版本 |
| DDoS（带宽层） | 由反代/CDN 承担，不在应用层解决 |

### 14.2 秘密清单与流向

#### 14.2.1 秘密总表

| 秘密 | 存放位置 | 谁能读 | 是否进数据库 | 是否进日志 |
|---|---|---|---|---|
| `SESSION_SECRET` | `.env` | 后端进程 | 否 | 否 |
| `BOT_SECRET` | `.env` | 后端 + Bot 进程 | 否 | 否 |
| `TELEGRAM_BOT_TOKEN` | `.env` | Bot 进程 | 否 | 否 |
| 节点 `token` | `nodes.token`（DB）+ 节点 `config.json` | 后端进程 + 节点 root | **是** | 否 |
| 节点 `wireguard_private_key` | 节点 `config.json` | 节点 root | **否** | 否 |
| 节点 `wireguard_public_key` | DB + 节点配置 | 所有人（公开） | 是 | 可 |
| 用户会话 | 签名 Cookie | 用户浏览器 | 否 | 否 |
| Kioubit 签名 | 请求体（瞬时） | 后端 | **否**（只存 ASN/身份） | 否 |

#### 14.2.2 私钥永不出节点

这是**整个架构最重要的安全属性**，值得单独强调。

**后端渲染 WG 配置时只输出占位符**（§7.3 `render_wireguard_peer_config`）：

```
[Interface]
PrivateKey = {{WIREGUARD_PRIVATE_KEY}}
ListenPort = 20090
Table = off
MTU = 1420
PostUp = ip addr add fe80::90/64 dev %i
```

**节点写盘前替换**（§13.5.5 `renderWireGuardConfig`）：

```go
const placeholder = "{{WIREGUARD_PRIVATE_KEY}}"
if strings.Contains(config, placeholder) {
    if r.WireGuardKey == "" {
        return "", errors.New("wireguard_private_key is required ...")
    }
    return strings.ReplaceAll(config, placeholder, r.WireGuardKey), nil
}
```

**这个设计的三个后果**：

1. **后端数据库被拖库，攻击者拿不到任何节点私钥**——只能拿到公钥（公开信息）。
2. **后端进程内存里没有私钥**——即使后端被 RCE，也无法直接窃取（要逐个连节点，而那需要 token）。
3. **部署链路上（WSS）传输的是含占位符的配置**——TLS 保护下，但即便 TLS 被破，泄漏的也不是私钥。

⚠️ **复刻时绝对不要把私钥挪到后端**。常见"优化"是"后端统一管理私钥，渲染完整配置下发"——这会让后端变成**单点高价值目标**，一旦被攻破，所有节点的隧道全部失守。原实现的取舍是"多点分散 + 每节点只能拿到自己的私钥"。

⚠️ **占位符必须逐字匹配 `{{WIREGUARD_PRIVATE_KEY}}`**。后端渲染、节点替换两处必须用同一个字面量。若后端改了占位符而节点没改，**节点会把占位符原样写进 `.conf`** → `wg-quick up` 报 `Invalid key` → 部署失败，且错误信息里会包含占位符（不泄漏私钥，但会让运维困惑）。

#### 14.2.3 节点 token 的双向用途

token 是**对称的共享秘密**：

| 方向 | 用途 | 校验方式 |
|---|---|---|
| 节点 → 后端 | WSS 握手 `Authorization: Bearer <token>` | `secrets.compare_digest`（§5.1） |
| 后端 → 节点 | 无（后端不发 token） | — |

**只有节点主动拨出**，所以 token 只在"节点证明自己是谁"时使用。后端**不需要**向节点证明自己——它靠 TLS 证书（节点校验 `ServerName`）。

⚠️ **这意味着一件事：如果攻击者拿到 token，他能冒充节点连上后端，但拿不到任何数据**（后端不会主动推数据给节点，只会回应请求）。他的收益是"让后端以为节点在线"，从而接收 `peers.deploy` 并**记录下完整的 Peer 配置**（含对端公钥、IP 规划）。这是一个**信息泄露**面，不是直接控制面。

**缓解**：`_lookup_node_auth` 拒绝空 token 节点（§5.1），token 用 `secrets.token_urlsafe(32)` 生成（§11.8.2），轮换方式见 §2.7。

#### 14.2.4 `SESSION_SECRET` 的强度

Starlette 的 `SessionMiddleware` 用 `itsdangerous` 对 Cookie **签名**（不是加密）。这意味着：

- 攻击者**能解码** Cookie 内容（base64 + JSON）；
- 但只要不知道 secret，就**不能伪造**签名。

**因此**：

1. `SESSION_SECRET` 必须足够长（≥ 32 字节随机）。
2. **Cookie 里不能放秘密**——原实现只放 `user_id`（UUID）与 `_flash`。
3. **不能依赖 Cookie 保密性**。

⚠️ **`SessionMiddleware` 没有 `max_age` 的原实现配置**。若未设，会话是**浏览器会话级**（关闭浏览器即失效）。复刻时若需要"记住我"，要显式设 `max_age`，并接受"长期有效的签名 Cookie 一旦泄露即可长期冒充"。

⚠️ **会话不随密码/身份变化而失效**。`logout` 只是删 Cookie；服务端没有会话表。所以**改了 `is_admin` 后，旧 Cookie 仍然有效**（但 `is_admin` 是每次请求从库里读的，见 §11.6.1，所以权限变更立即生效）。

#### 14.2.5 `BOT_SECRET` 的边界

`require_bot_secret`（§9）对**所有** `/api/telegram/*` 之外的 Bot-only 端点生效。三条硬性要求：

1. **`secrets.compare_digest`**，不是 `==`。后者有计时侧信道。
2. **从 `Authorization: Bearer <secret>` 读**，不是自定义头（复用标准，减少配置错误）。
3. **`BOT_SECRET` 为空时拒绝所有请求**（不是"放行"）。这一点极其关键——见 §14.8。

⚠️ **Bot 与后端必须共享同一个 `BOT_SECRET`**。若两边 `.env` 不一致，所有 Bot 请求 401，但**错误消息不会提示"secret 不匹配"**（只返回通用 401）。这是排障难点，运维手册里必须写（§16）。

### 14.3 三条认证路径的安全属性

#### 14.3.1 对照表

| 路径 | 入口 | 凭证 | 重放防护 | 身份来源 | 信任级别 |
|---|---|---|---|---|---|
| Web Kioubit | `GET /login` → 跳转 g-load → `GET /auth/kioubit/callback` | `params` + `signature`（ECDSA） | **60 秒双向时间窗** + 一次性 `auth_challenges` | 签名里的 ASN | 高（密码学） |
| Telegram Mini App | Bot 内 `sendData` → `web_app_data` → `POST /api/telegram/verify` | `params` + `signature` + `telegram_user_id` | 同上 | 签名 ASN + TG UID 绑定 | 高 |
| FindNOC 快速登录 | `POST /api/telegram/findnoc-login` | `queryUser` / `verify` | 由 FindNOC 服务承担 | FindNOC 返回的 ASN | 中（依赖第三方） |

**为什么 Web 与 Telegram 走两条不同的"挑战"用途**：`auth_challenges.purpose` 区分 `web` / `telegram`（§4.2）。**消费时必须匹配 purpose**，否则一条 Web 挑战可以被 Telegram 流程消费（反之亦然），造成"同一挑战两处生效"。

#### 14.3.2 Kioubit 签名验证

```python
# 概念性伪代码，实际实现见 app/auth/kioubit.py
def verify(params: str, signature: str, domain: str) -> dict:
    raw = base64.b64decode(signature)          # 注意：不是 urlsafe_b64decode
    ...
    # 1. 解析 params 为 JSON（payload 里含 asn、mnt、timestamp 等）
    # 2. 用 ASN 对应的公钥验 ECDSA/SHA-512
    # 3. 校验 timestamp 与本机时间差 <= 60 秒（双向）
    # 4. 校验 payload["domain"] == settings.auth_domain（精确相等）
    # 5. 返回 payload
```

**四个必须照抄的细节**：

1. **`base64.b64decode` 而非 `urlsafe_b64decode`**。Kioubit 用的是标准 base64（含 `+` `/`）。用 urlsafe 会把 `-` `_` 当合法字符，导致某些签名被误解码——**验证失败是好事，但若签名恰好不含 `+`/`/`，两者结果相同，掩盖了这个差异**。复刻时用错会在某个特定签名上突然失败，极难排查。
2. **60 秒双向窗口**。`abs(now - timestamp) <= 60`。**单向窗口（只拒未来）会让重放窗口无限长**。
3. **`domain` 必须精确 `==`**，不能用 `endswith` 或 `in`。`evil-dn42.g-load.eu` 以 `.g-load.eu` 结尾，`endswith` 会放过。
4. **`params` 不能再解码一次**。若 payload 里已有 JSON 字符串，别再 `json.loads` 它（见 §10 陷阱）。

**为什么用挑战（challenge）而不是纯时间窗**：60 秒窗口内，同一条签名可以被重放任意次（比如并发开 100 个会话）。`auth_challenges` 一次性消费把窗口压到"一次"。**两层防护缺一不可**：

- 只有时间窗 → 60 秒内可重放；
- 只有挑战 → 攻击者可以先自己发起挑战，再诱导受害者签名（CSRF 式），时间窗能限制这个。

#### 14.3.3 挑战的生命周期

```python
# 概念性
challenge = create_challenge(db, purpose="web")   # token_urlsafe(32), TTL 600s
...
consume_challenge(db, token, purpose="web")        # 校验未消费 + 未过期 + purpose 匹配
```

| 属性 | 值 | 失效后果 |
|---|---|---|
| `token` | `secrets.token_urlsafe(32)`（43 字符） | 熵不足可被猜测 |
| TTL | 600 秒 | 太长可被利用；太短用户体验差 |
| `purpose` | `web` / `telegram` | 不区分 → 跨流程重放 |
| `consumed_at` | 一次性 | 不消费 → 60 秒内可重放 |
| 存储 | `auth_challenges` 表 | 只存内存 → 多 worker 失效 |

⚠️ **挑战是**数据库**存储，不是内存**。这让多 worker 部署也能工作（任一 worker 都能消费）。代价是每次登录两次 DB 写（创建 + 消费）。

⚠️ **挑战消费必须在 `upsert_user_from_kioubit` 之前**（§10.2）。若顺序反了，攻击者可以用同一条签名反复触发 `upsert`（虽然每次结果相同，但会刷新 `last_login_at`，且是多余的写放大）。

⚠️ **挑战过期清理**。原实现没有定时清理任务——过期记录会堆积。数据量小（每次登录一条）时可接受，但长期运行会累积。**复刻时建议加定期删除或按 `expires_at` 索引 + 惰性清理**。

#### 14.3.4 Telegram Mini App 的特殊点

`POST /api/telegram/verify` 的 payload 除了 Kioubit 签名，还带 `telegram_user_id`。

**必须做 UID 的比较**：

```python
# 概念性
challenge = consume_challenge(db, token, purpose="telegram")
if str(challenge.telegram_user_id) != str(payload["telegram_user_id"]):
    raise HTTPException(400, ...)
```

⚠️ **`telegram_user_id` 必须按字符串比较**。TG 的 UID 是 64 位整数，若一处按 int、一处按 str，`123` 与 `"123"` 会不相等（或反之），造成"绑定成功但登录失败"。

⚠️ **`web_app_data` 必须 `json.loads`**。Bot 收到的 `message.web_app_data.data` 是一个 JSON **字符串**，不是 dict。不解析会直接报错（见 §8.14）。

#### 14.3.5 FindNOC 的回退

`POST /api/telegram/findnoc-login` 先调 `queryUser`，再调 `verify`。

| FindNOC 返回 | 后端行为 |
|---|---|
| `404` | **回退 Kioubit**（该 ASN 未在 FindNOC 注册） |
| `503` | **回退 Kioubit**（FindNOC 服务不可用） |
| 其他 4xx/5xx | **报错**（不静默回退） |
| 200 + 有效 | 登录成功 |

⚠️ **只对 404/503 回退**。若对所有错误都回退，FindNOC 的**认证失败**（如 401）会被降级成"走 Kioubit"，攻击者可以绕过 FindNOC 的额外校验。**404/503 是"服务/记录不存在"，回退是语义正确的；401/403 是"验证失败"，回退是安全漏洞**。

⚠️ **FindNOC 的信任级别低于 Kioubit**——它不提供密码学证明，只提供"这个 TG 用户声称是 ASN X，FindNOC 认可"。因此**不应把 FindNOC 登录的用户直接授为管理员**（原实现的 `is_admin` 只取决于 ASN 是否等于 `LOCAL_ASN`，与登录路径无关——这没问题，但也意味着**任何能通过 FindNOC 声称自己是 LOCAL_ASN 的人都会成为管理员**）。

**这是原实现的一个隐含假设**：FindNOC 对 ASN 的校验是可信的。若该假设不成立，就存在提权路径。**复刻时必须确认 FindNOC 的 `verify` 确实做了归属校验**。

### 14.4 节点认证与 WSS 安全

#### 14.4.1 认证失败的四种情况

`/api/nodes/ws` 的认证（§5.1）：

| 情况 | 行为 | 日志 |
|---|---|---|
| `name` 缺失 | 关闭连接（4000 或 HTTP 拒绝） | 无 |
| 节点不存在 | 关闭连接 | 无（**避免枚举**） |
| 节点 `token` 为空 | **直接拒绝** | warning |
| token 不匹配 | 关闭连接 | warning（含节点名） |

⚠️ **"节点 `token` 为空直接拒绝"是必需的**。若允许空 token 匹配空 token，则**任何知道节点名的人都能冒充该节点**。节点名在半公开语境下（管理员界面、日志）并不难获得。

⚠️ **"节点不存在"与"token 错误"对外表现应一致**。若前者返回"node not found"、后者返回"invalid token"，攻击者可以枚举节点名。原实现两者都只是关连接。

#### 14.4.2 连接替换

`NodeHub.register` 在已有连接时：

1. `fail_pending(NodeOfflineError)` —— 让所有在途请求立即失败（不等到超时）；
2. 关闭旧连接（close code **4000**）；
3. 替换为新连接。

⚠️ **必须让旧连接的在途请求立即失败**，否则后端会等 30 秒超时（§5.4），期间用户看到"转圈"。`NodeOfflineError` 的文案应面向用户（"node is offline"）。

⚠️ **`unregister` 必须校验 `current is connection`**。若节点在 A/B 两条连接间抖动，A 的 `unregister` 不能把 B 的注册删掉。原实现用身份比较（`is`），不是按名字删。

#### 14.4.3 节点侧不监听

**节点不开放任何端口**。这是与上一代架构（后端主动 POST 到 Agent）最大的安全改进：

| 项 | 旧架构（Agent 监听） | 本架构（节点拨出） |
|---|---|---|
| 节点防火墙 | 必须开放 Agent 端口给后端 | **无需开放任何入站** |
| 认证 | Header Secret（明文 HTTP 下可被嗅探） | Bearer over TLS |
| 中间人 | 可篡改请求 | TLS 证书校验 |
| NAT 后节点 | 无法被访问 | **可以**（主动拨出） |

⚠️ **复刻时不要"为了方便"给节点加一个 HTTP 监听**（比如健康检查端点）。那会立刻把上面的四条优势全部丢掉。

### 14.5 输入校验矩阵

#### 14.5.1 逐层校验总表

| 数据 | 后端校验 | 传输 | 节点校验 | 最终去向 |
|---|---|---|---|---|
| LG `query_type` | `ALLOWED_QUERY_TYPES` | WSS | `Command` 的 switch | 拼 `lg.<type>` |
| LG `target` | `validate_target` | WSS | `ValidateHostTarget` / `ValidateRouteTarget` | **固定 argv** |
| `protocol_name` | `peer_protocol_name`（含长度约束） | WSS | `safeNameRE` | 文件名 + argv |
| `wireguard_config` | 由 `render_wireguard_peer_config` 生成 | WSS | 非空 / ≤16 KiB / 无 NUL | 写文件 |
| `bird_config` | 由 `render_bird_peer_config` 生成 | WSS | 同上 | 写文件 |
| `asn` | `normalize_asn_number` | WSS | ≤32 + 无危险字符 | 日志/审计 |
| `node` | 取自 DB | WSS | ≤64 + 无 `/` `\` | 日志/审计 |
| Peer 表单字段 | `normalize_peer_input` | — | — | 渲染配置 |
| Bot 命令参数 | 各命令自己的解析 | HTTP | — | — |

**两侧校验的哲学差异**：

- **后端校验是"业务正确性"**：拒绝非法 ASN、拒绝无法推导的地址、给出面向用户的错误。
- **节点校验是"最坏情况兜底"**：假设后端已被攻破或版本不匹配，仍要保证 root 进程不被利用。

⚠️ **不要把节点侧的校验删掉，理由是"后端已经校验过了"**。这就是纵深防御的定义。原实现两处都做，且**节点的两处（`hasUnsafeTargetChar` + `safeNameRE` + `ensureChildPath`）都是独立的**，不依赖后端。

#### 14.5.2 固定 argv 的三重意义

所有外部命令都是：

```go
exec.CommandContext(ctx, args[0], args[1:]...)
```

**没有 shell**。这消除了以下全部注入面：

| 注入技术 | 在 shell 下 | 在固定 argv 下 |
|---|---|---|
| `; rm -rf /` | 执行 | 作为目标的字面量，`ping` 报错 |
| `$(...)` | 命令替换 | 字面量 |
| `` `...` `` | 同上 | 字面量 |
| `|` / `&&` | 管道/串联 | 字面量 |
| `>` / `<` | 重定向 | 字面量 |
| 换行 | 新命令 | 字面量（但 `\s` 已拒） |

**但固定 argv 仍有两个残留面**：

1. **以 `-` 开头的参数会被目标程序当成选项**。`ping -f 1.1.1.1` 会开启 flood（需要 root，正好我们是 root）。所以 `hasUnsafeTargetChar` 拒绝前导 `-`。
2. **某些程序会做二次参数解析**。例如 `ssh` 会把 `-o` 之后的东西再解析（我们不用 ssh）；`mtr` 的部分版本对 `--` 之后不做保护。所以除了拒绝 `-`，还要拒绝空白（防止 `"1.1.1.1 -c 100000"` 被程序内部再切分）。

⚠️ **`--` 分隔符不是万能的**。`ping -- 1.1.1.1` 在某些实现上不被支持。**拒绝前导 `-` 是更可靠的方案**。

#### 14.5.3 配置片段的内容不校验

节点侧对 `wireguard_config` / `bird_config` **只做"非空 + 大小 + NUL"检查**，不解析内容（§13.5.4）。

**这意味着**：如果后端被攻破，攻击者可以让后端生成一份**任意内容**的 BIRD 配置并下发。节点会照写，然后 `birdc configure` 执行。

**BIRD 配置能做什么**：

- 宣告任意前缀（路由劫持）；
- 通过 `include` 读节点上任意文件（BIRD 语法支持 `include "path"`）——**这可以读取 `/etc/shadow` 并通过 `birdc` 回显**；
- 通过 `eval` / `function` 做有限的计算。

⚠️ **这是本架构最大的残留风险**：节点信任后端的配置内容。缓解手段是"后端是可信的"（同一运维团队），但**一旦后端被 RCE，所有节点随之失守**。

**若要加固**（复刻时可考虑）：

1. 节点侧对 BIRD 配置做**模板白名单匹配**（只允许特定结构）；
2. 或节点侧拒绝配置中的 `include` 关键字；
3. 或让 `birdc configure` 在受限的 mount namespace 里跑。

原实现没有做这些，属于"信任后端"的设计。**复刻时必须明确记录这个信任假设**。

### 14.6 文件系统与权限

#### 14.6.1 目录与权限

| 路径 | 属主:组 | 权限 | 内容 | 谁能读 |
|---|---|---|---|---|
| `/etc/wireguard/` | `root:root` | 0750 | `DN42_xxxx_yyyy.conf` | root |
| `/etc/wireguard/DN42_x.conf` | `root:root` | 0640 | WG 接口配置（**含私钥**） | **仅 root** |
| `/etc/bird/peers/` | `root:bird` | 0750 | `DN42_x.conf` | root + bird |
| `/etc/bird/peers/DN42_x.conf` | `root:bird` | 0640 | BIRD peer 片段 | root + bird |
| `/etc/dn42-node/config.json` | `root:root` | **0600** | 含 token + 私钥 | **仅 root** |

⚠️ **WG 文件是 0640 但组是 `root`**——所以实际上只有 root 能读。这是 `writeConfigFile` 硬编码 0640 + 不 chown WG 文件的结果。

⚠️ **`config.json` 必须 0600**。它含 `token` 与 `wireguard_private_key`。systemd 单元里应加 `ConfigurationDirectoryMode` 或 `UMask=0077` 兜底。

#### 14.6.2 写文件的三个不变量

1. **原子性**（`CreateTemp` + `Rename`）——防止半写文件被 BIRD/wg-quick 读到。
2. **最小权限**（0600 建 → 0640 落）——防止创建瞬间可读。
3. **路径限定**（`ensureChildPath`）——防止写到目录外。

⚠️ **这三个不变量必须同时满足**。少任何一个都会留下实际可利用的问题：

- 少原子性 → 概率性故障（难排查）；
- 少最小权限 → 极短的窗口期，但存在；
- 少路径限定 → 直接任意文件写（root）。

#### 14.6.3 后端侧的文件

| 路径 | 权限 | 内容 |
|---|---|---|
| `/opt/dn42/.env` | **0600** | 所有秘密 |
| `/opt/dn42/data/dn42.sqlite3` | 0600 | 用户、Peer、节点 token |
| `/opt/dn42/` | 0755 | 代码（公开无妨） |

⚠️ **SQLite 文件含节点 token**，必须 0600。若数据库放在 Web 可访问的目录下，就能被直接下载——**一定要在 `/opt` 或 `/var/lib` 下，绝不要放在 `static/` 里**。

⚠️ **`.env` 不能被 Web 服务读取**。若用 nginx 反代且 `root` 指向项目根目录，`/.env` 可能被直接返回。**反代必须只 `proxy_pass` 到应用，不要 `root` 指项目目录**。

### 14.7 反代与头信任

#### 14.7.1 `FORWARDED_IP_HEADER` 的正确配置

（§12.3.7 已述，这里给完整要求。）

| 项 | 要求 |
|---|---|
| nginx | `proxy_set_header X-Forwarded-For $remote_addr;`（**覆盖**） |
| 应用 | `FORWARDED_IP_HEADER=X-Forwarded-For` |
| 若不用反代 | `FORWARDED_IP_HEADER` **留空** |

⚠️ **`$proxy_add_x_forwarded_for` 是追加，会被伪造**。必须用 `$remote_addr`。

⚠️ **多层反代（CDN → nginx）** 时，`$remote_addr` 是 CDN 的 IP，不是用户 IP。此时需要：

1. 配置 nginx 的 `real_ip` 模块（`set_real_ip_from` + `real_ip_header`），让 `$remote_addr` 变成真实用户 IP；
2. 或者信任 CDN 设置的 `CF-Connecting-IP` 之类，但那需要 `FORWARDED_IP_HEADER` 指向该头，且**只在有 CDN 时安全**。

⚠️ **如果 `FORWARDED_IP_HEADER` 配了但反代没覆盖，限流形同虚设**。这是**最常见的部署事故**。

#### 14.7.2 HTTPS 强制

- `BASE_URL` 必须是 `https://`（`/login` 的 `return_url` 是绝对 URL，§11.6.4）；
- Cookie 的 `Secure` 标志：Starlette `SessionMiddleware` 的 `https_only` 参数，原实现应设为 `settings.base_url.startswith("https")`；
- `ALLOW_INSECURE_DEFAULTS` **只在 `--allow-http` 时设为 1**（§2.2）。

⚠️ **若用 HTTP 部署**：token、会话 Cookie、Kioubit 签名全部明文传输。原实现用"不安全默认值守卫"（§14.8）阻止这种部署**意外**发生，但不阻止**明知故犯**。

### 14.8 不安全默认值守卫

#### 14.8.1 机制

```python
INSECURE_SECRET_VALUES = {"dev-session-secret", "change-me", "dev-telegram-secret", "change-me-too", ""}

# lifespan 中
if not settings.allow_insecure_defaults:
    for name, value in (
        ("SESSION_SECRET", settings.session_secret),
        ("BOT_SECRET", settings.bot_secret),
        ("TELEGRAM_BOT_TOKEN", settings.telegram_bot_token),
    ):
        if value in INSECURE_SECRET_VALUES:
            raise RuntimeError(f"{name} must be changed from its default value")
```

⚠️ **这个守卫只在 `ALLOW_INSECURE_DEFAULTS` 未设时生效**。`start.py --allow-http` 会设 `ALLOW_INSECURE_DEFAULTS=1`，**跳过守卫**。

**设计意图**：开发时用 `--allow-http` 快速起步；生产时忘记改 secret → 启动直接失败，而不是"带着默认 secret 上线"。

⚠️ **守卫的集合是"字面量黑名单"，不是"强度检查"**。`SESSION_SECRET=abc` 不会被拦（不在黑名单里）。所以它只能防"忘记改"，不能防"改成弱值"。**复刻时建议加长度检查（≥ 32 字符）**。

#### 14.8.2 空值也在黑名单里

`""` 在 `INSECURE_SECRET_VALUES` 里。这防止：

- `SESSION_SECRET=` （空）→ Starlette 用空 secret 签名 → 任何人都能伪造会话；
- `BOT_SECRET=` → `require_bot_secret` 若用 `compare_digest("", "")` 会返回 True → **Bot API 完全开放**。

⚠️ **`require_bot_secret` 必须显式拒绝空 secret**，不能只依赖"空 secret 与空头相等"。原实现在 `require_bot_secret` 里应该也有这条（见 §9.7 第 3 点：`BOT_SECRET` 为空时拒绝所有请求）。**两层都要有**：

- 启动期守卫：拒绝启动；
- 请求期检查：即使启动期被绕过（`ALLOW_INSECURE_DEFAULTS=1`），也拒绝。

### 14.9 上线安全检查清单

复刻完成后，**逐条打勾**才能上线：

#### 秘密

- [ ] `SESSION_SECRET` ≥ 32 字节随机（`secrets.token_urlsafe(48)`）
- [ ] `BOT_SECRET` ≥ 32 字节随机，且后端与 Bot 进程**完全一致**
- [ ] `TELEGRAM_BOT_TOKEN` 来自 BotFather，未提交到版本库
- [ ] 每个节点的 `token` 独立生成（`secrets.token_urlsafe(32)`），无复用
- [ ] 每个节点的 `wireguard_private_key` 独立生成，**不在后端留存**
- [ ] `.env` 权限 0600，属主为运行用户
- [ ] 节点 `config.json` 权限 0600，属主 root
- [ ] 版本库中无任何 `.env` / `config.json` 真实值（只有 `.example`）

#### 传输

- [ ] `BASE_URL` 为 `https://`
- [ ] 节点 `backend_wss_url` 为 `wss://`（或 `https://`，会被归一）
- [ ] TLS 证书有效且由公共 CA 签发（节点不信任自签）
- [ ] 反代 `proxy_set_header X-Forwarded-For $remote_addr`（覆盖）
- [ ] `FORWARDED_IP_HEADER` 与反代实际头名一致
- [ ] Cookie `https_only=True`

#### 认证

- [ ] `AUTH_DOMAIN` 与 Kioubit 后台登记的回调域名**精确一致**
- [ ] `LOCAL_ASN` 已设（否则无人是管理员；或全部人都是管理员——取决于实现，见 §11.6.1）
- [ ] `LOCAL_ASN` 格式合法（`normalize_asn_number` 能解析）
- [ ] 挑战 TTL 为 600 秒，`purpose` 区分正确
- [ ] 验证了 Kioubit 签名用的是 `b64decode`（非 urlsafe）
- [ ] 验证了 domain 用 `==`（非 `endswith`）
- [ ] FindNOC 只对 404/503 回退

#### 节点

- [ ] `max_concurrency` 已设（不是 0）
- [ ] `command_timeout_seconds` 与后端 `request_node_sync` 超时匹配（后端 ≥ 3× 节点）
- [ ] `bird_peer_group` 与实际 BIRD 用户组一致
- [ ] `deploy_reload_cmd` 正确（通常是 `birdc configure`）
- [ ] 节点以 systemd 托管，`Restart=always`
- [ ] 节点**不监听任何 TCP 端口**（`ss -ltnp` 确认）
- [ ] `/etc/wireguard` 下无 world-readable 文件

#### 限流与滥用

- [ ] `LG_RATE_LIMIT` > 0
- [ ] `LG_RATE_WINDOW_SECONDS` > 0
- [ ] 确认 worker 数量（多 worker 时实际阈值 × N）
- [ ] 若暴露公网 LG，考虑在反代层再加一层限流

#### 日志与审计

- [ ] 日志不包含 token、私钥、签名原文
- [ ] 日志保留策略已定（`LGQuery` 会持续增长）
- [ ] 确认 `LGQuery` 没有 `client_ip`（若需要，先加列）

### 14.10 已知安全缺口

复刻时**应当知道并决定是否修补**：

| # | 缺口 | 风险 | 建议 |
|---|---|---|---|
| 1 | `LGQuery` 无 `client_ip` | 无法追溯滥用来源 | 加列 |
| 2 | BIRD 配置内容不校验（§14.5.3） | 后端被攻破 → 所有节点失守 | 模板白名单 / 禁 `include` |
| 3 | `ensureChildPath` 不解析符号链接 | 多租户场景可被利用 | `EvalSymlinks` |
| 4 | 限流是进程内计数 | 多 worker 时阈值 × N | 接受，或上 Redis |
| 5 | `_prune` 是 O(n) 全量扫描 | 大量源 IP 时可被拖慢 | 改用 LRU / 分片 |
| 6 | 会话无 `max_age` | 浏览器会话级（可能是优点） | 按需设 |
| 7 | 挑战无定期清理 | 表持续增长 | 定时任务 |
| 8 | `decodeCommandPayload` 不记日志 | 排障盲点 | 加 debug 日志 |
| 9 | `deploy_peer` 超时（20s）< 节点最坏（36s） | 后端标记 failed 但节点可能成功 | 对齐超时 |
| 10 | `SESSION_SECRET` 只做黑名单，不查强度 | 弱 secret 能上线 | 加长度检查 |
| 11 | 节点信任系统 CA，无证书固定 | CA 被攻破 / 错误签发 | 可选 pinning |
| 12 | `peers.status` 的 `WireGuard` 字段不带 `ok` | 后端只能靠文本判断隧道状态 | 加上 `wireguard_ok` |

---

## §15 验收用例与一致性对照

本章是「复刻是否成功」的判据。§0–§14 描述「怎么实现」，本章描述「怎么证明实现对了」。

复刻过程中最常见的失败不是写不出来，而是**写出来但契约偏了**：字段名差一个字母、状态码多一个 400、文案少一个句号、`ok` 与 `applied` 语义对调。这些偏差在单测里看不出来，但在真实节点上会变成"部署成功但隧道没起来""Bot 一直提示未知错误"。

因此本章的验收用例全部是**黑盒可观测**的：只依赖 HTTP 响应、数据库行、节点上的文件、Bot 发出的消息。复刻者可以完全不用原仓库的代码，只按本章跑一遍。

### 15.1 验收环境

#### 15.1.1 最小三端环境

不需要真实路由器也能验完 90% 的用例。推荐环境：

| 角色 | 部署方式 | 说明 |
|---|---|---|
| Backend | `python3 start.py --allow-http --backend-only --host 127.0.0.1 --port 8000` | `--allow-http` 同时放开 HTTPS 校验与占位 secret 校验 |
| Node（真实） | 一台 Linux VM，装了 `wireguard-tools` + `bird2`，root 跑 `./node -config config.json` | 验证真实 `wg-quick`/`birdc` 行为 |
| Node（假） | 一个 60 行的 Python WSS 客户端（见 15.1.3） | 验证协议与后端逻辑，不需要 root，不需要 wireguard |
| Bot | 真实 BotFather token + 一个测试群 | 验证文案与 FSM |
| Kioubit | **无法在本地伪造真实签名** | 用 15.1.4 的"测试后门"方案 |

> **必须**准备两套节点：假节点用于跑协议/状态码用例（快、可断言报文），真实节点用于跑 §15.4 的落盘与 `wg-quick` 用例。只测假节点会漏掉 `chownToGroup`、`Table = off`、`PostUp` 这类真机才暴露的问题。

#### 15.1.2 后端测试用 `.env`

```ini
APP_NAME=dn42 Autopeer (test)
HOST=127.0.0.1
PORT=8000
DOMAIN=http://127.0.0.1:8000
SESSION_SECRET=test-session-secret-not-in-blacklist
DATABASE_URL=sqlite:///./test-autopeer.db
LOCAL_ASN=4242420000
KIOUBIT_PUBLIC_KEY_PATH=app/keys/public_key.pem
TELEGRAM_BOT_TOKEN=
TELEGRAM_BACKEND_SECRET=test-backend-secret-not-in-blacklist
TELEGRAM_BACKEND_URL=http://127.0.0.1:8000
FINDNOC_API_URL=https://findnoc.ox5.cc
FINDNOC_API_TOKEN=
ALLOW_INSECURE_DEFAULTS=1
LG_RATE_LIMIT=3
LG_RATE_WINDOW_SECONDS=10
FORWARDED_IP_HEADER=
```

注意三个刻意的取值：

1. `LG_RATE_LIMIT=3` / `LG_RATE_WINDOW_SECONDS=10`——把限流窗口压到 10 秒，§15.5 的限流用例才能在 30 秒内跑完。生产值是 20/60。
2. `SESSION_SECRET` 不能是 `dev-session-secret`/`change-me`/空——即使 `ALLOW_INSECURE_DEFAULTS=1`，某些路径仍然要求非空（§14.8）。用一个"像真的但不是黑名单值"的字符串最稳。
3. `FORWARDED_IP_HEADER` 留空——否则所有请求都会被当成同一个伪造 IP，限流用例失效。

#### 15.1.3 假节点（Fake Node）参考实现

这是验收工具，不是交付代码。它做到：拨 WSS、发 `hello`、回 `heartbeat`、按命令返回**固定可控**的结果。

```python
# tools/fake_node.py —— 仅用于验收，禁止进生产
import asyncio, json, ssl, sys, uuid
import websockets

BACKEND = sys.argv[1]          # ws://127.0.0.1:8000/api/nodes/ws?name=test-node
TOKEN = sys.argv[2]            # 与 Admin > Nodes 里的一致
PUBKEY = "x" * 43 + "="        # 44 字符
MODE = sys.argv[3] if len(sys.argv) > 3 else "ok"
# MODE: ok | busy | slow | fail

async def handler(ws):
    await ws.send(json.dumps({"type": "hello", "public_key": PUBKEY,
                              "system": {"hostname": "fake", "os": "linux", "arch": "amd64",
                                         "goroutines": 1,
                                         "wireguard": {"ok": True, "output": "interface: wg0\n"},
                                         "bird": {"ok": True, "output": "BIRD 2.0.12 ready.\n"}}}))
    async def hb():
        while True:
            await asyncio.sleep(20)
            await ws.send(json.dumps({"type": "heartbeat", "public_key": PUBKEY,
                                      "system": {"hostname": "fake", "os": "linux",
                                                 "arch": "amd64", "goroutines": 1,
                                                 "wireguard": {"ok": True, "output": "..."},
                                                 "bird": {"ok": True, "output": "..."}}}))
    hb_task = asyncio.create_task(hb())
    try:
        async for raw in ws:
            msg = json.loads(raw)
            if msg.get("type") != "request":
                continue
            cmd, rid = msg["command"], msg["id"]
            if MODE == "fail":
                await ws.send(json.dumps({"type": "response", "id": rid, "error": "boom"}))
                continue
            if MODE == "slow":
                await asyncio.sleep(60)
            result = {
                "pubkey": {"public_key": PUBKEY},
                "lg.ping": {"ok": True, "output": "PING 1.1.1.1 ... 4 packets transmitted"},
                "lg.trace": {"ok": True, "output": "traceroute to ..."},
                "lg.mtr": {"ok": True, "output": "HOST: ..."},
                "lg.route": {"ok": True, "output": "BGP.as_path: 4242420000 4242420090"},
                "peers.status": {"ok": True, "output": "BGP state:          Established\n",
                                 "wireguard": "interface: DN42_0090\n"},
                "peers.deploy": {"ok": True, "applied": True,
                                 "output": "deployed peer config\n",
                                 "files": ["/etc/wireguard/DN42_0090.conf",
                                           "/etc/bird/peers/DN42_0090.conf"]},
                "peers.remove": {"ok": True, "applied": True,
                                 "output": "removed peer config\n", "files": []},
            }.get(cmd, {"ok": False, "output": "unknown command"})
            if MODE == "busy" and cmd.startswith("lg."):
                result = {"ok": False, "output": "node is busy, try again shortly"}
            await ws.send(json.dumps({"type": "response", "id": rid, "result": result}))
    finally:
        hb_task.cancel()

async def main():
    async with websockets.connect(BACKEND, additional_headers={"Authorization": f"Bearer {TOKEN}"},
                                  ssl=None) as ws:
        await handler(ws)

asyncio.run(main())
```

运行：

```bash
python3 tools/fake_node.py "ws://127.0.0.1:8000/api/nodes/ws?name=test-node" "<token>" ok
```

> **建议**：先把 `MODE` 做成命令行参数并保留，后面的负面用例（busy/slow/fail）全靠它，不要为了"干净"删掉。

#### 15.1.4 绕过 Kioubit 的测试方案

Kioubit 的签名无法本地伪造（除非你有它的私钥）。三种可行方案，按推荐度排序：

| 方案 | 做法 | 优点 | 缺点 |
|---|---|---|---|
| A. 生成自己的测试密钥对，改 `KIOUBIT_PUBLIC_KEY_PATH` 指向测试公钥 | 用一个 Python 脚本用测试私钥签 `params`，直接打 `/auth/kioubit/callback` | 完整覆盖验签路径 | 需要临时改配置，且必须严格还原 |
| B. 在 `auth/service.py` 里加一个**仅在 `ALLOW_INSECURE_DEFAULTS` 时生效**的 dev 登录端点 | `GET /auth/dev?asn=4242420090` 直接建会话 | 最快 | 属于新增面，必须保证生产不可达 |
| C. 直接写数据库 | `INSERT INTO users/telegram_bindings`，再手工设置 session cookie | 零改动 | 绕过了挑战逻辑，测不到认证 |

**推荐 A**：它把 `b64decode`（非 urlsafe）、60 秒双向窗口、domain 精确匹配、params 不二次解码这四条 §14.3 强调的细节都真的跑了一遍。

测试签名脚本骨架：

```python
# tools/sign_kioubit.py
import base64, json, time, sys
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec

with open("tools/test_kioubit_private.pem", "rb") as f:
    key = serialization.load_pem_private_key(f.read(), password=None)

params = json.dumps({
    "user_token": sys.argv[1],
    "asn": "4242420090",
    "domain": "127.0.0.1:8000",   # 与 DOMAIN 去掉 scheme 和尾斜杠后一致
    "iat": int(time.time()),
    "mnt": "TEST-MNT",
}, separators=(",", ":")).encode()

sig = key.sign(params, ec.ECDSA(hashes.SHA512()))
print("params=" + base64.b64encode(params).decode())
print("signature=" + base64.b64encode(sig).decode())
```

> ⚠️ `domain` 必须是 **`DOMAIN` 去掉 scheme、去掉尾斜杠**后的值。测试环境 `DOMAIN=http://127.0.0.1:8000` → 令牌里写 `127.0.0.1:8000`。写 `localhost:8000` 会被 domain 精确匹配拒绝。

### 15.2 端到端验收场景

下面 10 个场景覆盖三条主链路（Web / Bot / LG）与两处基础设施（节点连接 / 部署）。

每个场景的写法规格：

- **前置**：开始前的系统状态。
- **步骤**：可复制的操作序列。
- **断言**：编号的、可机检的期望。`DB:` 前缀表示直接查 SQLite，`磁盘:` 表示在节点上查文件。

#### 场景 A：冷启动与不安全默认值守卫

**前置**：干净数据库（删除 `test-autopeer.db`）。

**步骤**：

```bash
# A1 正常启动
python3 start.py --allow-http --backend-only --host 127.0.0.1 --port 8000

# A2 启动后立刻
curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8000/
```

**断言**：

1. 进程正常存活，日志出现 Uvicorn 启动行。
2. `curl /` 返回 `200`。
3. `DB:` 存在 7 张表：`users`、`asn_identities`、`auth_challenges`、`telegram_bindings`、`nodes`、`peer_requests`、`lg_queries`。
4. `DB:` `select count(*) from nodes` = `0`（后端不会自动建节点）。

**负面**（不设 `ALLOW_INSECURE_DEFAULTS`）：

```bash
# 临时把 .env 的 SESSION_SECRET 改回 change-me，去掉 ALLOW_INSECURE_DEFAULTS
python3 start.py --backend-only
```

5. 进程**退出**，日志包含拒绝启动的说明，且**不应**出现端口监听成功。
6. 把 `TELEGRAM_BACKEND_SECRET` 也设成 `change-me-too` 时，即使 `SESSION_SECRET` 正常，仍应拒绝（两个 secret 各自独立检查）。

> ⚠️ 常见错误是只检查一个 secret。原实现两者都查，复刻时不要合并成一个 `if`。

#### 场景 B：节点首次连接与公钥上报

**前置**：后端运行；`DB:` 里有一个 `enabled=1` 的节点，`name='test-node'`、`token='t0ken-aaa'`、`url='127.0.0.1:51820'`。

**步骤**：

1. 启动假节点（15.1.3）。
2. 观察后端日志。
3. `curl http://127.0.0.1:8000/admin/nodes -b cookies.txt`（先登管理员，见场景 C）。

**断言**：

1. 节点 `hello` 到达后，后端日志出现连接注册（不含 token）。
2. `DB:` `nodes.wg_public_key` 在首次 `hello` 后被写成 `xxxxxxxx...=`，`DB:` `nodes.last_seen_at` 不为空。
3. `/admin/nodes` 页面该节点显示"在线"（依据是内存里的活动连接，不是 `last_seen_at`）。
4. `DB:` 再等 65 秒，`nodes.system_status_json` 被心跳刷新（解析出的 `hostname` = `fake`）。
5. **断开假节点**：60 秒内 `/admin/nodes` 显示离线。
6. **错误 token**：把假节点 token 改成 `wrong`，连接应被服务端拒绝（HTTP 403 或握手后关闭），后端日志不含该 token 原文。
7. **空 token 节点**：手工插入 `token=''` 的节点，假节点用空 token 连接，**必须**被拒绝（`_lookup_node_auth` 对空 token 直接拒绝，§6.2）。

> ⚠️ 断言 7 是易漏点：不实现"空 token 直接拒绝"的话，`compare_digest('', '')` 会通过，形成后门。

#### 场景 C：Web Kioubit 登录

**前置**：后端运行；测试密钥已就位。

**步骤**：

1. `curl -c cookies.txt -s http://127.0.0.1:8000/login > login.html`
2. `DB:` `select token, purpose, expires_at from auth_challenges order by id desc limit 1`
3. 用 15.1.4 的脚本签上一步的 token，得到 `params` / `signature`。
4. `curl -b cookies.txt -c cookies.txt -s -o /dev/null -w "%{http_code} %{redirect_url}" "http://127.0.0.1:8000/auth/kioubit/callback?params=...&signature=..."`

**断言**：

1. `login.html` 含 `kioubit-auth-btn` 元素（或至少含 Kioubit 按钮的资源引用）。
2. `DB:` 挑战行 `purpose='web'`，`consumed_at IS NULL`，`expires_at - created_at ≈ 600s`。
3. 回调返回 `303` 或 `302`，`Location` 以 `/portal` 结尾。
4. `DB:` `users` 新增一行，`primary_asn='4242420090'`，`is_admin=0`（不等于 `LOCAL_ASN`）。
5. `DB:` `asn_identities` 新增一行，`authtype` 记录 Kioubit。
6. `DB:` 挑战行 `consumed_at` 非空。
7. **重放同一个 `params`**：返回错误页（不是 500），且不创建第二个 user。
8. **换 `domain`**：签名正确但 domain 为 `example.com`，返回错误页，文案包含 domain 不匹配的含义。
9. **过期令牌**：`iat` 设为 120 秒前，返回错误页。
10. **purpose 错配**：用 `purpose='telegram'` 的挑战去走 Web 回调，返回错误页（"purpose mismatch"）。
11. **登录 `LOCAL_ASN`**：把签名里的 ASN 改成 `4242420000`，`DB:` 该 user `is_admin=1`，且能打开 `/admin`。

#### 场景 D：门户创建 Peer（核心链路）

**前置**：场景 C 已登录；节点 `test-node` 在线（假节点 `MODE=ok`）；该节点 `url='203.0.113.10:51820'`、`dn42_ipv4='172.20.0.10'`、`dn42_ipv6='fd00::10'`、`wg_public_key` 已上报。

**步骤**：

1. `GET /portal/new`，确认表单字段。
2. `POST /portal/peers/confirm` 提交表单（见下表），得到确认页。
3. `POST /portal/peers` 正式创建。

表单字段（复刻时字段名必须一致，否则模板与路由对不上）：

| 字段 | 值 | 备注 |
|---|---|---|
| `node_id` | 节点 UUID | 必填 |
| `wg_public_key` | 44 字符 base64 | 必填 |
| `endpoint` | 空 | 空 = 对端主动拨我们 |
| `peer_dn42_ipv4` | `172.20.99.1` | 至少一个地址必填 |
| `peer_dn42_ipv6` | `fd00:99::1` | 可空 |
| `peer_link_address` | 空 | 空 → 后端派生 `fe80::<suffix>` |
| `wg_mtu` | `1420` | 1280–9000 |
| `bgp_extended` | `on` | 缺省为开启 |

**断言**：

1. `GET /portal/new` 返回 `200`，HTML 含 `node_id`、`wg_public_key`、`peer_dn42_ipv4`、`peer_dn42_ipv6`、`peer_link_address`、`wg_mtu` 这些 `name=` 属性。
2. 确认页显示派生出的对端 link-local = `fe80::90`（ASN `4242420090` 的后缀 `90`），且显示我方 endpoint = `203.0.113.10:20090`。
3. `DB:` `peer_requests` 新增一行：`asn='4242420090'`、`node_id` 对应、`status='approved'`、`deploy_status='deployed'`（假节点返回 `ok:true`）。
4. `DB:` `local_link_address` = `fe80::1`（节点 ASN 派生，非对端 ASN）。
5. 假节点收到的请求报文满足：
   - `type='request'`、`command='peers.deploy'`、`id` 为 32 位 hex；
   - `payload.request_id` 非空且 ≤64 字符；
   - `payload.asn` = `4242420090`；
   - `payload.node` = 节点名；
   - `payload.protocol_name` 匹配 `^DN42_0090_[0-9a-f]{4}$`；
   - `payload.wireguard_config` 含 `PrivateKey = {{WIREGUARD_PRIVATE_KEY}}`、`ListenPort = 20090`、`Table = off`、`MTU = 1420`、`PostUp = ip addr add fe80::1/64 dev %i`；
   - `payload.bird_config` 含 `from dnpeers`、`neighbor fe80::90%DN42_0090 as 4242420090`、`source address fe80::1`、`enable extended messages on;`、`extended next hop on;`。
6. 创建后跳到 Peer 详情页，页面显示我方 endpoint / 我方公钥 / 对端应配的 BGP neighbor。
7. **重复创建**：同一 ASN 在同一节点再建一个 peer，返回错误页，文案包含"一个 ASN 每个节点只能有一个 peer"的意思。
8. **公钥非法**：填 43 字符，返回错误页，不写库。
9. **MTU 越界**：填 `1000`，返回错误页。
10. **三个地址全空**：返回错误页。
11. **节点被禁用**：把节点 `enabled=0`，再提交，返回错误页（`deploy_peer` 检查 `node.enabled`）。
12. **节点离线**：停掉假节点，再提交，返回错误页，文案含"节点离线/不可用"的意思，且 `deploy_status='failed'`。

> ⚠️ 断言 4 是 §7.2 的 ULA/link-local 分支陷阱：`local_link_address` 必须从**节点 ASN** 派生，不是对端 ASN。两条 ASN 恰好后 4 位相同时最容易写错。

#### 场景 E：编辑 Peer 并迁移节点

**前置**：场景 D 的 peer 存在；第二个节点 `test-node-2` 在线。

**步骤**：

1. `POST /portal/peers/{id}/edit`（或管理端 `POST /admin/peers/{id}`），把 `node_id` 改为 `test-node-2`、`wg_mtu` 改为 `1400`。

**断言**：

1. 假节点 1 收到 `peers.remove`，payload 的 `protocol_name` 等于旧值。
2. 假节点 2 收到 `peers.deploy`，`protocol_name` 等于**新值**（`peer.id` 不变则同名；若实现重新生成 id 则不同名，两种都可，但必须自洽）。
3. `DB:` `peer_requests.node_id` 已更新；`deploy_status` 以最后一次结果为准。
4. 新 WireGuard 配置含 `MTU = 1400`。
5. **旧节点移除失败**（假节点 1 设 `MODE=fail`）：编辑仍应完成，`DB:` 迁移成功，日志有 best-effort 清理失败的记录，**不应**回滚节点字段。
6. **新节点部署失败**：`DB:` `deploy_status='failed'`，但 `node_id` 仍指向新节点（不做事务回滚）。

> ⚠️ 断言 5/6 对应 §7.7 的"节点迁移快照陷阱"：必须先快照旧 node 再改字段，否则清理会打到新节点上。

#### 场景 F：禁用与删除

**前置**：场景 D 的 peer。

**步骤**：

1. 管理端把 peer `status` 改为 `disabled`。
2. 再改回 `approved` 并重新部署。
3. 门户删除该 peer。

**断言**：

1. 禁用时节点收到 `peers.remove`；`DB:` `status='disabled'`、`deploy_status='removed'`。
2. 禁用后该 peer **仍出现在** `/portal` 列表（软语义），但详情页显示已禁用。
3. 重新批准 + 部署时节点收到 `peers.deploy`，`deploy_status` 回到 `deployed`。
4. 删除（门户）时节点收到 `peers.remove`，`DB:` 该行**被物理删除**（`select count(*)` 减少 1）。
5. 删除后访问 `/portal/peers/{id}` 返回 `404`。
6. 管理端删除同样走硬删除（`delete_peer`）。

> ⚠️ 门户删除与"禁用"是两套语义，不要为了"安全"把门户删除改成软删除——否则 §15 的计数用例与 Bot 的 peer 选择菜单都会变。

#### 场景 G：Looking Glass

**前置**：节点在线；`LG_RATE_LIMIT=3`、窗口 10 秒。

**步骤**：

```bash
# G1 HTML 表单
curl -s -X POST http://127.0.0.1:8000/lg \
  -d "node_id=<node-uuid>&query_type=ping&target=1.1.1.1" | head -30

# G2 fetch 模式
curl -s -X POST http://127.0.0.1:8000/lg \
  -H "X-Requested-With: fetch" \
  -d "node_id=<node-uuid>&query_type=ping&target=1.1.1.1"

# G3 限流
for i in 1 2 3 4; do
  curl -s -o /dev/null -w "%{http_code}\n" -X POST http://127.0.0.1:8000/lg \
    -H "X-Requested-With: fetch" \
    -d "node_id=<node-uuid>&query_type=ping&target=1.1.1.1"
done
```

**断言**：

1. G1 返回 `200` + HTML 页面，页面含查询输出文本（不是 JSON）。
2. G2 返回 `200` + JSON，结构为 `{"ok": true, "output": "...", "query_type": "ping"}`。
3. G3 前 3 次 `200`，第 4 次 `429`；`429` 响应体是限流文案（HTML 或 JSON 取决于 `X-Requested-With`）。
4. **非法 target**（`1.1.1.1; rm -rf /`）：返回 `200`，但 `ok=false`、`output` 是统一校验失败文案；**不是 400**。
5. `DB:` 每次请求（含失败）都写一条 `lg_queries` 行，字段含 `node_id`、`query_type`、`target`、`ok`、`result`（截断后）、`created_at`，可能带 `user_id`；**没有 `client_ip` 列**。
6. **未知/禁用节点**：`node_id` 随便填，返回 `400`，文案含 `Unknown or disabled node`。
7. **节点返回 busy**（假节点 `MODE=busy`）：响应 `ok=false`、`output="node is busy, try again shortly"`，且**仍写审计**。
8. **节点超时**（`MODE=slow`）：约 12 秒后响应，`ok=false`，文案含超时含义，**不返回 500**。
9. **`query_type` 非法**（`query_type=shell`）：返回 `200` + `ok=false`，不触达节点（假节点不应收到请求）。
10. **route 查询主机名**（`query_type=route&target=example.com`）：返回 `ok=false`；`query_type=route&target=8.8.8.0/24` 正常。
11. **公开 LG 页**（`GET /lg` 未登录）：返回 `200`，节点下拉框只含 `enabled=1` 的节点。

#### 场景 H：Bot 创建流程

**前置**：真实 Bot token；测试群；该 Telegram UID 已通过 Kioubit Mini App 绑定到 ASN（或用 FindNOC）。

**步骤**：

1. `/create`
2. 依次发送：节点序号 → `skip`（endpoint）→ 公钥 → `172.20.99.1` → `fd00:99::1` → `skip`（link-local，走派生）→ `default`（MTU）→ `yes`（扩展）
3. 在确认块出现后发送确认。

**断言**：

1. `/create` 的回复列出节点，带序号（不是 UUID）。
2. 每一步都有提示文案；发 `/cancel` 可随时中断并回到空闲态。
3. 在任一文本步骤发送 `/start` 或其他命令，应提示"当前正在创建，先 /cancel"而**不是**把命令当输入（`reject_if_command`）。
4. `skip` 在 endpoint 步骤有效（= 空）；`default` 在 MTU 步骤 = `1420`。
5. 非法公钥：Bot 提示重新输入，**FSM 状态不变**（不前进也不退出）。
6. 确认块包含节点名、公钥、地址、MTU、扩展开关。
7. 确认后 `DB:` 新增 peer，`deploy_status='deployed'`。
8. 成功消息包含我方 endpoint / 公钥 / 隧道 IP / MTU（`peering_info` 的 7 个字段）。
9. **超过 4096 字符**的输出被分成多条消息，且每条都 `< 4096`，不出现半截代码块。
10. **部署失败**：消息中显示节点返回的 `output` 摘要（`detail_of`），而不是只显示"失败"。

#### 场景 I：Telegram 绑定与解绑

**前置**：UX 已绑定 ASN。

**步骤**：

1. `/listpeers` → 应有 peer。
2. `/logout`
3. `/listpeers`

**断言**：

1. `/listpeers` 输出按 peer 分块，每块含 BGP 状态摘要（`Established · routes X in / Y out` 或 `<state> — <error>`）、WireGuard 摘要（`no handshake yet` / `stale` / `interface down`）、我方参数。
2. `/logout` 后 `DB:` `telegram_bindings` 该 UID 的行被删除；`peer_requests` **不受影响**。
3. `/logout` 后再 `/listpeers` 提示需要先 `/login`。
4. 重新 `/login` 同一 ASN 后，peer 再次可见（因为归属 user 而非 Telegram）。

> ⚠️ 断言 2/3/4 是 §13/§14 强调的"Peer 归属 user 而非 Telegram"。把 peer 挂到 UID 上的实现会导致 `/logout` 后数据"消失"。

#### 场景 J：管理员节点运维

**前置**：管理员登录；节点 `test-node` 在线。

**步骤**：

1. `/admin/nodes` → 编辑节点，修改 `url`、`dn42_ipv4`、`dn42_ipv6`、`enabled`。
2. 点"刷新公钥"。
3. 点"重置 token"。
4. 用旧 token 重连假节点。
5. 用新 token 重连。

**断言**：

1. 节点在线时 `/admin/nodes` 显示上次心跳时间与系统信息。
2. 字段名是 **`url`**（不是 `endpoint`），提交后 `DB:` 对应列更新。
3. 刷新公钥后 `DB:` `nodes.wg_public_key` 更新为假节点回报值。
4. 重置 token 后 `DB:` token 变化；页面 flash **不显示新 token**（需另行查看，防止肩窥/日志泄漏）。
5. 旧 token 连接被拒；新 token 连接成功。
6. 禁用节点后，公开首页与 `/lg` 的节点列表都不再出现该节点。
7. `GET /admin` 概览页聚合 9 组数据（用户/peer/节点/部署失败/LG 等），任一为空时页面仍能渲染（不抛 500）。

### 15.3 协议与字段一致性对照

复刻时把这张表当成契约清单逐项打勾。任何一行不匹配，都会在某个链路上出问题。

#### 15.3.1 后端 → 节点（WSS 请求）

| 项 | 契约 | 违反后果 |
|---|---|---|
| 连接 URL | `wss://<host>/api/nodes/ws?name=<node>` | 连接 404 |
| 认证头 | `Authorization: Bearer <token>` | 403 |
| `type` | 固定 `"request"` | 节点丢弃 |
| `id` | `uuid4().hex`（32 位） | 后端无法配对响应，超时 |
| `command` | 8 个之一 | 节点返回 error 信封 |
| `payload` | JSON 对象（不是字符串） | 节点 `decodeCommandPayload` 报错 |
| deploy payload 字段 | `request_id` / `asn` / `node` / `protocol_name` / `wireguard_config` / `bird_config` | 节点校验失败 |
| remove payload 字段 | `request_id` / `protocol_name` | 同上 |
| status payload 字段 | `protocol_name` | 同上 |
| LG payload 字段 | `target` | 同上 |
| 空 payload | `{}` 或 `null` 均可（节点归一为 `{}`） | — |

#### 15.3.2 节点 → 后端（WSS 上行）

| 项 | 契约 | 违反后果 |
|---|---|---|
| `type` | `hello` / `heartbeat` / `response` | 后端忽略 |
| 首帧 | 必须是 `hello` | 后端可能不注册/不更新公钥 |
| hello 字段 | `public_key` + `system` | 公钥空 → 门户显示占位符 |
| heartbeat 周期 | 20s | 后端 60s 内无心跳视为离线 |
| `system` 字段 | `hostname`/`os`/`arch`/`uptime_seconds`/`load_*`/`cpu_percent`/`memory_*`/`network_*`/`goroutines`/`wireguard`/`bird` | 缺字段时后端容忍，但页面显示"未知" |
| `response.result` | 命令结果对象 | 后端拿不到结果 |
| `response.error` | 字符串 | 后端抛 `NodeRequestError` |

#### 15.3.3 状态码与文案

| 场景 | 状态码 | 关键文案（原实现，建议照抄） |
|---|---|---|
| `GET /lg` 未登录 | 200 | 公开页 |
| `POST /lg` 校验失败 | **200** | 统一校验失败文案，`ok=false` |
| `POST /lg` 未知/禁用节点 | 400 | `Unknown or disabled node` |
| `POST /lg` 触发限流 | 429 | `Too many looking glass queries. Please wait a moment and try again.` |
| `POST /lg` 节点超时 | 200 | 超时说明，`ok=false` |
| 门户创建成功 | 303/302 → `/portal` | — |
| 门户创建校验失败 | 200 | 错误页 + 字段级提示 |
| 门户创建节点离线 | 200 | 部署失败说明 |
| 访问他人 peer | 404 | 不区分"不存在"与"无权限" |
| 非管理员访问 `/admin` | 302 → `/`（或 403） | 与实现一致即可 |
| Bot API 缺 `X-Backend-Secret` | 401 | — |
| Bot API secret 错误 | 401 | 与缺失同响应，防枚举 |
| 节点 WSS token 错误 | 403 | 不泄漏"节点是否存在" |

> ⚠️ 最容易写错的是 `POST /lg` 校验失败返回 **200**。很多人会顺手改成 400；改了以后前端 fetch 分支会把错误当传输失败，页面不显示提示。

#### 15.3.4 命名一致性三件套

这三者在同一节点上必须**完全相等**，否则 `wg-quick` 与 BIRD 会对不上：

```text
WireGuard 接口名 = WireGuard 文件名（去 .conf）= BIRD protocol 名 = <protocol_name>
```

约束：

- `protocol_name = DN42_<ASN 后 4 位>_<peer.id 后 4 位>`
- 长度 14（`DN42_` 5 + 4 + 1 + 4），**严格小于 IFNAMSIZ 的 15**
- 必须匹配 `^[A-Za-z0-9_][A-Za-z0-9_-]{0,79}$`

> ⚠️ 只取 ASN 后 4 位会让 `AS4242425001` 与 `AS65001` 碰撞（同节点）。必须带 peer id 后缀。

### 15.4 数据不变量断言

这些是"数据库层面必须永远为真"的约束。建议写成 pytest fixture，在每个场景后跑一遍。

| # | 不变量 | 检查方式 |
|---|---|---|
| 1 | `users.primary_asn` 唯一 | `select primary_asn, count(*) from users group by 1 having count(*) > 1` 为空 |
| 2 | 一个 ASN 一个节点最多一个 peer | `select asn, node_id, count(*) from peer_requests group by 1,2 having count(*) > 1` 为空 |
| 3 | 每个 peer 的 `node_id` 指向存在的节点 | 左连接 `nodes` 检查 NULL |
| 4 | `telegram_bindings.telegram_user_id` 唯一；`user_id` 可重复 | 分组检查 |
| 5 | `peer_requests.user_id` 非空且存在 | 同上 |
| 6 | `local_link_address` 非空（创建成功后） | `where local_link_address is null or local_link_address=''` 为空 |
| 7 | `protocol_name` 派生唯一 | 按 `(node_id, peer_protocol_name)` 分组无重复 |
| 8 | `auth_challenges` 用过一次即 `consumed_at` 非空 | 抽查 |
| 9 | `lg_queries` 每次请求都有一行，且 `result` 长度受限 | 对比请求数与行数 |
| 10 | `nodes.token` 为 NULL 或非空，**不允许空字符串** | `where token=''` 为空 |

断言 10 值得单独强调：节点 token 为空会让 `compare_digest("", "")` 通过，形成"任意人用空 token 冒充该节点"的后门。原实现在认证查找时显式拒绝空 token。

### 15.5 回归测试清单（陷阱 → 断言）

把 §0–§14 各章"实现陷阱"逐条转成可验证断言。**每一条都能在 5 分钟内手工跑完**。

| # | 来源 | 断言 |
|---|---|---|
| 1 | §7.2 | ASN `4242420090` 创建 peer 时 link-local 空 → `fe80::90`（不是 `fe80::0090`，也不是 `fe80::4242420090`） |
| 2 | §7.2 | ASN `424242` 后缀为 `242` 时 → `fe80::242`（去掉 `424242` 前缀） |
| 3 | §7.2 | ULA 场景（`fd00::/8`）走另一分支，按 `/64` + ASN suffix 推导，结果与 link-local 分支不同 |
| 4 | §7.3 | WG 配置含 `Table = off`（否则 `wg-quick` 会抢默认路由） |
| 5 | §7.3 | `PostUp` 用 `%i` 而不是硬编码接口名 |
| 6 | §7.3 | 私钥是 `{{WIREGUARD_PRIVATE_KEY}}` 占位符，**不是**真实私钥 |
| 7 | §7.4 | link-local 邻居带 `%<protocol_name>` scope；ULA 邻居**不带** |
| 8 | §7.4 | `bgp_extended=false` 时无 `enable extended messages on;` 与 `extended next hop on;` |
| 9 | §7.6 | 部署前 `status` 必须是 `approved`；`pending`/`disabled` 被拒 |
| 10 | §7.6 | 部署后 `ok=true, applied=true` → `deploy_status='deployed'` |
| 11 | §7.6 | `ok=false, applied=true` → `deploy_status='failed'`（不能当成功） |
| 12 | §7.8 | tear down 成功 → `deploy_status='removed'`（第五种状态） |
| 13 | §7.8 | `remove_peer` **不检查** `node.enabled`（与 deploy 不同） |
| 14 | §7.9 | `preview_peer` 的临时对象**没有 id**，直接调 `peer_protocol_name` 会抛异常 |
| 15 | §8.6 | 在文本输入步骤发 `/start` 会被 `reject_if_command` 拦下 |
| 16 | §8.11 | 长输出按块切分，每块 ≤ 4096 字符，代码块围栏成对 |
| 17 | §8.8 | `peering_info` 的 7 个字段齐全，缺公钥时显示占位符而不是空串 |
| 18 | §9.3 | Bot API 的 `extra="forbid"` 拒绝未知字段（防悄悄传 `asn` 越权） |
| 19 | §9.8 | Bot 不自行解码 Kioubit JSON，只透传信封 |
| 20 | §10.2 | `/login` **没有 `next` 参数**；登录后固定去 `/portal` |
| 21 | §10.3 | 挑战的 `telegram_user_id` 必须与 Bot 报送的一致，否则拒绝 |
| 22 | §10.4 | FindNOC 只对 404/503 回退 Kioubit；500 必须报错 |
| 23 | §10.5 | 每次登录重算 `is_admin`；降权立即生效，提权等下次登录 |
| 24 | §11.2 | `render()` 的 `user` 由调用方传入，不自动查 session |
| 25 | §11.3 | flash 走 Cookie（<4KB），超长消息被丢弃而不是 500 |
| 26 | §11.6 | `/logout` 只清 `user_id`，不动 peer |
| 27 | §11.7 | `POST /portal/peers` 是**同步 `def`**（走 `request_node_sync`），不是 `async def` |
| 28 | §11.7 | `GET /portal/peers/{id}` 是**唯一 `async def`** 的门户读路由 |
| 29 | §11.8 | `LGQuery` **无 `client_ip` 列** |
| 30 | §11.9 | `kioubit-auth-btn` 是 **GET 表单**，无 `method="post"` |
| 31 | §12.1 | `ALLOWED_NETWORKS` 是全网（`0.0.0.0/0`、`::/0`），**不是**仅 dn42 |
| 32 | §12.1 | 校验顺序：长度 → 前导 `-`/危险字符 → 类型分支；不可重排 |
| 33 | §12.1 | `route` 接受 CIDR，`ping`/`trace`/`mtr` 不接受 CIDR（`ip_network` 与 `ip_address` 分支不同） |
| 34 | §12.2 | 限流在最前面（先于节点存在性检查） |
| 35 | §12.2 | 校验失败仍写审计 |
| 36 | §12.3 | 限流用 `time.monotonic()`，不是 `time.time()` |
| 37 | §12.3 | 多 worker 时阈值 × N（部署 1 worker 才能得到预期值） |
| 38 | §12.4 | 管理端 LG 日志按 50 条分页；截断在模板层不是 SQL 层 |
| 39 | §12.5 | `summarize_peer_bird` 的正则不跨行（`.*?` 不匹配 `\n`） |
| 40 | §12.5 | `summarize_wireguard` 把 `hour`/`day` 判为 `stale` |
| 41 | §12.6 | `route` 用 `birdc show route for`，不是 `show route` |
| 42 | §12.6 | `-6` 只对 IPv6 字面量加，主机名不加 |
| 43 | §13.3 | `readFrame` 在**分配内存前**检查 `maxFramePayload`（1MB） |
| 44 | §13.3 | 握手后复用同一个 `bufio.Reader`（否则吞掉后续帧） |
| 45 | §13.3 | `writeFrame` 有 `writeMu`（`handleRequest` 是 goroutine） |
| 46 | §13.3 | `heartbeatErr` 容量恰为 1 |
| 47 | §13.3 | 不支持分片（FIN=0 或 opcode=0 直接报错） |
| 48 | §13.4 | `tryAcquire` 非阻塞，满则返回 busy，不排队 |
| 49 | §13.4 | `deployMu` 由 deploy 与 remove 共用；部署**不占** LG 信号量 |
| 50 | §13.4 | `decodeCommandPayload` 拒绝未知字段与尾部数据 |
| 51 | §13.5 | `ensureChildPath` 用 `filepath.Rel`，不是字符串前缀比较 |
| 52 | §13.5 | `writeConfigFile` 临时文件在**同目录**；先 0600 后 0640 |
| 53 | §13.5 | `chownToGroup` 同时改目录与文件；WG 文件永不 chown |
| 54 | §13.5 | 节点 `command_timeout_seconds` 默认 **12 秒** |
| 55 | §13.6 | `wg-quick down` 传**文件路径**；`wg show` 传**接口名** |
| 56 | §13.6 | `RemovePeer` 先 `os.Stat` 再 down |
| 57 | §13.7 | CPU/内存/网络字段是 `*float64` + `omitempty`（区分 0% 与未知） |
| 58 | §13.7 | 内存已用 = `MemTotal - MemAvailable` |
| 59 | §13.7 | 状态输出按 **字节** 截断到 64 KiB，不是按字符 |
| 60 | §13.2 | `max_concurrency` 用 `*int`：nil→4、0→不限、负→4 |
| 61 | §13.2 | `bird_peer_group` 用 `*string`：nil→`bird`、`""`→不 chown |
| 62 | §14.2 | 后端任何响应中都不出现节点私钥 |
| 63 | §14.3 | Kioubit 的 `params` 用标准 `b64decode`，不是 urlsafe |
| 64 | §14.3 | 时间窗是**双向** 60 秒（未来时间戳也拒绝） |
| 65 | §14.3 | domain 用 `==` 比较，不是 `endswith` |
| 66 | §14.5 | 所有外部命令固定 argv，无 `shell=True` |
| 67 | §14.6 | SQLite 文件权限 0600（含节点 token） |
| 68 | §14.8 | 空 secret 也在黑名单里 |

### 15.6 冒烟脚本

一次跑完主链路，用于每次改动后的快速回归。**这是建议脚本，不是原仓库内容**。

```bash
#!/usr/bin/env bash
# tools/smoke.sh —— 需要先启动后端、假节点，并导出 TOKEN
set -euo pipefail
BASE=${BASE:-http://127.0.0.1:8000}
NODE_ID=${NODE_ID:?set NODE_ID}
JAR=$(mktemp)
fail() { echo "FAIL: $*"; exit 1; }
ok()   { echo "PASS: $*"; }

# 1 首页
[ "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/")" = 200 ] && ok "home" || fail "home"

# 2 LG 页
[ "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/lg")" = 200 ] && ok "lg page" || fail "lg page"

# 3 LG 查询（JSON）
R=$(curl -s -X POST "$BASE/lg" -H 'X-Requested-With: fetch' \
    -d "node_id=$NODE_ID&query_type=ping&target=1.1.1.1")
echo "$R" | grep -q '"ok": *true' && ok "lg query" || fail "lg query: $R"

# 4 非法 target 仍是 200 + ok=false
R=$(curl -s -w '\n%{http_code}' -X POST "$BASE/lg" -H 'X-Requested-With: fetch' \
    -d "node_id=$NODE_ID&query_type=ping&target=1.1.1.1%3B%20id")
echo "$R" | tail -1 | grep -q '^200$' && ok "lg invalid target 200" || fail "lg invalid status"
echo "$R" | grep -q '"ok": *false' && ok "lg invalid ok=false" || fail "lg invalid ok"

# 5 未知节点 400
[ "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/lg" \
     -d 'node_id=00000000-0000-0000-0000-000000000000&query_type=ping&target=1.1.1.1')" = 400 ] \
  && ok "unknown node 400" || fail "unknown node"

# 6 限流（沿用测试 .env 的 3/10s）
for i in 1 2 3; do curl -s -o /dev/null -X POST "$BASE/lg" \
  -H 'X-Requested-With: fetch' -d "node_id=$NODE_ID&query_type=ping&target=1.1.1.1"; done
[ "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/lg" \
     -H 'X-Requested-With: fetch' -d "node_id=$NODE_ID&query_type=ping&target=1.1.1.1")" = 429 ] \
  && ok "rate limit 429" || fail "rate limit"

# 7 Bot API 无 secret → 401
[ "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/telegram/challenge" \
     -H 'Content-Type: application/json' -d '{}')" = 401 ] \
  && ok "bot api 401" || fail "bot api 401"

rm -f "$JAR"
echo "smoke done"
```

### 15.7 负面与安全用例

| # | 用例 | 期望 |
|---|---|---|
| 1 | `target` 含换行/制表 | 拒绝（`\s` 在 `UNSAFE_TARGET_RE` 里） |
| 2 | `target` 以 `-` 开头（`-I /etc/passwd`） | 拒绝 |
| 3 | `target` 为 `$(id)` / 反引号包裹的命令 | 拒绝（`$` 与反引号都在字符集里） |
| 4 | `target` 长 300 字符 | 拒绝（>255） |
| 5 | `protocol_name` 为 `../../etc/passwd` | 节点拒绝（safeNameRE） |
| 6 | `bird_config` 含 NUL 字节 | 节点拒绝 |
| 7 | `bird_config` 20 KiB | 节点拒绝（>16 KiB） |
| 8 | 伪造 WSS `id` 的响应 | 后端不匹配，原请求超时，不串消息 |
| 9 | 同一节点开两条 WSS | 旧连接被 `fail_pending` + close 4000，不双写状态 |
| 10 | 用过期 token 连 WSS | 403 |
| 11 | Bot API 用 `=` 比较 secret（人为改坏） | 审计时能发现时序差（仅代码审查，不做时序攻击测试） |
| 12 | `findnoc` 返回 500 | 报错，不回退 |
| 13 | 挑战消费两次 | 第二次拒绝 |
| 14 | 跨用户访问 peer | 404 |
| 15 | 非管理员触发 redeploy | 拒绝 |

### 15.8 验收结论模板

复刻完成后按这个模板出具结论，每一项都必须有观测证据（截图/日志/SQL 输出）：

```text
复刻验收报告
────────────
基线：jasonxu114514/dn42 @ 4248b89
环境：后端 1 worker + 假节点 + 真实节点(VM) + 测试 Bot
────────────────────────────
[ ] 场景 A 冷启动与守卫            （证据：____）
[ ] 场景 B 节点连接与公钥          （证据：____）
[ ] 场景 C Web Kioubit 登录        （证据：____）
[ ] 场景 D 创建 Peer               （证据：____）
[ ] 场景 E 编辑迁移                （证据：____）
[ ] 场景 F 禁用与删除              （证据：____）
[ ] 场景 G Looking Glass           （证据：____）
[ ] 场景 H Bot 创建                （证据：____）
[ ] 场景 I 绑定与解绑              （证据：____）
[ ] 场景 J 管理员运维              （证据：____）
[ ] §15.3 字段对照全绿
[ ] §15.4 数据不变量全绿
[ ] §15.5 回归清单 68 条全绿
[ ] §15.7 负面用例 15 条全绿
────────────────────────────
结论：可上线 / 有条件上线（列出偏差）
```

> 允许存在的偏差：文案措辞、HTML 结构、CSS、日志格式。**不允许**的偏差：字段名、状态码、`ok`/`applied` 语义、`protocol_name` 派生、认证校验强度、文件权限、命令 argv。

---

## §16 运维手册

本章面向"复刻完成后要长期跑这套系统"的运维者。所有命令都假设后端装在工作目录 `/srv/dn42-autopeer`、节点服务在 `/opt/dn42-node`、均以 systemd 托管。

> 本章不含时间估算。所有"多久"都是**阈值/周期**，不是工期。

### 16.1 运行视图

#### 16.1.1 进程清单

| 单元 | 位置 | 用户 | 关键依赖 |
|---|---|---|---|
| `dn42-autopeer.service` | 后端主机 | 非 root（建议 `dn42`） | SQLite 可写、`app/keys/public_key.pem` 可读 |
| `dn42-bot.service` | 后端主机 | 同一非 root 用户 | 能访问 `TELEGRAM_BACKEND_URL` |
| `dn42-node.service` | 每台路由器 | **root** | `wg-quick`、`birdc`、`ip`、`ping`、`traceroute`、`mtr` |
| `nginx` / `caddy` | 后端主机 | root | 反代到 `127.0.0.1:8000` |

> ⚠️ 节点服务**必须** root：它要写 `/etc/wireguard`、`/etc/bird/peers` 并调用 `wg-quick`。后端则**不应** root：它只写数据库和 Cookie。

#### 16.1.2 目录与文件归属

| 路径 | 权限 | 所有者 | 内容 |
|---|---|---|---|
| `autopeer.db` | `0600` | 后端用户 | 全部业务数据（含节点 token） |
| `.env` | `0600` | 后端用户 | 秘密 |
| `app/keys/public_key.pem` | `0644` | 后端用户 | Kioubit 签名公钥（公开，无需保密） |
| `/etc/dn42-node/config.json` | `0600` | root | 节点 token + WG 私钥 |
| `/etc/wireguard/<name>.conf` | `0640` 或 `0600` | root | 含明文私钥 |
| `/etc/bird/peers/<name>.conf` | `0640` | `root:bird` | BIRD 片段 |

> ⚠️ 上线前跑一次 `find /etc/wireguard -perm -o+r`，输出必须为空。任何 world-readable 的 WireGuard 配置都等于私钥泄露。

### 16.2 日常巡检

#### 16.2.1 每班次（人工或脚本）

```bash
# 1 三个 unit 都在跑
systemctl is-active dn42-autopeer dn42-bot
ssh router1 systemctl is-active dn42-node

# 2 后端健康
curl -fsS -o /dev/null -w '%{http_code}\n' https://<domain>/          # 期望 200
curl -fsS -o /dev/null -w '%{http_code}\n' https://<domain>/lg        # 期望 200

# 3 节点在线数 vs 总数
sqlite3 /srv/dn42-autopeer/autopeer.db \
  "select count(*) as total, sum(enabled) as enabled from nodes;"

# 4 最近 24h 部署失败
sqlite3 /srv/dn42-autopeer/autopeer.db \
  "select count(*) from peer_requests
   where deploy_status='failed' and updated_at > datetime('now','-1 day');"

# 5 磁盘与库大小
df -h / /var
ls -lh /srv/dn42-autopeer/autopeer.db

# 6 节点上的隧道数量
ssh router1 'wg show interfaces; birdc show protocols | grep -c BGP'
```

#### 16.2.2 建议的巡检周期表

| 项 | 周期 | 阈值/判据 |
|---|---|---|
| 磁盘使用率 | 每日 | >80% 告警；SQLite 增长过快查 `lg_queries` |
| 节点离线 | 每分钟（监控） | 任一 `enabled` 节点离线 >2 分钟告警 |
| 部署失败率 | 每小时 | 1 小时内 `failed` >3 条告警 |
| LG 429 比例 | 每小时 | >20% 说明被打或限流过严 |
| 证书到期 | 每周 | <30 天告警 |
| 备份成功 | 每日 | 文件大小 >0 且可 `pragma integrity_check` |

### 16.3 日志与关键事件

#### 16.3.1 日志来源

| 来源 | 位置 | 关注点 |
|---|---|---|
| 后端 | `journalctl -u dn42-autopeer` | 启动守卫、认证失败、节点连接/断开、部署异常 |
| Bot | `journalctl -u dn42-bot` | Telegram API 错误、后端 5xx |
| 节点 | `journalctl -u dn42-node` | WSS 重连、命令失败、部署错误 |
| nginx | `/var/log/nginx/access.log` | `/lg` 的 429、异常 UA |
| BIRD | `birdc show protocols all` | BGP 会话状态 |

#### 16.3.2 应当能找到的关键事件

认证类：

```text
# 成功
kioubit login: asn=4242420090 user_id=12
# 失败（必须能区分原因，但不泄漏签名）
kioubit login failed: invalid signature
kioubit login failed: token expired
kioubit login failed: domain mismatch
kioubit login failed: challenge purpose mismatch
```

节点类：

```text
node connected: name=sin1
node disconnected: name=sin1
node auth failed: name=sin1 reason=bad-token
node replaced existing connection: name=sin1
```

部署类：

```text
deploy peer: asn=4242420090 node=sin1 protocol=DN42_0090 ok=true applied=true
deploy peer: asn=4242420090 node=sin1 protocol=DN42_0090 ok=false applied=true
```

> ⚠️ 日志里**绝对不能**出现：节点 token、WG 私钥、`params`/`signature` 原文、session cookie、`X-Backend-Secret`。审查日志时用 `grep -iE 'token|private|secret|signature'` 抽查。

#### 16.3.3 审计数据（数据库侧）

| 表 | 用途 | 保留建议 |
|---|---|---|
| `lg_queries` | LG 查询审计 | 30–90 天，按需归档 |
| `asn_identities` | 登录证明历史 | 永久（量很小） |
| `peer_requests.deploy_output` | 最后一次部署输出 | 随 peer 生命周期 |

### 16.4 故障排查决策树

按"用户看到什么"反查，比按模块查快。

#### 16.4.1 后端起不来

```text
后端退出 / 502
├─ 日志含 "insecure"/"placeholder"/"refuse"
│   └─ SESSION_SECRET 或 TELEGRAM_BACKEND_SECRET 是黑名单值
│       → 换强随机值；本地调试可 --allow-http
├─ 日志含 "no such table"
│   └─ DATABASE_URL 指向了空库且 init_db 未跑
│       → 确认 DATABASE_URL 路径；检查目录可写
├─ 日志含 "Address already in use"
│   └─ 端口被占 → ss -ltnp | grep 8000
├─ 日志含 "Kioubit public key"
│   └─ app/keys/public_key.pem 缺失或不是 EC 公钥
└─ 无日志直接退出
    └─ 依赖缺失 → pip install -r requirements.txt；检查 Python 版本
```

#### 16.4.2 登录不成功

```text
点 Kioubit 按钮后回到错误页
├─ "Invalid Kioubit signature"
│   └─ 公钥不是当前 Kioubit 的；或 params 被中间层改过（WAF/编码）
├─ "token has expired"
│   └─ 服务器时间偏差 >60s → 校时（chrony/NTP）
├─ "issued for a different domain"
│   └─ DOMAIN 与 Kioubit 后台登记的回调域名不一致
├─ "Unknown auth challenge"
│   └─ 打开登录页的浏览器与回调的浏览器不是同一个（cookie 丢失）
│       → 检查 SameSite/Secure 设置；确认走 HTTPS
└─ "challenge has expired"
    └─ 停在登录页超过 600 秒 → 刷新重来
```

#### 16.4.3 节点一直离线

```text
/admin/nodes 显示离线
├─ 节点日志 "unauthorized" / "403"
│   └─ token 不匹配 → 在 Admin 重置 token 并同步 config.json
├─ 节点日志 "dial tcp ... timeout"
│   └─ 出网被拦 / DNS / 防火墙 → 在节点上 curl -I https://<domain>/
├─ 节点日志 "tls: failed to verify certificate"
│   └─ 证书链不全 / 系统 CA 过旧 → 更新 ca-certificates
├─ 节点日志 "websocket handshake" 相关
│   └─ 反代未转发 Upgrade/Connection 头 → 修 nginx 配置
├─ 节点从未打印连接日志
│   └─ backend_wss_url 为空或 name 为空 → 启动时应已 fatal，检查 unit 环境
└─ 日志显示反复 "disconnected" 每 5 秒
    └─ 后端主动关闭：name 不存在 / 已被禁用 / token 错
```

> ⚠️ 后端把"节点不存在"与"token 错误"表现为同一个 403，这是刻意的防枚举。排查时**不要**期望从状态码区分，直接比对数据库里的 `name`/`token`。

#### 16.4.4 Peer 创建失败

```text
提交创建表单 → 错误页
├─ "公钥"相关
│   └─ 必须是 44 字符 base64；末尾 "=" 不能丢
├─ "MTU"相关
│   └─ 1280–9000 的整数
├─ "已存在"
│   └─ 同 ASN 同节点已有 peer（DB 唯一约束）→ 编辑现有 peer
├─ "节点不可用"/"offline"
│   └─ 节点不在线 → 先修节点
└─ "部署失败" + 节点 output
    ├─ 含 "missing private key"
    │   └─ 节点 config.json 的 wireguard_private_key 为空
    ├─ 含 "Permission denied" 且提到 bird
    │   └─ bird_peer_group 与实际 BIRD 用户组不符
    ├─ 含 "wg-quick up" 失败
    │   └─ 端口冲突（同 ASN 已有其他 peer 占用 20090）或内核模块缺失
    └─ 含 "timed out"
        └─ 见 16.4.6 超时对齐
```

#### 16.4.5 BGP 不 Established

```text
Peer 详情页 BGP 状态非 Established
├─ WireGuard 摘要 = "interface down"
│   └─ 隧道没起来 → 节点上 wg show <iface>；wg-quick up <file>
├─ WireGuard 摘要 = "no handshake yet"
│   └─ 对端未发起/未响应 → 检查对端 Endpoint、公钥、防火墙 UDP
├─ WireGuard 摘要 = "stale"
│   └─ 握手超过 1 小时 → 对端掉线或路由问题
├─ 隧道 OK 但 BGP Idle/Active
│   ├─ Active（TCP 连不上）
│   │   └─ link-local scope 错（缺 %<iface>）或 source address 不匹配
│   ├─ Idle（拒绝）
│   │   └─ 对端 ASN 不匹配 / BIRD 模板未 include
│   └─ Connect/OpenSent 卡住
│       └─ MTU 不一致（尤其开了 extended messages）
└─ BGP Established 但无路由
    └─ import/export 过滤器 / `extended next hop` 开关与对端不一致
```

#### 16.4.6 部署超时（后端 20s vs 节点最坏 36s）

这是 §13.5 已标注的**已知不一致**：

```text
后端 deploy_peer timeout = 20s
节点最坏路径：wg-quick down(12s) + wg-quick up(12s) + reload(12s) = 36s
```

后果：节点实际成功，但后端已超时并把 peer 标记为 `failed`。

排查特征：

- 后端日志有超时，节点日志显示 `wg-quick up` 正常完成。
- `DB:` `deploy_status='failed'`，但节点上文件存在且 `wg show` 有接口。

处理：

1. 短期：在管理端点"重新部署"（幂等：`wg-quick down` 后再 up）。
2. 中期：把节点的 `command_timeout_seconds` 调小（如 6），让 3 条命令的最坏值 18s < 20s。
3. 长期：按 §18.2 把后端超时提到 40s 以上，或把部署改为异步任务。

> ⚠️ 不要只调大后端超时而不管节点：若节点某条命令真的挂住，超时越长占用 `deployMu` 越久，会阻塞该节点的所有部署。

### 16.5 备份与恢复

#### 16.5.1 备份对象

| 对象 | 必要性 | 说明 |
|---|---|---|
| `autopeer.db` | **必须** | 用户、peer、节点 token |
| `.env` | **必须** | `SESSION_SECRET` 丢失会导致所有会话失效（可接受），`TELEGRAM_BACKEND_SECRET` 丢失需同步改 bot |
| 节点 `config.json` | **必须** | 含 WG 私钥；丢失需重新生成密钥并更新对端 |
| `app/keys/public_key.pem` | 建议 | 可从 Kioubit 重新获取 |
| BIRD 主配置 | 建议 | 不在本系统管理，但恢复节点时需要 |
| 反代配置 | 建议 | — |

> ⚠️ `autopeer.db` 与 `config.json` 都是**秘密载体**。备份文件必须加密（`age`/`gpg`）或放在访问受控的存储，不能扔进公开的对象存储。

#### 16.5.2 SQLite 一致性备份

**不能**直接 `cp` 正在写入的 SQLite（可能拿到半页）。三种正确方式：

```bash
# 方式 1：在线备份 API（推荐）
sqlite3 /srv/dn42-autopeer/autopeer.db ".backup '/backup/autopeer-$(date +%F).db'"

# 方式 2：VACUUM INTO（生成紧凑副本，SQLite ≥ 3.27）
sqlite3 /srv/dn42-autopeer/autopeer.db \
  "VACUUM INTO '/backup/autopeer-$(date +%F).db';"

# 方式 3：短暂停服后 cp（可接受，但有停机）
systemctl stop dn42-autopeer && cp autopeer.db /backup/ && systemctl start dn42-autopeer
```

备份后立刻校验：

```bash
sqlite3 /backup/autopeer-2026-10-23.db "pragma integrity_check;"   # 期望 ok
sqlite3 /backup/autopeer-2026-10-23.db "select count(*) from peer_requests;"
```

#### 16.5.3 恢复顺序

恢复必须按依赖顺序，否则外键与 token 会不一致：

```text
1. 停 bot（避免它在此期间调用 API）
2. 停后端
3. 还原 .env
4. 还原 autopeer.db（并 chmod 0600、chown 后端用户）
5. 启动后端，确认 / 返回 200、/admin 能登录
6. 还原节点 config.json（chmod 0600、root）
7. 逐个重启 dn42-node，确认 /admin/nodes 变在线
8. 启动 bot
9. 抽查 3 个 peer 的详情页与 BGP 状态
```

> ⚠️ 如果只恢复了数据库但**没恢复** `SESSION_SECRET`，所有用户会被登出（可接受）；如果只恢复了 `.env` 但数据库是旧的，节点 token 会与节点侧不一致 → 所有节点离线。两者必须成对恢复。

#### 16.5.4 单节点重建

节点机器损毁后：

1. 在管理端**不要**删除该节点记录（保留 peer 归属与历史）。
2. 新机器装依赖、放 `config.json`（沿用原 token 或重置 token 后同步）。
3. 启动节点服务，等 `/admin/nodes` 变在线。
4. 在 `/admin/peers` 里对该节点的每个 peer 点"重新部署"，把配置写回去。
5. 核对 `wg show` 与 `birdc show protocols` 数量与 peer 数一致。

> ⚠️ 节点上的 WireGuard 私钥若未备份，必须重新生成 `wg genkey`，并把新公钥告知所有对端——这是不可自动化的部分。

### 16.6 升级与回滚

#### 16.6.1 数据库 schema 的现实

原实现**没有迁移框架**（无 Alembic）。`create_schema()` 做三件事：

1. `Base.metadata.create_all` —— 只建缺失的表；
2. `_ensure_node_columns` / `_ensure_peer_request_columns` —— 用 `ALTER TABLE ADD COLUMN` 幂等补齐后加的列；
3. `_ensure_indexes` —— 幂等建索引。

这意味着：

- **加列**安全（重启即补）。
- **改列类型 / 删列 / 改约束**不安全，需人工迁移。
- **重命名表**不安全。

复刻时若想加迁移框架，建议在 §17 的 M2 阶段就引入，避免后期补。

#### 16.6.2 后端升级步骤

```bash
cd /srv/dn42-autopeer
git fetch && git checkout <tag>
python3 -m pip install -r requirements.txt
# 先备份
sqlite3 autopeer.db ".backup '/backup/pre-upgrade.db'"
systemctl restart dn42-autopeer
# 观察 30 秒
journalctl -u dn42-autopeer -n 50 --no-pager
curl -fsS -o /dev/null -w '%{http_code}\n' https://<domain>/
```

回滚：

```bash
git checkout <previous-tag>
systemctl restart dn42-autopeer
# 只有当新版本做了不兼容 schema 变更时才需要还原数据库
```

> ⚠️ `create_all` 不会删列，所以"升级后再回滚代码"通常仍可运行；但如果你手工删过列，回滚会 500。

#### 16.6.3 节点滚动升级

节点服务是**独立二进制**，可以逐台升级，后端无感：

```bash
# 在构建机
go build -trimpath -ldflags="-s -w" -o dn42-node ./cmd/node

# 逐台
scp dn42-node router1:/opt/dn42-node/dn42-node.new
ssh router1 'systemctl stop dn42-node && \
  mv /opt/dn42-node/dn42-node /opt/dn42-node/dn42-node.old && \
  mv /opt/dn42-node/dn42-node.new /opt/dn42-node/dn42-node && \
  chmod 0755 /opt/dn42-node/dn42-node && \
  systemctl start dn42-node'
ssh router1 'systemctl is-active dn42-node && journalctl -u dn42-node -n 20 --no-pager'
```

每次只升一台，观察 `/admin/nodes` 该节点恢复在线，再做下一台。

> ⚠️ 新旧节点服务可以同时连同一后端（协议向后兼容的前提是**不删字段、不改语义**）。若必须破坏兼容，先升后端到兼容双版本，再滚节点。

#### 16.6.4 二进制与配置的兼容矩阵

| 改动 | 需要同时升级后端？ | 需要同时升级节点？ |
|---|---|---|
| 新增可选 payload 字段 | 否（节点忽略未知字段？**不行**，`DisallowUnknownFields` 会拒绝） | **是** |
| 新增可选响应字段 | **是**（旧后端忽略） | 否 |
| 修改文案 | 否 | 否 |
| 修改 `protocol_name` 规则 | **是** | **是** |
| 修改 `{{WIREGUARD_PRIVATE_KEY}}` 占位符 | **是** | **是** |

> ⚠️ 第一行是陷阱：节点侧 `decodeCommandPayload` 用 `DisallowUnknownFields`，后端**不能**先发新字段。必须先升级节点，再升级后端。

### 16.7 扩容

#### 16.7.1 后端多 worker

现状：

- 会话是签名 Cookie → 无服务端状态 → **可以**多 worker。
- 节点 WSS 连接保存在**进程内存** → **不可以**多 worker，否则节点只连到其中一个 worker，其他 worker 认为它离线。
- LG 限流是**进程内** → 多 worker 时实际阈值 × N。

结论：

| 场景 | 建议 |
|---|---|
| 单机、节点数 <50、LG 流量小 | **1 worker**，最简单 |
| 需要多 worker | 必须先把 `NodeHub` 外置（Redis pub/sub 或 sticky routing），否则节点状态不一致 |
| 只读扩容 | 不适用（SQLite + 内存态） |

> ⚠️ 复刻时如果直接上 `--workers 4`，会出现"节点时好时坏"——因为每次请求可能打到没有该连接的 worker。这是最容易踩的扩容坑。

#### 16.7.2 节点数增长

单节点连接的开销：一个 WSS + 每 20s 一次心跳 + 每 60s 两次子进程（`wg show`、`birdc`）。

| 节点数 | 关注点 |
|---|---|
| <20 | 无特殊问题 |
| 20–100 | 后端事件循环压力可忽略；注意心跳 `system_status_json` 写入频次 |
| >100 | 每次心跳都写库会成为瓶颈 → 加"仅状态变化时写"或降频 |
| >500 | 单进程 `NodeHub` 字典 + 单 SQLite 写入不够 → 需要外置状态与连接网关 |

#### 16.7.3 换 PostgreSQL

SQLAlchemy URL 改成 `postgresql+psycopg://...` 后仍能跑，但需要处理：

1. `init_db` 的 `ALTER TABLE ... ADD COLUMN` 方言差异（多数兼容）。
2. `Boolean` 默认值 `1` → 改成 `true`（`_ensure_*_columns` 里写死了 `DEFAULT 1`）。
3. SQLite 的 `datetime('now')` 运维查询要改成 `now()`。
4. 唯一约束与索引需重建。

> **建议**：若一开始就打算用 Postgres，在 M2 阶段直接选它，别先 SQLite 后迁移。

### 16.8 监控与告警

#### 16.8.1 最小指标集

后端侧（可从数据库/日志派生，无需改代码）：

| 指标 | 计算 | 告警建议 |
|---|---|---|
| `nodes_total` / `nodes_enabled` | `select count(*) ...` | — |
| `nodes_online` | 内存态或"最近 60s 有心跳" | 任一 enabled 离线 >2min |
| `peers_total` | `select count(*)` | — |
| `deploy_failed_1h` | `deploy_status='failed'` 且 `updated_at` 近 1h | >3 |
| `lg_429_ratio` | 日志中 429 / 总数 | >20% |
| `lg_latency_p95` | 反代日志 | >15s |
| `db_size_bytes` | 文件大小 | 日增 >50MB |
| `auth_fail_1h` | 日志计数 | 突增 10 倍 |

#### 16.8.2 建议加埋点（复刻时可做）

原实现没有 `/metrics`。若要做，最小暴露：

```text
dn42_nodes_total{enabled="true|false"}
dn42_nodes_online
dn42_peers_total{status="approved|pending|disabled"}
dn42_deploy_total{result="ok|failed"}
dn42_lg_requests_total{query_type="ping|trace|mtr|route",result="ok|error|busy|timeout"}
dn42_lg_rate_limited_total
dn42_node_heartbeat_age_seconds{node="sin1"}
```

> ⚠️ 指标标签**不要**带 `target` 或 `asn`，否则基数爆炸。`node` 标签可以带，但节点数需可控。

#### 16.8.3 外部黑盒监控

| 探针 | 期望 |
|---|---|
| `GET /` | 200，响应体含站点名 |
| `GET /lg` | 200 |
| `POST /lg`（固定合法 target） | 200 且 `ok=true`（需处理限流：探针用独立 IP 或调低频率） |
| TCP 443 | 可连，证书有效 |
| 节点 SSH | 可连（用于确认机器存活，不替代 WSS 检测） |

> ⚠️ 用 `POST /lg` 做探针会消耗限流额度，可能把真实用户挤掉。要么单独豁免探针 IP（需改代码），要么降低探测频率到窗口阈值以下。

### 16.9 应急响应

#### 16.9.1 场景：节点 token 泄露

影响：攻击者可冒充该节点连上 WSS，**接收**后端下发的全部 peer 配置（含对端公钥、地址），并**返回**伪造的部署结果与 LG 输出。

处置：

```text
1. Admin > Nodes 重置该节点 token
2. 更新节点 config.json 的 token，重启 dn42-node
3. 确认旧连接已断（/admin/nodes 短暂离线后恢复在线）
4. 审计：检查该节点在此期间是否有异常 deploy 记录
5. 评估：攻击者已获取该节点上所有 peer 的对端公钥与地址（非私钥）
```

> 注意：token 泄露**不会**泄露 WG 私钥（私钥只在节点本地，后端只存占位符）。但会泄露"本节点上与哪些 ASN 建了 peer"，属于隐私面。

#### 16.9.2 场景：WireGuard 私钥泄露

影响：攻击者可解密/注入该节点的所有隧道流量。

```text
1. 在节点上生成新密钥：wg genkey | tee priv | wg pubkey > pub
2. 更新节点 config.json 的 wireguard_private_key / wireguard_public_key
3. 重启节点，等后端刷新公钥（Admin > 刷新公钥）
4. 对每个 peer 重新部署 —— 对端必须同步改成我们的新公钥
5. 通知所有对端（无法自动完成，这是人工步骤）
```

> ⚠️ 换公钥后**所有对端**的 `[Peer] PublicKey` 都要改，否则隧道不通。这是运维上最痛的操作，应尽量避免（限制私钥文件的读取面）。

#### 16.9.3 场景：后端被攻破

攻击者拿到后端 = 拿到所有节点 token + 能下发任意配置到所有节点。这是**最高危**场景。

```text
1. 立刻停后端与 bot
2. 在每台节点上停 dn42-node（阻断后续命令）
3. 重置所有节点 token
4. 轮换 SESSION_SECRET / TELEGRAM_BACKEND_SECRET
5. 检查每台节点的 /etc/bird/peers/*.conf 是否被注入（BIRD include 可读任意文件）
6. 检查 /etc/wireguard/*.conf
7. 从备份重建后端，逐台恢复节点
8. 审计 lg_queries 与 access.log
```

> ⚠️ 这就是 §14.5.3 强调"BIRD 配置内容不校验"的后果：后端被攻破时，攻击者可以在 `bird_config` 里塞 `include "/etc/shadow";` 之类的内容，让 BIRD 读出敏感文件并通过协议/日志外泄。复刻时建议优先修这个缺口。

#### 16.9.4 场景：LG 被打

特征：`429` 比例飙升、CPU 高、`lg_queries` 快速增长。

```text
1. 立即在反代层加限流（nginx limit_req），比应用层更早拦截
2. 临时把 LG_RATE_LIMIT 调低并重启（注意是多 worker 时 × N）
3. 若单一 IP：反代封禁该 IP
4. 若分布式：加验证码或关闭公开 LG（把路由下线）
5. 事后：给 LGQuery 加 client_ip 列（§18.2 P1）
```

#### 16.9.5 场景：节点失联但机器活着

```text
1. ssh 上去，systemctl status dn42-node
2. 看日志是否在 5 秒循环重连
3. curl -I https://<domain>/api/nodes/ws?name=<node>   # 期望 403/426，不是超时
4. 若 TLS 失败：openssl s_client -connect <domain>:443 -servername <domain>
5. 若 403：token 不匹配（可能刚轮换过）
6. 若 404：反代路径没转发到后端
```

#### 16.9.6 场景：磁盘写满

```text
1. df -h 找分区
2. 最大嫌疑：lg_queries 表、journal 日志、SQLite WAL
3. 立即：journalctl --vacuum-size=200M
4. 清理 lg_queries 旧数据：
   delete from lg_queries where created_at < datetime('now','-30 day');
   vacuum;   -- 注意：需要额外磁盘空间，空间不足时改用增量删除
5. 长期：加归档任务
```

> ⚠️ `vacuum` 需要约等于数据库大小的临时空间。磁盘已满时它会失败，先删一部分行腾出空间再 vacuum。

### 16.10 变更 SOP

#### 16.10.1 新增节点

```text
1. 在路由器上装 wireguard-tools、bird2、iproute2、ping、traceroute、mtr
2. 生成密钥：wg genkey | tee /etc/dn42-node/priv | wg pubkey
3. Admin > Nodes > 新增：name / location / url / asn / dn42_ipv4 / dn42_ipv6
4. 记录生成的 token（只显示一次或需另行查看）
5. 写 /etc/dn42-node/config.json（0600，root）
6. systemctl enable --now dn42-node
7. 确认 /admin/nodes 变在线、wg_public_key 已上报
8. 在 BIRD 主配置确认 include 了 bird_peer_dir
9. 建一个测试 peer，验证 wg-quick 与 birdc 正常
```

#### 16.10.2 下线节点

```text
1. 先确认该节点上的 peer 数：select count(*) from peer_requests where node_id=...
2. 逐个把 peer 迁到其他节点（编辑 peer 的 node_id）或删除
3. 确认节点上 wg show interfaces 为空
4. Admin > Nodes 把 enabled 关掉（先隐藏，不删）
5. 观察一个周期，确认无引用
6. 再删除节点记录（或保留作为历史）
```

> ⚠️ 直接删 `nodes` 行会因为 `peer_requests.node_id` 外键而失败（或留下悬空引用，取决于是否开了外键约束）。先迁 peer。

#### 16.10.3 轮换 secret

| secret | 影响 | 步骤 |
|---|---|---|
| `SESSION_SECRET` | 所有浏览器会话失效 | 改 `.env` → 重启后端 → 用户重新登录 |
| `TELEGRAM_BACKEND_SECRET` | bot 与后端失联 | 改 `.env` → 重启后端 → 改 bot 环境 → 重启 bot |
| 节点 token | 该节点短暂离线 | Admin 重置 → 改节点 config → 重启节点 |
| Kioubit 公钥 | 所有登录失效 | 替换 `public_key.pem` → 重启后端 |

> ⚠️ `SESSION_SECRET` 与 `TELEGRAM_BACKEND_SECRET` 必须**分别**是强随机值。用 `python -c "import secrets; print(secrets.token_urlsafe(32))"` 生成；不要复用同一个值。

#### 16.10.4 修改 `LOCAL_ASN`

影响：管理员判定规则变化（`is_admin = asn == LOCAL_ASN`）。

```text
1. 确认新 ASN 已在 users 表里存在（该 ASN 的用户需先登录过一次）
2. 改 .env 的 LOCAL_ASN
3. 重启后端
4. 用新 ASN 登录一次（触发 is_admin 重算）
5. 确认能进 /admin；旧管理员下次登录时会被降权
```

> ⚠️ `is_admin` 只在**登录时**重算。改完 `LOCAL_ASN` 后，已在线的旧管理员在本次会话内仍是管理员（因为在线的 `current_user` 是每请求查库，`is_admin` 字段已是 True）。若要立即生效，需清 `users.is_admin` 或等其重新登录。详见 §11.6.1 的说明。

#### 16.10.5 封禁用户

原实现**没有**封禁字段。可用最小侵入方式：

```sql
-- 1. 把该用户所有 peer 置为 disabled 并记备注
update peer_requests set status='disabled', admin_note='banned: <reason>'
 where user_id = (select id from users where primary_asn='4242420090');

-- 2. 删除 Telegram 绑定，阻断 bot 侧操作
delete from telegram_bindings
 where user_id = (select id from users where primary_asn='4242420090');
```

> ⚠️ 用户仍可通过 Kioubit 重新登录并创建新 peer。真正的封禁需要在认证入口加"ASN 黑名单"（§18.4 建议项）。

### 16.11 运维检查表（上线后首周）

- [ ] 三个 unit 都设了 `Restart=always` 且验证过 kill 后自愈
- [ ] 后端 1 worker（或已确认多 worker 的节点连接问题已解决）
- [ ] `autopeer.db`、`.env`、节点 `config.json` 均 0600
- [ ] `/etc/wireguard` 无 world-readable 文件
- [ ] 反代已转发 WebSocket Upgrade 头
- [ ] `FORWARDED_IP_HEADER` 与 nginx 实际头名一致（且用 `$remote_addr` 不是 `$proxy_add_x_forwarded_for`）
- [ ] 证书自动续期可用
- [ ] 备份任务已跑成功至少一次，并做过一次**演练恢复**
- [ ] `lg_queries` 有清理/归档策略
- [ ] 至少一台节点做过"kill -9 后自动重连"演练
- [ ] 至少一个 peer 做过"编辑迁移节点"演练
- [ ] 日志抽查过，无 token/私钥/signature 泄漏

---

## §17 实施阶段与复刻路线

本章把 §0–§16 的内容拆成可交付的里程碑。每个里程碑都有**明确的完成判据**，做完就能跑对应验收用例。

### 17.1 里程碑总览

| 里程碑 | 名称 | 交付物 | 完成判据 | 依赖 |
|---|---|---|---|---|
| M0 | 骨架与配置 | 目录结构、`Settings`、`init_db`、lifespan、`start.py` | 后端能空跑，7 张表建好，不安全的 secret 被拒 | 无 |
| M1 | 数据模型与查询 | 7 个 ORM 模型、`queries.py` 常用查询 | 能手工 INSERT 出 user/node/peer 并在 SQL 中查到 | M0 |
| M2 | 配置渲染与校验 | `peer/validation.py`、`peer/config.py` | 给定固定输入，渲染出的 WG/BIRD 片段与 §7.3/§7.4 逐字一致 | M1 |
| M3 | 节点协议（假节点驱动） | `node_ws.py`、`NodeHub`、Go 侧 WSS 客户端 | 假节点能连上、心跳、被请求、回响应；超时与错误分类正确 | M0 |
| M4 | 部署编排 | `peer/deploy.py`、`peer/service.py`、Go 侧 `DeployPeer`/`RemovePeer` | 创建/编辑/删除能落盘并 `wg-quick up/down` 成功 | M2+M3 |
| M5 | 认证 | `auth/*`、三张身份表、Kioubit 验签、FindNOC | 三条登录路径都能产出 `users` 行；管理员判定正确 | M1 |
| M6 | Web UI | 35 条路由、模板、静态资源 | §15 场景 C/D/E/F/J 全绿 | M4+M5 |
| M7 | Bot 与 Bot API | `bot/main.py`、`api/telegram.py`、12 个端点 | §15 场景 H/I 全绿 | M4+M5 |
| M8 | Looking Glass | `lg/*`、`web/lg.py`、Go 侧 4 个 LG 命令 | §15 场景 G 全绿 | M3 |
| M9 | 加固与验收 | 安全清单、监控、备份、文档 | §15.4/15.5/15.7 全绿 | 全部 |

> **建议**：M3 必须在 M4 之前完成。先有协议再有部署，否则你会用"直接在 Python 里调 `subprocess`"的方式临时凑，最后被迫重写。

### 17.2 关键取舍

#### 17.2.1 先协议，后 UI

顺序 `M3 → M4 → M6` 而不是 `M6 → M4 → M3`。理由：

- UI 是最容易"看起来做完了"的部分，但它只调用服务层；
- 协议错了，UI 做得再漂亮也部署不到节点；
- 假节点（§15.1.3）让你在没有 UI 时就能验证协议。

#### 17.2.2 渲染函数先于编排

`render_wireguard_peer_config` / `render_bird_peer_config` 是**纯函数**：输入 ORM 对象，输出字符串。先把它们做到逐字正确，再写 `deploy_peer`。

理由：部署失败时你无法区分"配置内容错"还是"传输/落盘错"。纯函数先固化内容，能把两类问题分开。

#### 17.2.3 schema 先定，别边写边加列

原实现是边写边加列（`_ensure_*_columns` 就是化石证据）。复刻时有两条路：

| 路线 | 做法 | 适合 |
|---|---|---|
| A. 照抄原实现 | `create_all` + 幂等 `ALTER` | 想快速对齐行为 |
| B. 一次定稿 + 迁移工具 | 一开始就把所有列写全，用 Alembic | 想长期维护 |

**建议 B**：原实现的列已经是最终形态，直接照 §4.2 一次建全，再加 Alembic 初始版本即可。

#### 17.2.4 单 worker 起步

M0–M8 全部用 `--workers 1`。多 worker 的问题（节点连接状态、限流阈值）留到 §18 解决，不要一开始就上。

### 17.3 各阶段任务清单

#### M0 骨架与配置

- [ ] 建目录：`app/{api,auth,bot,db,lg,peer,web,templates,static}`、`cmd/node`、`internal/{api,backend,config,runner}`
- [ ] `app/config.py`：`Settings` 全部字段与默认值（§3.1）
- [ ] `app/db/session.py`：engine、`SessionLocal`、`Base`、`get_db`
- [ ] `app/db/init_db.py`：`create_schema`
- [ ] `app/main.py`：lifespan + SessionMiddleware + 异常处理器
- [ ] 不安全默认值守卫（§3.4）
- [ ] `start.py`：`.env` 解析、`--allow-http`、`--backend-only`、`--bot-only`、`--host`、`--port`
- [ ] `.env.example`、`requirements.txt`

完成判据：`python3 start.py --allow-http --backend-only` 起得来；把 `SESSION_SECRET` 改成 `change-me` 后起不来。

#### M1 数据模型

- [ ] `app/db/models.py`：7 张表（§4.2），含 `UniqueConstraint("node_id","asn")`
- [ ] `app/peer/queries.py`：`query_enabled_nodes`、peer 列表、按 user 过滤等
- [ ] `app/web/deps.py`：`get_db`、`current_user`、`require_admin`

完成判据：`sqlite3` 里能看到 7 张表；手工插入一个 node + 一个 peer，`/portal` 能查到（此时 UI 可先用最简单的模板）。

#### M2 校验与渲染

- [ ] `app/peer/validation.py`：端点、公钥、MTU、隧道地址、ASN 派生（§7.1、§7.2）
- [ ] `app/peer/config.py`：`peer_protocol_name`、`wireguard_listen_port`、`render_wireguard_peer_config`、`render_bird_peer_config`、`render_user_config`、`peering_info`
- [ ] 固定样例测试：`AS4242420090` + 固定 peer id → 断言输出逐字一致

完成判据：§15.5 的第 1–8 条断言全过。

> ⚠️ 这一步最容易"凭感觉"写出 `fe80::0090`。必须用 `4242420090`、`424242`、`65001`、`424242` 后缀碰撞等样例逐个验证。

#### M3 节点协议

后端侧：

- [ ] `NodeHub`：`register` / `unregister` / `request` / `handle_message`
- [ ] `app/node_ws.py` 路由：认证（空 token 拒绝、`compare_digest`）、握手、首帧 `hello`、心跳
- [ ] `request_node`（async）与 `request_node_sync`（同步桥）
- [ ] 状态清洗白名单（§6.5）

节点侧：

- [ ] `internal/config`：`Load` + `applyDefaults` + 指针语义
- [ ] `internal/backend`：手写 WebSocket（握手、帧读写、掩码、`maxFramePayload`）
- [ ] `runOnce`：`hello` 首帧、20s 心跳、`go handleRequest`
- [ ] `internal/api`：8 分支命令分发 + `tryAcquire`

完成判据：假节点连上后 `/admin/nodes` 在线；杀掉假节点后 60 秒内离线；错误 token 被拒。

#### M4 部署编排

- [ ] `app/peer/deploy.py`：`deploy_peer`、`remove_peer`、`fetch_node_public_key`、`apply_deploy_result`
- [ ] `app/peer/service.py`：`create_peer`、`update_peer`、`teardown_peer_request`、节点迁移快照
- [ ] Go `runner.DeployPeer`：校验 → 渲染 → 路径检查 → 原子写 → chown → `wg-quick down/up` → reload
- [ ] Go `runner.RemovePeer`：`os.Stat` → down → remove → reload
- [ ] `ok` / `applied` 双字段语义

完成判据：§15 场景 D/E/F 的节点侧断言全过（真实节点上能看到文件与接口）。

#### M5 认证

- [ ] `app/auth/kioubit.py`：`b64decode`（标准）、ECDSA/SHA-512、60s 双向窗口、domain `==`
- [ ] `app/auth/session.py`：挑战创建/消费（TTL 600s、一次性、purpose）
- [ ] `app/auth/findnoc.py`：`queryUser` / `verify`、仅 404/503 回退
- [ ] `app/auth/service.py`：`upsert_user`、`is_admin` 重算、`asn_identities` 审计、Telegram 绑定
- [ ] 三条登录路径的入口路由

完成判据：§15 场景 C 的 11 条断言全过。

#### M6 Web UI

- [ ] `app/web/pages.py`：`/`、`/lg`（GET）、`/login`、`/auth/kioubit/callback`、`/telegram/auth`、`/logout`
- [ ] `app/web/portal.py`：`/portal`、`/portal/new`、确认、创建、详情、配置、删除
- [ ] `app/web/admin.py`：概览、节点 5 动作、peer 管理、用户管理、LG 日志
- [ ] `app/web/deps.py`：`render`、`flash`、`Pagination`、`client_ip`
- [ ] 模板：`base`、`macros`、`home`、`lg`、`login`、`portal*`、`peer_detail`、`config`、`error`、`admin/*`
- [ ] 静态：`app.js`、`kioubit-auth-button.js`、CSS

完成判据：§15 场景 C/D/E/F/J 全绿；页面在 375px 与 1440px 宽度下不溢出。

#### M7 Bot 与 Bot API

- [ ] `app/api/telegram.py`：12 个端点 + `require_bot_secret`
- [ ] `app/bot/main.py`：双 Router、12 条命令菜单、三套 FSM、`format_block` / `chunk_blocks`
- [ ] 所有提示文案（§8.7）

完成判据：§15 场景 H/I 全绿。

#### M8 Looking Glass

- [ ] `app/lg/validation.py`：四层防护的第一、二层
- [ ] `app/lg/client.py`：`NodeClient.query`
- [ ] `app/lg/ratelimit.py`：`SlidingWindowRateLimiter`
- [ ] `app/lg/summary.py`：BIRD/WG 摘要
- [ ] `app/web/lg.py`：`GET /lg`、`POST /lg`
- [ ] Go 侧 `Ping` / `Trace` / `Mtr` / `Route`

完成判据：§15 场景 G 的 11 条断言全绿。

#### M9 加固与验收

- [ ] §14.9 的 30 项检查
- [ ] §15.4 的 10 条数据不变量做成 pytest
- [ ] §15.5 的 68 条回归清单
- [ ] §15.7 的 15 条负面用例
- [ ] 备份脚本 + 恢复演练
- [ ] 监控探针
- [ ] 运维文档（可直接用 §16）

### 17.4 复杂度评级

用"相对复杂度"替代工时估算，便于排布并行工作。

| 模块 | 复杂度 | 理由 |
|---|---|---|
| `Settings` / `init_db` / `start.py` | ★☆☆☆☆ | 直白的配置与建表 |
| 数据模型 | ★☆☆☆☆ | 7 张表，字段明确 |
| 校验与渲染 | ★★★☆☆ | 规则多、边界细（ASN 后缀、ULA 分支、MTU） |
| 后端 `NodeHub` | ★★★★☆ | Future 挂起、超时、连接替换、线程桥 |
| Go 手写 WebSocket | ★★★★★ | 帧格式、掩码、长度编码、reader 复用 |
| 部署编排 | ★★★★☆ | 两阶段事务、`ok`/`applied`、节点迁移、原子写 |
| 认证 | ★★★★☆ | 密码学验签、挑战生命周期、三路径归一 |
| Web UI | ★★★☆☆ | 量大但机械；陷阱在同步/异步路由混用 |
| Bot | ★★★★☆ | FSM 状态多、文案多、分块逻辑 |
| LG | ★★★☆☆ | 校验链与限流；节点侧命令参数 |
| 安全加固 | ★★★★☆ | 需要逐条对照，无"差不多" |

**最难的两块是 Go WebSocket 与认证**。若团队分工，建议让最熟悉协议/密码学的人各负责一块。

> ⚠️ 若不想手写 WebSocket，复刻时**可以**用 `gorilla/websocket` 或 `nhooyr.io/websocket`。但必须保留 §13.3 的语义：`maxFramePayload` 限制、不支持分片、握手后复用 reader、`writeMu`、`heartbeatErr` 容量 1。换库不是问题，丢语义才是问题。

### 17.5 本地开发环境

#### 17.5.1 最小依赖

```text
Python 3.11+
Go 1.22+
（可选）wireguard-tools、bird2 —— 只有验证真机部署时才需要
```

后端依赖见 `requirements.txt`（FastAPI、uvicorn、SQLAlchemy、aiogram、httpx、cryptography、jinja2、itsdangerous、python-multipart、anyio）。

#### 17.5.2 三种本地运行组合

| 组合 | 命令 | 用途 |
|---|---|---|
| 只后端 | `python3 start.py --allow-http --backend-only` | 写 Web/API |
| 后端 + 假节点 | 上者 + `python3 tools/fake_node.py ...` | 写部署与 LG |
| 后端 + Bot | `python3 start.py --allow-http --backend-only` + `--bot-only`（两个进程） | 写 Bot |

> ⚠️ `--bot-only` 仍然需要 `TELEGRAM_BOT_TOKEN`。没有真 token 时，Bot 会在启动时失败——这是刻意的快速失败，不要改成"空 token 也能起"。

#### 17.5.3 调试技巧

1. **看数据库**：`sqlite3 autopeer.db` + `.headers on` + `.mode column`。
2. **看发往节点的报文**：在假节点里 `print(json.dumps(msg, indent=2))`，比在后端打日志更快。
3. **看渲染结果**：写一个 10 行的脚本，构造 `PeerRequest`/`Node` 对象直接调 `render_*`，不用走 HTTP。
4. **看 session**：Cookie 是签名的，用 `itsdangerous` 解不出来就说明 secret 变了。
5. **绕过限流**：把 `LG_RATE_LIMIT` 设为 `0`（禁用），或把窗口调大。

### 17.6 常见返工点

按"返工代价"排序，越靠前越应该在早期避免：

| # | 返工点 | 早期避免方式 |
|---|---|---|
| 1 | `protocol_name` 未带 peer id 后缀 → ASN 后 4 位碰撞 | M2 就定死格式并写样例测试 |
| 2 | 把 `ok` 与 `applied` 合并成一个布尔 | M4 就按 §7.10 实现 `apply_deploy_result` |
| 3 | 同步/异步路由混用（`def` 里 `await`） | M6 前先画一张"哪些路由 sync / 哪些 async"的表 |
| 4 | `readFrame` 分配内存后才检查长度 | M3 直接照 §13.3 的检查顺序写 |
| 5 | Peer 归属挂到 Telegram UID | M1 就把 `user_id` 设成外键 |
| 6 | 限流用 `time.time()` | M8 用 `time.monotonic()` |
| 7 | 校验失败返回 400 | M8 先写 §15.3.3 的状态码表再写代码 |
| 8 | 门户删除做成软删除 | M6 明确"门户=硬删除，管理端禁用=软" |
| 9 | 私钥进入后端 | M2 就用占位符，节点侧替换 |
| 10 | 节点命令用 shell | M4 第一版就用固定 argv |

> **最重要的建议**：把 §15.5 的 68 条断言在 M9 之前就写成自动化测试。它们是"防返工"的最低成本手段。

---

## §18 改进建议

本章是"复刻完成后，下一步该往哪走"。按优先级分级，**不要**一次全做。

> 判断标准：任何改动都必须在 §15 的验收用例上**不回归**。若改完需要修改 §15.3 的契约表，说明你改变了系统行为，需单独评估。

### 18.1 架构演进

#### 18.1.1 把节点连接状态外置（P1）

**问题**：`NodeHub` 在进程内存，导致不能多 worker（§16.7.1）。

**方案（由轻到重）**：

| 方案 | 做法 | 代价 |
|---|---|---|
| A. sticky routing | 反代按 `name` 参数哈希到固定 worker | 简单，但 worker 挂掉即节点离线 |
| B. Redis pub/sub | 节点连接保持在一个 "gateway" 进程；业务 worker 通过 Redis 发请求 | 引入 Redis，需处理请求/响应关联 |
| C. 独立网关服务 | WSS 网关单进程，HTTP 内部 RPC 给后端集群 | 最清晰，架构最重 |

**建议**：节点数 <100 且单机可承受时，**不要**做（收益小、复杂度高）。只有当"必须水平扩容 Web"时才做 B。

#### 18.1.2 部署异步化（P1）

**问题**：`POST /portal/peers` 是同步路由，阻塞等待最多 20 秒（§11.7、§16.4.6）。

**方案**：

```text
1. 创建 peer 时 status=approved, deploy_status=deploying
2. 立即返回详情页（显示"部署中"）
3. 后台任务（asyncio.create_task 或 worker）执行 deploy
4. 详情页轮询 deploy_status 或 SSE 推送
```

**收益**：

- 用户不再盯着转圈的页面；
- 超时可以放宽到 60s，消除 20s vs 36s 的矛盾；
- 部署失败可以重试，不用手工点。

**代价**：需要任务状态机（`deploying` 已是现成的第五个状态之一），以及"进程重启后遗留 `deploying`"的清理逻辑。

#### 18.1.3 配置渲染结构化（P2）

**问题**：BIRD 片段是字符串模板，后端无法校验语义（§14.5.3 最大残留风险）。

**方案**：定义结构化 schema（如 JSON）描述 peer，节点侧用 Go 模板渲染，后端只传结构。

```json
{
  "protocol_name": "DN42_0090_1a2b",
  "local_asn": "4242420000",
  "peer_asn": "4242420090",
  "neighbor": "fe80::90",
  "scope": "DN42_0090_1a2b",
  "source": "fe80::1",
  "extended": true
}
```

好处：

- 后端不能注入任意 BIRD 语句；
- 两侧共享同一份字段定义；
- 未来换 BIRD 版本只改节点模板。

**代价**：破坏 wire 协议兼容（需同时升级两端），且节点不再是"哑执行器"。

> ⚠️ 这是**最值得做**的安全改进，但也是改动面最大的。若只做一件事，做这个。

### 18.2 安全加固优先级

| 优先级 | 项 | 现状 | 改法 | 验证 |
|---|---|---|---|---|
| **P0** | BIRD 配置内容不校验 | 后端可下发任意 BIRD 语法 | 见 18.1.3；过渡期至少在节点侧拒绝 `include`/`import`/`filter` 等关键字 | 构造含 `include "/etc/shadow";` 的 payload，节点必须拒绝 |
| **P0** | 部署超时不对齐 | 后端 20s < 节点最坏 36s | 后端提到 45s，或节点 `command_timeout_seconds=6` | 制造慢 `wg-quick`，后端不应误判失败 |
| **P1** | `LGQuery` 无 `client_ip` | 无法追溯滥用 | 加列 + 迁移 + 模板展示 | 查询后能看到来源 IP |
| **P1** | `ensureChildPath` 不解析符号链接 | 目录内符号链接可指向外部 | `filepath.EvalSymlinks` 后比较 | 在 peers 目录放指向 `/etc/shadow` 的软链，部署必须失败 |
| **P1** | 限流只在应用层 | 反代层无保护 | nginx `limit_req` + 应用层保留 | 压测时反代先返回 429 |
| **P1** | 挑战/日志无清理 | 表持续增长 | 定时任务删过期挑战与旧 LG 日志 | 跑一次任务后行数下降 |
| **P2** | secret 只查黑名单 | 弱 secret 能上线 | 加最小长度/熵检查 | 用 8 字符 secret 启动必须失败 |
| **P2** | 会话无 `max_age` | 浏览器会话级 | 按需设 `max_age`（如 7 天） | 关浏览器再开仍登录 |
| **P2** | 无证书固定 | 依赖系统 CA | 节点侧可选 pin SPKI | 换错证书时连接失败 |
| **P2** | `peers.status` 的 WG 无 `ok` | 后端靠文本判断 | 加 `wireguard_ok` 布尔 | 接口不存在时 `wireguard_ok=false` |
| **P2** | `decodeCommandPayload` 不记日志 | 排障盲点 | 加 debug 日志（不含敏感值） | 非法 payload 时有日志 |
| **P3** | 无审计登录失败 | 无法发现撞库 | 记录 ASN/IP/原因到独立表 | 连续失败 10 次可查 |

> ⚠️ P0 的两项都是"会导致真实损失"的：一个是被攻破后横向移动，一个是运维误判导致重复部署。其余是"提升可运维性"。

### 18.3 可观测性

#### 18.3.1 结构化日志

现状是 `print`/`log.Printf` 的自由文本。建议改成 JSON 行：

```json
{"ts":"2026-10-23T10:00:00Z","level":"info","event":"deploy","asn":"4242420090","node":"sin1","protocol":"DN42_0090_1a2b","ok":true,"applied":true,"duration_ms":1830}
```

关键字段：`event`、`asn`、`node`、`protocol`、`ok`、`applied`、`duration_ms`、`error`。

> ⚠️ 不要让 `event` 携带 `token`、`private_key`、`params`、`signature`。

#### 18.3.2 指标暴露

见 §16.8.2。实现方式：

- Python 侧用 `prometheus_client`，在 `/metrics` 暴露（需限制访问或放在内网端口）。
- Go 侧可在心跳里附带计数，由后端聚合；或单独开一个只监听 `127.0.0.1` 的 metrics 端口。

#### 18.3.3 链路追踪

若部署异步化（18.1.2），建议给每次部署一个 `request_id`（已有），并在日志中贯穿。这样"用户投诉部署失败"时可以用一个 id 查出后端→节点→`wg-quick` 的完整链路。

### 18.4 功能扩展

按"用户价值 / 改动成本"排序：

| 功能 | 价值 | 改动点 | 风险 |
|---|---|---|---|
| 每个 ASN 的 peer 配额 | 中 | `create_peer` 加计数检查 | 低 |
| ASN 黑名单 | 中 | 认证入口加表查询 | 低 |
| 邮件/Telegram 通知部署结果 | 中 | 部署完成后调 Bot API | 低 |
| Peer 到期提醒 | 低 | 定时任务 + 通知 | 低 |
| 多 operator（多 `LOCAL_ASN`） | 高 | 管理员模型从布尔改为角色表 | **高**（涉及所有鉴权） |
| IPv6-only 节点 | 中 | endpoint 渲染与校验 | 中 |
| 每节点自定义 BGP 模板 | 中 | 节点配置增加模板路径 | 中（安全面） |
| Peer 自助改 key | 中 | 编辑表单 + 重部署 | 低 |
| 公开 Peer 列表/统计页 | 低 | 只读页面 | 低 |
| 对接 dn42 registry 校验 ASN | 高 | 外部 API + 缓存 | 中（可用性依赖） |

> ⚠️ "多 operator" 看似只是把 `is_admin` 换成角色，实际会影响：`LOCAL_ASN` 派生、节点归属、peer 归属、审计归属。不要在 M6 之后临时加，要在 M1 就设计。

### 18.5 明确不建议改的契约

这些是"看起来可以优化，但改了会破坏系统"的地方。复刻者最容易在这里自作聪明。

| # | 不要改 | 原因 |
|---|---|---|
| 1 | 不要把 `POST /lg` 的校验失败改成 400 | 前端 fetch 分支依赖 200 + `ok=false` |
| 2 | 不要把 `ok` 与 `applied` 合并 | 会丢失"文件已写但服务未起"的关键信息 |
| 3 | 不要去掉 `protocol_name` 的 peer id 后缀 | 同节点 ASN 后 4 位碰撞会互相覆盖隧道 |
| 4 | 不要把私钥挪到后端渲染 | 后端一旦被攻破即全节点私钥泄露 |
| 5 | 不要把 `remove_peer` 加上 `node.enabled` 检查 | 禁用节点后仍必须能清理残留配置 |
| 6 | 不要把门户删除改成软删除 | Bot 的 peer 菜单与计数依赖硬删除 |
| 7 | 不要给 `ALLOWED_NETWORKS` 收窄成只允许 dn42 | 公开 LG 的价值就是能查全网；收窄需同步改两侧 |
| 8 | 不要去掉 LG 的"每请求都写审计" | 安全事件时这是唯一线索 |
| 9 | 不要把异步 LG 路由改成同步 `def` | 同步路由里 `await` 会直接报错 |
| 10 | 不要让节点服务监听端口 | 架构的安全基石是"只拨出" |
| 11 | 不要把 `readFrame` 的 1MB 限制去掉 | 单帧 4GB 会 OOM |
| 12 | 不要给 `heartbeatErr` 加大缓冲 | 缓冲区越大，退出越慢，重连越迟 |
| 13 | 不要把 `tryAcquire` 改成阻塞等待 | 会让 LG 请求排队堆积，拖垮节点 |
| 14 | 不要把 `deployMu` 拆成两把锁 | deploy 与 remove 必须互斥，否则会同时改同一文件 |
| 15 | 不要在 `bird_peer_group=""` 时回退成 `bird` | 显式空是"不 chown"的开关 |

### 18.6 复刻与上游的关系

如果复刻的目的是**替代上游**（而不是学习），建议：

1. 先保持 wire 协议与数据库 schema 完全兼容（可直接接现有节点与 Bot）。
2. 再逐项做 §18.1/§18.2 的改进，每项单独发版。
3. 每次改进都用 §15 回归，确保没破坏既有部署。

如果目的是**学习/教学**，建议直接照抄原实现（包括那些"不完美"的地方），因为它们本身就是设计取舍的教材。

---

## 附录 A 速查表

### A.1 后端错误与提示文案

以下为原实现中的关键字符串。复刻时建议**照抄**，因为 E2E 测试与用户预期都依赖它们。

#### A.1.1 Looking Glass

| 场景 | 原文 |
|---|---|
| 限流 | `Too many looking glass queries. Please wait a moment and try again.` |
| 节点不存在/禁用 | `Unknown or disabled node` |
| 节点忙 | `node is busy, try again shortly` |
| 目标非法 | 统一校验失败文案（不带具体原因，避免探测） |

#### A.1.2 Peer 校验

| 场景 | 原文 |
|---|---|
| 端点过长 | `Endpoint is too long` |
| 端点含空白/控制字符 | `Endpoint must not contain spaces or control characters` |
| 端点格式 | `Endpoint must be in host:port form` |
| 端口范围 | `Endpoint port must be between 1 and 65535` |
| IPv6 端点格式 | `IPv6 endpoints must be written as [address]:port` |
| 端点主机 | `Endpoint host must be an IP address or hostname` |
| 公钥 | `WireGuard public key must be a 44-character base64 value` |
| MTU 非整数 | `WireGuard MTU must be an integer` |
| MTU 范围 | `WireGuard MTU must be between 1280 and 9000` |
| 隧道地址必填 | `Peer address is required` |
| 隧道地址类型 | `Peer address must be an IPv6 link-local (fe80::/10) or ULA (fd00::/8) address` |
| 节点地址必填 | `Node public address is required` |
| 节点地址格式 | `Node public address must be an IPv4, IPv6, or domain (no scheme or port)` |
| ASN 非数字 | `ASN must be numeric` |
| 派生端口越界 | `Derived WireGuard listen port is out of range` |
| 部署状态 | `Only approved peers can be deployed.` |

#### A.1.3 认证

| 场景 | 原文 |
|---|---|
| 公钥缺失 | `Kioubit public key is not installed` |
| 验签失败 | `Invalid Kioubit signature` |
| 时间窗 | `Kioubit token has expired` |
| 域名不符 | `Kioubit token was issued for a different domain` |
| 挑战不存在 | `Unknown auth challenge` |
| purpose 不符 | `Auth challenge purpose mismatch` |
| 挑战已用 | `Auth challenge was already used` |
| 挑战过期 | `Auth challenge has expired` |
| Telegram 不匹配 | `Telegram user mismatch` |
| FindNOC 不可用 | `FindNOC is currently unavailable` |

#### A.1.4 节点启动

| 场景 | 原文 |
|---|---|
| 公钥缺失/非法 | `wireguard_public_key is required and must be a 44-character base64 WireGuard key` |
| WSS URL 缺失 | `backend_wss_url is required` |
| name 缺失 | `name is required when backend_wss_url is set` |

### A.2 Bot 命令与语义

| 命令 | 行为 | 特殊输入 |
|---|---|---|
| `/start` | 欢迎 + 菜单 | — |
| `/help` | 用法说明 | — |
| `/login` | FindNOC 优先，失败回退 Kioubit Mini App | 多 ASN 时让用户选 |
| `/logout` | 仅解绑 Telegram | peer 保留 |
| `/listpeers` | 分块展示 peer 状态 | — |
| `/create` | 6 步创建向导 | `skip`、`default` |
| `/edit` | 4 步编辑向导 | `keep`（保留 MTU） |
| `/delete` | 2 步删除向导 | 需确认 |
| `/ping` `/trace` `/mtr` `/route` | LG 查询 | 需先选节点与目标 |
| `/cancel` | 中止当前向导 | 任意步骤可用 |

> ⚠️ 在任何向导步骤中，以 `/` 开头的输入都会被 `reject_if_command` 拦下并提示先 `/cancel`，**不能**当作普通文本。

### A.3 状态枚举

#### A.3.1 `peer_requests.status`

| 值 | 含义 | 允许部署 | 出现在用户列表 |
|---|---|---|---|
| `pending` | 待审 | 否 | 是（标记待审） |
| `approved` | 已批准 | 是 | 是 |
| `disabled` | 已禁用 | 否 | 是（标记禁用） |

#### A.3.2 `peer_requests.deploy_status`

| 值 | 含义 | 触发 |
|---|---|---|
| `not_deployed` | 从未部署（默认） | 新建行默认值 |
| `deploying` | 部署中 | 部署前写入 |
| `deployed` | 部署成功 | 节点返回 `ok=true` |
| `failed` | 部署失败 | 节点返回 `ok=false` 或异常 |
| `removed` | 已移除 | tear down 成功 |

> ⚠️ `removed` 是第五个状态，很容易漏。漏了会导致"禁用后仍显示已部署"。

#### A.3.3 展示映射

| 状态 | 徽章样式（原实现） |
|---|---|
| `approved` | `ok` |
| `disabled` | `bad` |
| `pending` | `warn` |
| `deployed` | `ok` |
| `failed` | `bad` |
| `deploying` | `warn` |

### A.4 常量总表

| 常量 | 值 | 所在层 | 说明 |
|---|---|---|---|
| `DEFAULT_WIREGUARD_MTU` | `1420` | 后端 | 空值回退 |
| `MIN_WIREGUARD_MTU` | `1280` | 后端 | 下限 |
| `MAX_WIREGUARD_MTU` | `9000` | 后端 | 上限 |
| WG 监听端口 | ASN 后 5 位 | 后端 | `4242420090 → 20090` |
| link-local 后缀 | 见 §0.3 | 后端 | `4242420090 → 90` |
| `protocol_name` | `DN42_<asn4>_<id4>` | 两侧 | 14 字符 |
| 心跳间隔 | `20s` | 节点 | `heartbeatInterval` |
| 状态采样间隔 | `60s` | 节点 | `statusSampleInterval` |
| 重连间隔 | `5s` | 节点 | `defaultReconnectDelay`（固定，无退避） |
| `maxFramePayload` | `1 MiB` | 节点 | `1 << 20` |
| `maxStatusOutput` | `65536` | 节点 | 64 KiB 截断 |
| `defaultMaxConcurrency` | `4` | 节点 | `nil` 或负数 → 4；`0` → 不限 |
| `defaultTimeoutSeconds` | `12` | 节点 | 单命令 |
| 部署超时（后端） | `20s` | 后端 | `deploy_peer` / `remove_peer` |
| 公钥获取超时 | `10s` | 后端 | `fetch_node_public_key` |
| LG 超时 | `12s` | 后端 | `NodeClient` |
| 通用请求超时 | `12s` | 后端 | `request_node` |
| 挑战 TTL | `600s` | 后端 | `auth_challenges` |
| 重放窗口 | `60s` | 后端 | Kioubit 双向 |
| LG 限流 | `20` / `60s` | 后端 | `LG_RATE_LIMIT` / 窗口 |
| LG 日志分页 | `50` | 后端 | `LG_LOG_PER_PAGE` |
| 限流器剪枝阈值 | `2048` 键 | 后端 | `_prune` |
| flash Cookie 上限 | 约 `4 KiB` | 后端 | 超出丢弃 |
| 配置片段上限 | `16 KiB` | 节点 | `wireguard_config` / `bird_config` |
| 端点长度上限 | `255` | 两侧 | — |
| `request_id` 上限 | `64` | 节点 | — |
| `asn` 长度上限 | `32` | 节点 | — |
| `node` 长度上限 | `64` | 节点 | — |
| `safeName` 长度 | `1–80` | 节点 | 正则量词 |
| 主机名总长 | `≤253` | 两侧 | RFC-1123 |
| 指纹/公钥长度 | `44` | 两侧 | base64 32 字节 |

### A.5 术语对照

| 中文 | 英文 / 代码名 | 说明 |
|---|---|---|
| 控制面 | Backend / control plane | FastAPI 后端 |
| 节点 | Node | 运维方的一个 PoP（路由器） |
| 节点服务 | Node service | 路由器上的 Go 进程 |
| 对等端 | Peer | 申请互联的用户侧 |
| 对等请求 | PeerRequest | 数据库实体（历史命名，实际是已批准的 peer） |
| 隧道 | tunnel | WireGuard 链路 |
| 观测窗 | Looking Glass (LG) | 公开查询页 |
| 部署 | deploy | 写配置 + `wg-quick up` |
| 移除 | remove / teardown | `wg-quick down` + 删文件 |
| 指纹/公钥 | public key | WireGuard 公钥 |
| 挑战 | challenge | 一次性登录令牌 |
| 身份 | identity | `asn_identities` 里的一次登录证明 |
| 绑定 | binding | Telegram UID ↔ user |
| 派生 | derive | 由 ASN 计算端口/地址/名称 |
| 摘要 | summary | 把节点原始输出压缩成一行 |

### A.6 章节与源码映射

复刻时按这张表找对应文件，避免"文档说的和代码对不上"。

| 章节 | 主要源码 |
|---|---|
| §3 配置与入口 | [`app/config.py`](file:///workspace/dn42-jasonxu/app/config.py)、[`app/main.py`](file:///workspace/dn42-jasonxu/app/main.py)、[`start.py`](file:///workspace/dn42-jasonxu/start.py) |
| §4 数据模型 | [`app/db/models.py`](file:///workspace/dn42-jasonxu/app/db/models.py)、[`app/db/init_db.py`](file:///workspace/dn42-jasonxu/app/db/init_db.py)、[`app/db/session.py`](file:///workspace/dn42-jasonxu/app/db/session.py) |
| §5 Node 协议 | [`app/node_ws.py`](file:///workspace/dn42-jasonxu/app/node_ws.py)、[`docs/node-api.md`](file:///workspace/dn42-jasonxu/docs/node-api.md) |
| §6 节点枢纽 | [`app/node_ws.py`](file:///workspace/dn42-jasonxu/app/node_ws.py) |
| §7 Peer 领域 | [`app/peer/validation.py`](file:///workspace/dn42-jasonxu/app/peer/validation.py)、[`app/peer/config.py`](file:///workspace/dn42-jasonxu/app/peer/config.py)、[`app/peer/service.py`](file:///workspace/dn42-jasonxu/app/peer/service.py)、[`app/peer/deploy.py`](file:///workspace/dn42-jasonxu/app/peer/deploy.py)、[`app/peer/queries.py`](file:///workspace/dn42-jasonxu/app/peer/queries.py) |
| §8 Bot | [`app/bot/main.py`](file:///workspace/dn42-jasonxu/app/bot/main.py) |
| §9 Bot API | [`app/api/telegram.py`](file:///workspace/dn42-jasonxu/app/api/telegram.py) |
| §10 认证 | [`app/auth/kioubit.py`](file:///workspace/dn42-jasonxu/app/auth/kioubit.py)、[`app/auth/findnoc.py`](file:///workspace/dn42-jasonxu/app/auth/findnoc.py)、[`app/auth/service.py`](file:///workspace/dn42-jasonxu/app/auth/service.py)、[`app/auth/session.py`](file:///workspace/dn42-jasonxu/app/auth/session.py)、[`docs/auth-flow.md`](file:///workspace/dn42-jasonxu/docs/auth-flow.md) |
| §11 Web UI | [`app/web/pages.py`](file:///workspace/dn42-jasonxu/app/web/pages.py)、[`app/web/portal.py`](file:///workspace/dn42-jasonxu/app/web/portal.py)、[`app/web/admin.py`](file:///workspace/dn42-jasonxu/app/web/admin.py)、[`app/web/deps.py`](file:///workspace/dn42-jasonxu/app/web/deps.py)、[`app/templates/`](file:///workspace/dn42-jasonxu/app/templates) |
| §12 LG | [`app/lg/validation.py`](file:///workspace/dn42-jasonxu/app/lg/validation.py)、[`app/lg/client.py`](file:///workspace/dn42-jasonxu/app/lg/client.py)、[`app/lg/ratelimit.py`](file:///workspace/dn42-jasonxu/app/lg/ratelimit.py)、[`app/lg/summary.py`](file:///workspace/dn42-jasonxu/app/lg/summary.py)、[`app/web/lg.py`](file:///workspace/dn42-jasonxu/app/web/lg.py) |
| §13 Go 节点 | [`cmd/node/main.go`](file:///workspace/dn42-jasonxu/cmd/node/main.go)、[`internal/api/server.go`](file:///workspace/dn42-jasonxu/internal/api/server.go)、[`internal/backend/client.go`](file:///workspace/dn42-jasonxu/internal/backend/client.go)、[`internal/config/config.go`](file:///workspace/dn42-jasonxu/internal/config/config.go)、[`internal/runner/runner.go`](file:///workspace/dn42-jasonxu/internal/runner/runner.go) |
| §14 安全 | 横跨全部；重点见 `app/auth/*`、`app/lg/validation.py`、`internal/runner/runner.go` |
| §15 验收 | 本章（无对应源码，需自行编写测试） |
| §16 运维 | [`README.md`](file:///workspace/dn42-jasonxu/README.md)、`docs/*`、systemd 单元 |

---

## 结语

这份文档覆盖了 `jasonxu114514/dn42` 在基线 `4248b89` 上的实现原理、交互逻辑与复刻细节。三个判断供参考：

1. **真正的难点是契约，不是代码量。** 7000 行 Python + Go 里，能让你卡住的只有三处：`protocol_name` 派生、`ok`/`applied` 语义、同步/异步路由边界。其余都是重复劳动。

2. **最危险的不是外部攻击，是内部误操作。** 节点服务以 root 运行、能写任意 BIRD 片段——这意味着"后端被攻破"等于"全部节点失守"。§18.1.3 的结构化渲染是唯一能根治的方向。

3. **先跑通再接真机。** 用 §15.1.3 的假节点把协议与状态码全部固化，再上真实路由器验证 `wg-quick` 与 `chownToGroup`。顺序反了，你会把"配置内容错"误判成"网络问题"，浪费大量时间。

复刻完成后，按 §15.8 的模板出具验收报告——**每一项都要有证据**，不要凭"我觉得跑通了"签字。
