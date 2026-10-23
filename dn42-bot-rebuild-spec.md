# DN42 Bot 复刻开发文档

> 目标：依据本文档可以从零实现一个与 `Potat0000/dn42-bot` 行为等价的系统。
> 原文仓库：`https://github.com/Potat0000/dn42-bot`
> 基线版本：`1d95d90845f37a2715134712e01080959013904e`（2026-03-25，“修复 Typo”）
> 文档范围：架构、数据模型、双端 API 契约、配置项、全部命令流程、校验规则、配置模板、定时任务、部署运维、测试用例。

**阅读路径建议**

1. 第一次复刻：先读 §1-§5（架构、配置、数据、API），再按 §11 的顺序实现。
2. 只关心 Peer 自动化：重点读 §7.5、§7.6、§7.7、§8.3-§8.6。
3. 需要 1:1 对齐交互：读 §7.14 文案清单与 §7.16 实现陷阱。
4. 上线部署：读 §2.4、§10.1、§15。
5. 验收：直接使用 §12 与 §13 的清单。

**符号约定**

| 符号 | 含义 |
|---|---|
| `必须` | 缺少会导致功能不可用或协议不兼容 |
| `建议` | 影响稳定性/可维护性，可按部署环境调整 |
| `原实现` | 指基线版本中的具体行为，复刻时建议保持一致 |
| `⚠️` | 已知缺陷或坑点，详见 §7.16 |

---

## 0. 术语

| 术语 | 含义 |
|---|---|
| Server | Telegram Bot 主程序，单实例部署，负责对话、校验、编排 |
| Agent | 部署在每台 DN42 节点上的 HTTP 服务，以 root 执行 WireGuard / BIRD 操作 |
| Peer | 一条 WireGuard 隧道 + 一到两个 BGP 会话 |
| Region / Node | Agent 所在节点，配置中用短名（如 `hkg`）标识 |
| 特权用户 | 通过 `PRIVILEGE_CODE` 登录的运维身份，可绕过多数限制 |
| LLA | IPv6 Link-Local 地址（`fe80::/64`） |
| ULA | IPv6 私有地址（`fc00::/7`） |

---

## 1. 系统架构

### 1.1 组件关系

```
Telegram 用户
   │ 命令 / 回复键盘 / 内联按钮回调
   ▼
┌────────────────────────── Server（单进程） ─────────────────────────┐
│ pyTelegramBotAPI（polling 或 webhook）                              │
│  ├─ 命令处理器（tools / login / peer / modify / remove / info ...） │
│  ├─ 交互状态机（register_next_step_handler + pre_/post_ 约定）      │
│  ├─ 本地能力（whois、dig、DNS、DN42/中国 IP 判定）                  │
│  ├─ 定时任务（节点健康、地图、ROA、FlapAlerted）                    │
│  └─ 内存 + pickle 持久化（user_db.pkl、map.pkl、step.save）         │
└───────────────┬──────────────────────────────┬──────────────────────┘
                │ HTTP POST，Header 鉴权         │
                ▼                              ▼
        ┌─ Agent@node-a ─┐              ┌─ Agent@node-b ─┐
        │ aiohttp HTTP   │              │ aiohttp HTTP   │
        │ wg-quick       │              │ wg-quick       │
        │ birdc          │              │ birdc          │
        │ ping/tcping    │              │ ping/tcping    │
        └────────────────┘              └────────────────┘
```

### 1.2 关键设计原则

1. **Server 不直接操作网络设备**。所有写配置、起服务、执行 ping 的动作都由 Agent 完成。
2. **Agent 无数据库**。真实状态就是 `/etc/wireguard/dn42-{ASN}.conf` 与 `/etc/bird/dn42_peers/{ASN}.conf`，`/info` 反向解析这两份文件得到状态。
3. **Server 只保存身份映射**：`chat_id -> ASN` 与特权集合，其余全部实时查询 Agent。
4. **多节点并发查询**：工具命令与节点状态探测用线程池并发 fan-out，单节点故障不阻塞整体。
5. **单进程假设**：交互状态与结果缓存均在进程内存中，不支持多 worker 横向扩展。

### 1.3 建议目录结构

```
dn42-bot/
├── server/
│   ├── main.py                 # 入口：初始化、定时任务、webhook/polling
│   ├── base.py                 # bot、全局状态、pickle 加载
│   ├── config.py               # 部署配置（由 config.example.py 复制）
│   ├── config.example.py
│   ├── requirements.txt
│   ├── commands/
│   │   ├── __init__.py         # 导入所有命令模块以完成注册
│   │   ├── start.py
│   │   ├── help.py
│   │   ├── cancel.py
│   │   ├── tools/
│   │   │   ├── all_in_one.py   # ping/tcping/trace/route/path
│   │   │   ├── dig.py
│   │   │   └── whois.py
│   │   ├── user_manage/
│   │   │   ├── login.py
│   │   │   ├── logout.py
│   │   │   └── whoami.py
│   │   ├── peer/
│   │   │   ├── peer.py         # /peer 入口与状态机调度
│   │   │   ├── info_collect.py # 全部采集步骤
│   │   │   ├── modify.py
│   │   │   ├── remove.py
│   │   │   ├── restart.py
│   │   │   └── info.py
│   │   └── statistics/
│   │       ├── stats.py
│   │       ├── rank.py
│   │       ├── peer_list.py
│   │       └── flaps.py
│   └── tools/
│       ├── __init__.py         # 统一导出
│       ├── tools.py            # 通用函数
│       ├── servers_check.py
│       ├── get_map.py
│       ├── get_flaps.py
│       ├── update_china_ip.py
│       └── update_as_route_table.py
└── agent/
    ├── main.py                 # aiohttp 应用入口
    ├── base.py                 # 配置加载、路由表
    ├── tools.py                # simple_run、Sentry 装饰器
    ├── agent_config.json
    ├── agent_config.example.json
    ├── requirements.txt
    └── commands/
        ├── __init__.py
        ├── peer.py             # /peer /remove /restart /info /pre_peer
        └── statistics.py       # /ping /trace /tcping /route /path
```

---

## 2. 运行环境与部署前提

### 2.1 Server 依赖

```text
aiohttp==3.12.15
APScheduler==3.11.0
dnspython==2.8.0
expiringdict==1.2.2
punycode==0.2.1
pyTelegramBotAPI==4.29.1
pytz==2025.2
Requests==2.32.5
requests_futures==1.0.2
rustworkx==0.17.1
sentry_sdk==2.39.0
urllib3==2.5.0
```

系统依赖：`whois`、`dig`（bind-utils / dnsutils）。

### 2.2 Agent 依赖

```text
aiohttp==3.12.15
sentry_sdk==2.39.0
```

系统依赖与前提：

| 依赖 | 用途 |
|---|---|
| `wireguard-tools` + `systemd` | `wg-quick@dn42-{ASN}` 服务 |
| 私钥 `/etc/wireguard/dn42-privatekey` | WG 接口私钥，由 `PostUp` 注入 |
| `bird2` | BGP 会话，支持 `birdc` |
| BIRD 模板 `dn42_peers` | Agent 生成的配置均 `from dn42_peers`，必须在节点 BIRD 配置中存在 |
| BIRD 表 `master4` / `master6`（可配置） | `/route`、`/path` 查询 |
| `tcping`（pouriyajamshidi/tcping） | `/tcping`，参数需支持 `--no-color -c N` |
| `ping`、`traceroute` | `/ping`、`/trace` |
| `vnstat`（可选） | 自动增删接口统计 |

Agent 进程必须以 **root** 运行（写 `/etc`、执行 systemctl/birdc）。

### 2.3 部署要点

- Server 必须从 `server/` 目录启动，因为 `user_db.pkl`、`map.pkl`、`step.save` 使用相对路径。
- Agent 的 API 端口需对 Server 可达；`config.HOSTS` 可为个别节点覆盖 API 域名/IP。
- Agent API 默认明文 HTTP，建议只在内网/WireGuard 内暴露，并在防火墙上限制来源。

### 2.4 完整部署手册

#### 2.4.1 目录与权限

```text
/opt/dn42-bot/
├── .venv/                 # 两侧共用的虚拟环境即可
├── server/                # 从该目录启动
│   ├── config.py          # chmod 600
│   ├── user_db.pkl        # chmod 600，运行用户可写
│   ├── map.pkl
│   └── step.save
└── agent/
    └── agent_config.json  # chmod 600，仅 root 可读
```

- Server 运行用户：普通用户即可（不需要 root），但必须对 `server/` 有写权限。
- Agent 运行用户：**root**（写 `/etc/wireguard`、`/etc/bird`，执行 systemctl、birdc）。
- 建议 Server 使用独立账号 `dn42bot`，并禁止其交互式登录。

#### 2.4.2 Server systemd 单元

```ini
[Unit]
Description=DN42 Telegram Bot Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=dn42bot
Group=dn42bot
WorkingDirectory=/opt/dn42-bot/server
ExecStart=/opt/dn42-bot/.venv/bin/python main.py
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
```

注意：`WorkingDirectory` 必须是 `server/`，否则三个 pickle 文件会落到错误位置。

#### 2.4.3 Agent systemd 单元

```ini
[Unit]
Description=DN42 Bot Agent
After=network-online.target bird.service
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/dn42-bot/agent
ExecStart=/opt/dn42-bot/.venv/bin/python main.py
Restart=always
RestartSec=3
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
```

Agent 必须在 BIRD 启动之后再启动，否则首次 `/info` 可能因 `birdc` 连接失败报错。

#### 2.4.4 WireGuard 私钥与公钥

```bash
wg genkey | tee /etc/wireguard/dn42-privatekey | wg pubkey
chmod 600 /etc/wireguard/dn42-privatekey
wg pubkey < /etc/wireguard/dn42-privatekey   # 结果写入 agent_config.json 的 MY_WG_PUBLIC_KEY
```

所有 Peer 共用这一把私钥；每份配置里只写对端公钥，本端私钥由 `PostUp = wg set %i private-key ...` 注入。

#### 2.4.5 BIRD 模板示例

Agent 生成的所有会话都使用 `from dn42_peers`，因此节点 BIRD 配置中必须存在同名模板：

```bird
template bgp dn42_peers {
    local as 4242421816;          # 替换为你的 DN42 ASN

    ipv4 {
        import filter dn42_import_v4;
        export filter dn42_export_v4;
    };

    ipv6 {
        import filter dn42_import_v6;
        export filter dn42_export_v6;
    };
}
```

过滤函数 `dn42_import_v4` / `dn42_export_v4` / `dn42_import_v6` / `dn42_export_v6` 不属于本项目，需部署者按自己的 ROA/前缀策略实现。Agent 生成的会话块只负责 `neighbor`、`description` 与单栈屏蔽，不覆盖模板中的过滤逻辑。

#### 2.4.6 Webhook 反向代理

Telegram 只接受 HTTPS webhook，而 Server 内置的 aiohttp 只监听明文 HTTP，因此需要反代：

```nginx
server {
    listen 443 ssl http2;
    server_name bot.example.com;

    ssl_certificate     /etc/letsencrypt/live/bot.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/bot.example.com/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:3443;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        # 必须透传 Telegram 的 secret header，默认会透传，不要显式清除
    }
}
```

配置对应：

```python
WEBHOOK_URL = "https://bot.example.com/"
WEBHOOK_LISTEN_HOST = "127.0.0.1"
WEBHOOK_LISTEN_PORT = 3443
```

`WEBHOOK_URL` 留空则回到 polling，无需公网入口。

#### 2.4.7 防火墙与网络

| 位置 | 方向 | 端口 | 来源/目的 |
|---|---|---|---|
| Server | 出 | 443 | `api.telegram.org`（polling 与 webhook 都需要） |
| Server | 入 | 443 | Telegram Webhook 网段（仅 webhook 模式） |
| Server | 出 | `API_PORT` | 各 Agent |
| Agent | 入 | `API_PORT` | 仅 Server IP |
| Agent | 出 | 任意 | 对端 WireGuard 端口、DNS、whois |

建议：Server 与 Agent 之间走 WireGuard 内网；若必须公网，至少加 TLS 或 mTLS（见 §16）。

#### 2.4.8 升级与兼容流程

1. 修改 Agent 协议时，先提升 `AGENT_VERSION`，再提升 Server 的 `MIN_AGENT_VERSION`。
2. 先滚动升级所有 Agent，再升级 Server；否则旧 Agent 会被 Server 判定为过旧而剔除。
3. 升级 Server 前备份 `user_db.pkl`、`step.save`、`map.pkl`。
4. `agent_config.json` 结构变化必须在 Agent 启动时做严格校验并明确报错，避免“半可用”状态。

#### 2.4.9 备份清单

| 文件 | 内容 | 丢失影响 |
|---|---|---|
| `server/user_db.pkl` | 登录映射与特权集合 | 所有用户需重新登录 |
| `server/step.save` | 未完成的多轮操作 | 进行中的流程失效，影响小 |
| `server/map.pkl` | 地图缓存 | 重启后自动重建 |
| `server/config.py` | 部署配置 | 需从备份恢复 |
| `agent/agent_config.json` | 节点身份与开关 | 需从备份恢复 |
| `/etc/wireguard/*.conf` | 所有 Peer 隧道 | 可由 `/info` + 人工重建，但成本高 |
| `/etc/bird/dn42_peers/*.conf` | 所有 BGP 会话 | 同上 |
| `/etc/wireguard/dn42-privatekey` | 本节点私钥 | **不可恢复**，所有 Peer 需重建 |

建议每日备份前五项与 `/etc/bird`、`/etc/wireguard`（私钥单独加密保管）。

#### 2.4.10 上线前自检

```bash
# Agent
python -c "import json;json.load(open('agent_config.json'))"
test -r /etc/wireguard/dn42-privatekey && echo key-ok
wg pubkey < /etc/wireguard/dn42-privatekey
birdc show status
command -v ping traceroute tcping whois dig
ss -lntp | grep <API_PORT>
curl -sS -X POST -H "X-DN42-Bot-Api-Secret-Token: $SECRET" http://127.0.0.1:<API_PORT>/version

# Server
python -c "import config;print(config.SERVERS)"
ls -l user_db.pkl map.pkl 2>/dev/null
python main.py   # 观察启动日志中的节点探测结果
```

---

## 3. 配置项

### 3.1 Server 配置（`server/config.py`）

| 键 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `BOT_TOKEN` | str | 是 | Telegram Bot Token |
| `CONTACT` | str | 是 | 联系方式；启动时会转义 Markdown 特殊字符 |
| `DN42_ASN` | int | 是 | 本网络 ASN，用于展示和端口默认值 |
| `WELCOME_TEXT` | str | 是 | `/help` 顶部文案 |
| `WHOIS_ADDRESS` | str | 是 | whois 服务地址（通常 `127.0.0.1`） |
| `DN42_ONLY` | bool | 是 | 工具命令是否只允许 DN42 目标 |
| `ALLOW_NO_CLEARNET` | bool | 是 | 是否允许无公网地址 Peer |
| `ENDPOINT` | str | 是 | 节点域名后缀；Agent API 为 `{region}.{ENDPOINT}`，也用于隧道展示 |
| `API_PORT` | int | 是 | Agent API 端口 |
| `API_TOKEN` | str | 是 | Agent API Secret |
| `SERVERS` | dict[str,str] | 是 | `region -> 展示名`，如 `{"hkg": "HKG | Hong Kong | Skywolf"}` |
| `HOSTS` | dict[str,str] | 否 | `region -> API host` 覆盖值 |
| `WEBHOOK_URL` | str | 否 | 非空则启用 webhook，否则 polling |
| `WEBHOOK_LISTEN_HOST` | str | webhook 时必填 | |
| `WEBHOOK_LISTEN_PORT` | int | webhook 时必填 | |
| `LG_DOMAIN` | str | 否 | Looking Glass 基础 URL（bird-lg 格式） |
| `PRIVILEGE_CODE` | str | 否 | 特权登录码；空则禁用 |
| `SINGLE_PRIVILEGE` | bool | 否 | 已有特权用户时是否禁止再登特权 |
| `FLAPALERTED_URL` | str | 否 | FlapAlerted 实例 URL；空则关闭集成 |
| `CN_WHITELIST_IP` | list[str] | 否 | 被明确视为非中国大陆的 IP/网段 |
| `SENTRY_DSN` | str/None | 否 | Sentry DSN |
| `send_email(asn, mnt, code, email)` | function | 是 | 部署者实现；失败必须抛 `RuntimeError` |

`send_email` 参考实现：SMTP + STARTTLS，正文包含 `code`；任何异常转换为 `RuntimeError`。

### 3.2 Agent 配置（`agent/agent_config.json`）

| 键 | 类型 | 说明 |
|---|---|---|
| `HOST` | str | API 监听地址 |
| `PORT` | int | API 端口 |
| `SECRET` | str | 与 Server `API_TOKEN` 一致 |
| `OPEN` | bool | 是否对外开放 Peer |
| `MAX_PEERS` | int | 最大 Peer 数，0 为不限 |
| `MIN_PEER_REQUIREMENT` | int | 申请者至少已有多少 Peer，0 为不限 |
| `NET_SUPPORT` | object | 见下 |
| `EXTRA_MSG` | str | 节点列表中的附加提示 |
| `MY_DN42_LINK_LOCAL_ADDRESS` | str | 本节点 LLA，如 `fe80::1816` |
| `MY_DN42_ULA_ADDRESS` | str | 本节点 ULA，如 `fd2c:1323:4042::1` |
| `MY_DN42_IPv4_ADDRESS` | str | 本节点 DN42 IPv4，如 `172.23.246.1` |
| `MY_WG_PUBLIC_KEY` | str | 本节点 WG 公钥 |
| `SENTRY_DSN` | str | 空则关闭 |
| `BIRD_TABLE_4` / `BIRD_TABLE_6` | str | 通常 `master4` / `master6` |
| `VNSTAT_AUTO_ADD` | bool | 建 Peer 时 `vnstat --add` |
| `VNSTAT_AUTO_REMOVE` | bool | 删 Peer 时 `vnstat --remove`；仅当 ADD 为真才生效 |

`NET_SUPPORT` 子项：

```json
{"ipv4": true, "ipv6": true, "ipv4_nat": false, "cn": false}
```

- `ipv4_nat`：本节点 IPv4 是否在 NAT 后（为真时要求对方提供公网地址）。
- `cn`：是否允许与中国大陆 Peer（为假时 Server 会拦截大陆 IP）。

Agent 启动时读取配置失败直接 `exit(1)`。

### 3.3 完整配置示例

#### 3.3.1 `server/config.py`

```python
import smtplib
from email.mime.text import MIMEText
from email.header import Header

BOT_TOKEN = "123456:AA..."
CONTACT = "@your_admin"
DN42_ASN = 4242421816
WELCOME_TEXT = (
    "Welcome to use the DN42 Peer Bot.\n"
    "欢迎使用 DN42 Peer Bot。\n"
    "Use /peer to create a peer, /info to view information."
)

WHOIS_ADDRESS = "127.0.0.1"

DN42_ONLY = False
ALLOW_NO_CLEARNET = True
ENDPOINT = "dn42.example.com"

API_PORT = 54321
API_TOKEN = "replace-with-a-long-random-string"

SERVERS = {
    "hkg": "HKG | Hong Kong | ExampleNet",
    "sgp": "SGP | Singapore | ExampleNet",
}

# 仅当某节点的 API 域名不是 "{region}.{ENDPOINT}" 时才需要
HOSTS = {
    # "hkg": "10.0.0.11",
}

WEBHOOK_URL = ""          # 留空使用 polling
WEBHOOK_LISTEN_HOST = "127.0.0.1"
WEBHOOK_LISTEN_PORT = 3443

LG_DOMAIN = ""            # 例如 "https://lg.example.com"
PRIVILEGE_CODE = ""       # 留空禁用
SINGLE_PRIVILEGE = False

FLAPALERTED_URL = ""      # 例如 "https://flap.example.com"
CN_WHITELIST_IP = [
    "203.0.113.0/24",     # 明确标记为非中国大陆的地址
]
SENTRY_DSN = None


def send_email(asn, mnt, code, email):
    """发送验证码；失败必须抛 RuntimeError。"""
    try:
        smtp = smtplib.SMTP("smtp.example.com", 587, timeout=10)
        smtp.starttls()
        smtp.login("bot@example.com", "password")
        body = (
            f"Your verification code for AS{asn} ({mnt}) is:\n\n"
            f"{code}\n\n"
            "If you did not request this, please ignore this email.\n"
        )
        msg = MIMEText(body, "plain", "utf-8")
        msg["Subject"] = Header(f"DN42 Bot Verification Code - AS{asn}", "utf-8")
        msg["From"] = "bot@example.com"
        msg["To"] = email
        smtp.sendmail("bot@example.com", [email], msg.as_string())
        smtp.quit()
    except BaseException as e:
        raise RuntimeError(f"Failed to send email: {e}") from e
```

要点：

- `CONTACT` 会在启动时做 Markdown 转义，因此可以放心写 `_`、`*`。
- `SERVERS` 的 key 必须与 Agent 所在节点的短名一致，并与 `HOSTS`/`ENDPOINT` 的拼装规则匹配。
- `SERVERS` 的 value 只是展示名，但 **必须全局唯一**：`/peer` 的节点选择键盘把展示名当作键来反查 region。

#### 3.3.2 `agent/agent_config.json`

```json
{
  "HOST": "0.0.0.0",
  "PORT": 54321,
  "SECRET": "replace-with-a-long-random-string",
  "OPEN": true,
  "MAX_PEERS": 30,
  "MIN_PEER_REQUIREMENT": 5,
  "NET_SUPPORT": {
    "ipv4": true,
    "ipv6": true,
    "ipv4_nat": false,
    "cn": false
  },
  "EXTRA_MSG": "AS4242421816 is a dual-stack node.",
  "MY_DN42_LINK_LOCAL_ADDRESS": "fe80::1816",
  "MY_DN42_ULA_ADDRESS": "fd2c:1323:4042::1",
  "MY_DN42_IPv4_ADDRESS": "172.23.246.1",
  "MY_WG_PUBLIC_KEY": "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=",
  "SENTRY_DSN": "",
  "BIRD_TABLE_4": "master4",
  "BIRD_TABLE_6": "master6",
  "VNSTAT_AUTO_ADD": true,
  "VNSTAT_AUTO_REMOVE": true
}
```

要点：

- `MY_DN42_ULA_ADDRESS` 必须与 WG 配置模板中的本端 ULA 完全一致，否则 `/info` 正则无法解析。
- `MY_DN42_IPv4_ADDRESS` 同理。
- `MAX_PEERS = 0` 表示不限；`MIN_PEER_REQUIREMENT = 0` 表示不要求对方已有 Peer。
- `VNSTAT_AUTO_REMOVE` 仅在 `VNSTAT_AUTO_ADD` 为真时有意义。

---

## 4. 数据模型

### 4.1 Server 全局状态

| 名称 | 结构 | 持久化 |
|---|---|---|
| `db` | `dict[chat_id:int, asn:int]` | `user_db.pkl` |
| `db_privilege` | `set[chat_id]` | 同上，与 `db` 组成 tuple `(db, db_privilege)` |
| `servers` | `dict[region, display_name]`，仅在线且版本合格的节点 | 内存，每 3 分钟刷新 |
| `AS_ROUTE` | `dict[asn, set[prefix_str]]`，来源 DN42 ROA | 内存，每 15 分钟刷新 |
| `ChinaIPv4` / `ChinaIPv6` | `list[ip_network]` | 内存，每日刷新 |
| `ChinaWhitelist` | `list[ip_network]` | 启动时由配置构建 |
| 工具结果缓存 | `ExpiringDict(max_len=500, max_age_seconds=259200)` | 内存 |
| 地图 | `(update_time, data, peer_map)` | `map.pkl` |
| 地图 `data` | `{centrality/closeness/betweenness/peer: list[(rank, asn, name, value)]}` | 由地图接口生成 |
| `peer_map` | `dict[asn, set[neighbor_asn]]` | 同上 |
| Flap 数据 | `list[{ASN, Prefix, TotalCount, RateSec, FirstSeen}]` | 内存，每 5 分钟刷新 |

### 4.2 贯穿 Peer 流程的 `peer_info`

| 键 | 取值示例 | 说明 |
|---|---|---|
| `Region` | `"hkg"` | 节点短名（收集阶段曾短暂是映射表） |
| `ASN` | `4242421816` | 申请者 ASN |
| `Channel` | `"IPv6 & IPv4" / "IPv6 only" / "IPv4 only"` | 路由传递范围 |
| `MP-BGP` | `"IPv6" / "IPv4" / "Not supported"` | 承载双栈的会话类型 |
| `ENH` | `True/False/None` | 是否支持 Extended Next Hop |
| `IPv6` | `"fe80::1234"` 或 `"Not enabled"` | 对端 DN42 IPv6 |
| `IPv4` | `"172.20.1.2"` 或 `"Not enabled"` 或 `"Not required due to Extended Next Hop"` | 对端 DN42 IPv4 |
| `Request-LinkLocal` | `"fe80::1816"` 或 `"Not required due to not use LLA as IPv6"` | 要求本节点使用的 LLA |
| `Clearnet` | `"1.2.3.4:21816"`、`"[2001:db8::1]:21816"`、`None` | 对端隧道端点；None 表示对方无公网 |
| `Port` | `"21816"` | **本节点**为该 Peer 监听的端口 |
| `PublicKey` | 44 字符 base64 | 对端 WG 公钥 |
| `Contact` | `"@user"` / 邮箱 | 对端联系方式 |
| `Net_Support` | 节点 `NET_SUPPORT` 副本 | 用于后续判断 |
| `Provide-LinkLocal` | 本节点 LLA | 节点返回的 `lla` |
| `InfoText` | str | 确认页信息文本，提交前弹出 |
| `ProgressType` | `"peer" / "modify"` | 提交前弹出 |
| `OldRegion` | `"hkg"` | 仅 modify 迁移时存在 |
| `backup` | dict | 仅 modify，用于 diff |

### 4.3 枚举与哨兵值速查

复刻时最容易出错的是“用字符串当状态”。原实现大量依赖精确字符串比较，以下值必须逐字一致（大小写、空格、连字符、标点）。

#### 4.3.1 `Channel`

| 值 | 语义 | 生成条件 |
|---|---|---|
| `IPv6 & IPv4` | 双栈 | 用户选择双栈 |
| `IPv6 only` | 仅 v6 | 用户选择 IPv6 only |
| `IPv4 only` | 仅 v4 | 用户选择 IPv4 only |

比较方式：`Channel == "IPv6 only"`、`Channel == "IPv4 only"`，其余一律视为双栈。因此不要新增第三种单栈命名。

#### 4.3.2 `MP-BGP`

| 值 | 语义 |
|---|---|
| `IPv6` | 用 v6 会话承载双栈 |
| `IPv4` | 用 v4 会话承载双栈 |
| `Not supported` | 不使用 MP-BGP（两个单栈会话） |

#### 4.3.3 `ENH`

| 值 | 语义 |
|---|---|
| `True` | 支持 Extended Next Hop，IPv4 不单独建会话 |
| `False` | 不支持 ENH，双栈需两个会话 |
| `None` | 单栈或未询问（不参与判断） |

判断代码使用 `ENH is not True` 而不是 `not ENH`，因此 `None` 与 `False` 等价。

#### 4.3.4 IPv6 / IPv4 哨兵

| 字段 | 哨兵值 | 含义 |
|---|---|---|
| `IPv6` | `Not enabled` | 不启用 v6 |
| `IPv4` | `Not enabled` | 不启用 v4 |
| `IPv4` | `Not required due to Extended Next Hop` | 由 ENH 承载，不单独填写 |
| `Request-LinkLocal` | `Not required due to not use LLA as IPv6` | 使用 ULA，无需指定本端 LLA |

渲染层必须识别这三个哨兵，不能把它们当普通地址展示。

#### 4.3.5 `session` → 修改状态映射

| `session` | Channel | MP-BGP | ENH |
|---|---|---|---|
| `IPv6 Session with IPv6 channel only` | `IPv6 only` | `Not supported` | `None` |
| `IPv4 Session with IPv4 channel only` | `IPv4 only` | `Not supported` | `None` |
| `IPv6 Session with IPv6 & IPv4 Channels` | `IPv6 & IPv4` | `IPv6` | `IPv4 == "Not enabled"` → `True`，否则 `False` |
| `IPv4 Session with IPv6 & IPv4 Channels` | `IPv6 & IPv4` | `IPv4` | `None` |
| `IPv6 & IPv4 Session with their own channels` | `IPv6 & IPv4` | `Not supported`（默认分支） | `None` |

复刻建议：虽然原实现没有显式处理第五种，但它落入“双栈 + Not supported”分支，生成结果与实际配置一致（两个单栈会话），可以保留该行为。

#### 4.3.6 其他状态值

| 字段 | 值 | 说明 |
|---|---|---|
| `ProgressType` | `peer` / `modify` | 决定提交前提示语与结果文案 |
| `OldRegion` | region 短名 | 仅跨节点迁移存在 |
| `Region`（收集阶段） | `dict[展示名] = (region, lla, net_support)` | 选择后替换为字符串 |
| Agent 返回状态 | `200` / `403` / `400` / `404` / `408` / `500` / `503` | 见 §5.3 |
| 节点可用性 | `online` / `offline` / `outdated` | `servers_check` 内部判定 |
| Flap 排序键 | `Count` / `RateSec` / `FirstSeen` / `ASN` | 按钮文本即排序键 |
| Rank 指标键 | `centrality` / `closeness` / `betweenness` / `peer` | `callback_data` 中的 `rank_type` |
| 会话角色 | `Established` / `up` / `start` / `down` | Bird 原始输出，不做翻译 |

---

## 5. 双端 API 规范

### 5.1 通用约定

- 方法：全部 `POST`。
- 鉴权：Header `X-DN42-Bot-Api-Secret-Token` 必须等于 Agent 的 `SECRET`，否则 `403`。
- 请求体：`text/plain`（多数）或 `application/json`（`/peer`）。Server 用 `data=...` 发送，Agent 用 `await request.text()` / `await request.json()` 读取。
- 无 TLS。
- `200` 为成功；`400` 参数非法；`403` 鉴权失败；`404` 资源不存在；`408` 超时；`500` 内部错误；`503` 不开放/容量满。

### 5.2 端点定义

#### `POST /version`

- 请求体：无。
- 响应：`AGENT_VERSION` 十进制字符串。
- Server 用途：每 3 分钟探测；版本 `< MIN_AGENT_VERSION(27)` 视为过旧并从可用节点剔除。

#### `POST /pre_peer`

- 请求体：无。
- 响应 JSON：

```json
{
  "existed": 12,
  "max": 30,
  "requirement": 0,
  "open": true,
  "net_support": {"ipv4": true, "ipv6": true, "ipv4_nat": false, "cn": false},
  "lla": "fe80::1816",
  "msg": ""
}
```

- `existed` 计数规则：同时统计 `/etc/wireguard/dn42-*.conf` 与 `/etc/bird/dn42_peers/*.conf` 中文件名为纯数字的条目；两者数量不一致返回 `500 "wireguard and bird config not match"`。

#### `POST /info`

- 请求体：ASN 十进制字符串。
- 错误：
  - 非整数 → `400`
  - 两份配置都不存在 → `404`
  - 只有 wg → `500 "wg only"`
  - 只有 bird → `500 "bird only"`
  - 解析失败 → `500 "wg error" / "bird error" / "session error" / "no session"`
- 成功 JSON：

```json
{
  "port": "21816",
  "v6": "fe80::1234",
  "v4": "172.20.1.2",
  "clearnet": "1.2.3.4:21816",
  "pubkey": "....44chars=",
  "desc": "@someone",
  "session": "IPv6 Session with IPv6 & IPv4 Channels",
  "session_name": ["DN42_4242421816_v6", "DN42_4242421816_v4"],
  "my_v6": "fe80::1816",
  "my_v4": "172.23.246.1",
  "my_pubkey": "....44chars=",
  "wg_last_handshake": 1729999999,
  "wg_transfer": [12345, 67890],
  "bird_status": {
    "DN42_4242421816_v6": ["Established", "", {"4": "12", "6": "34"}]
  },
  "net_support": {"ipv4": true, "ipv6": true, "ipv4_nat": false, "cn": false},
  "lla": "fe80::1816"
}
```

`session` 是 Server 反推修改状态的关键，必须严格使用以下枚举：

| 值 | 含义 |
|---|---|
| `IPv6 Session with IPv6 channel only` | 仅 v6 会话，屏蔽 v4 |
| `IPv4 Session with IPv4 channel only` | 仅 v4 会话，屏蔽 v6 |
| `IPv6 Session with IPv6 & IPv4 Channels` | v6 会话承载双栈 |
| `IPv4 Session with IPv6 & IPv4 Channels` | v4 会话承载双栈 |
| `IPv6 & IPv4 Session with their own channels` | 两个单栈会话 |

`bird_status` 值结构：`[状态, 附加信息行, {地址族: 路由数}]`。仅当状态为 `Established` 且通道 `State == UP`、`Output filter == "(unnamed)"` 时记录路由数。

#### `POST /peer`

- 请求体：`peer_info` JSON（`InfoText`、`ProgressType` 已在 Server 侧移除）。
- 前置检查：
  - 若该 ASN 两份配置已存在，则忽略容量与开放限制（允许覆盖/修改）。
  - 否则：`MAX_PEERS != 0 && existed >= MAX_PEERS` 或 `OPEN == false` → `503`。
  - 配置计数不一致 → `500`。
- 成功：`200`，无响应体。
- 副作用：写 wg 配置 → 写 bird 配置 → `systemctl daemon-reload` → `systemctl enable wg-quick@dn42-{ASN}` → `systemctl restart ...` → `birdc c` → 可选 `vnstat --add`。

#### `POST /remove`

- 请求体：ASN 十进制字符串；非法 → `400`。
- 行为：`systemctl stop` → `disable` → 删两份配置（忽略缺失）→ `birdc c` → 可选 `vnstat --remove --force`。
- 恒返回 `200`。

#### `POST /restart`

- 请求体：ASN 十进制字符串；非法 → `400`。
- 行为：`wg-quick@dn42-{ASN}` 重启，`birdc restart DN42_{ASN}_v4` 与 `_v6`。
- 返回判定：
  - 两个 bird 命令都输出 `syntax error`（会话不存在）且 wg 重启成功 → `404`
  - 两个 bird 命令都 `syntax error` 且 wg 失败 → `500 "bird error"`
  - 其余情况 wg 失败 → `500 "wg error"`
  - 否则 `200`

#### 工具端点

| 端点 | 请求体 | 执行 | 超时/错误 |
|---|---|---|---|
| `/ping` | `IP` | `ping -c 5 -w 6 {IP}` | 8s → `408` |
| `/trace` | `IP` | `traceroute -q1 -N32 -w1 {IP}`，8s 超时后重试 `-n` | 两次均超时 → `408` |
| `/tcping` | `IP PORT` | `tcping --no-color -c 5 {IP} {PORT}` | 10s → `408` |
| `/route` | `IP` 或 `IP/LEN` | 含 `:` 用 `master6`，否则 `master4`；`birdc show route table {table} for {target} all primary` | `408` |
| `/path` | 同上 | 同 `/route`，从输出中提取 `BGP.as_path` | 无匹配 → `404` |

`/trace` 后处理：反转行、去掉尾部空行、把末尾连续的“纯数字 + `*`”跳数移除并统计为 `N hops not responding.` 附在末尾。

`/tcping` 后处理：删除 `\n\nPing stopped/interrupted.\n\n`。

### 5.3 Server 对 Agent 响应的处理矩阵

这张表决定“节点离线 / 未 Peer / 服务错误”三者的区分，复刻时不能混用。

| 端点 | `200` | `403` | `404` | `408` | `500` | `503` | 其他/连接失败 |
|---|---|---|---|---|---|---|---|
| `/version` | 版本合格则上线 | 视为离线 | 视为离线 | 离线 | 离线 | 离线 | 离线 |
| `/pre_peer` | 解析 JSON 渲染节点 | 渲染“服务器错误” | 同左 | 同左 | 渲染错误文本 | 同左 | 渲染“服务器离线” |
| `/info` | 收录 dict | 不收录（当作未 Peer） | **不收录**（未 Peer） | 不收录 | 收录错误字符串 | 不收录 | 不收录 |
| `/peer` | 成功 | 统一报错 | 统一报错 | 统一报错 | 统一报错 | 专属“未开放/已满” | 统一报错 |
| `/remove` | 成功 | 统一报错 | 统一报错 | 统一报错 | 统一报错 | 统一报错 | 统一报错 |
| `/restart` | 成功 | 统一报错 | 统一报错 | 统一报错 | 统一报错 | 统一报错 | 统一报错 |
| 工具端点 | 渲染结果 | 通用错误 | `path` 显示 Not found，其余通用错误 | 显示 Timeout | 通用错误 | 通用错误 | 通用错误 |

`get_info()` 的收录规则（必须保持一致）：

```python
if status == 200:
    try:
        result[region] = json.loads(text)
    except BaseException:
        result[region] = "Error"
elif status == 500:
    result[region] = text
# 403 / 404 / 408 / 连接失败：不收录
```

由此产生两个副作用，复刻时要理解：

1. `404` 表示“该节点没有这个 Peer”，因此 `/peer init` 用 `get_info(asn).keys()` 判断“已 Peer 的节点”。
2. Agent 宕机或 `500` 也会让某节点缺失，可能被误判为“未 Peer”。原实现接受该风险；若要改进，可让 `get_info` 同时返回 `(data, errors)` 并在 UI 标注。

### 5.4 联调命令

以下命令可直接用于验证 Agent 行为（`$S` 为 Secret，`$H` 为 `host:port`）：

```bash
# 版本
curl -sS -X POST -H "X-DN42-Bot-Api-Secret-Token: $S" http://$H/version

# 节点画像
curl -sS -X POST -H "X-DN42-Bot-Api-Secret-Token: $S" http://$H/pre_peer

# 查询 Peer
curl -sS -X POST -H "X-DN42-Bot-Api-Secret-Token: $S" \
     --data '4242421816' http://$H/info

# 创建 Peer（JSON 体）
curl -sS -X POST -H "X-DN42-Bot-Api-Secret-Token: $S" \
     -H 'Content-Type: application/json' \
     --data @peer.json http://$H/peer

# 删除 / 重启
curl -sS -X POST -H "X-DN42-Bot-Api-Secret-Token: $S" --data '4242421816' http://$H/remove
curl -sS -X POST -H "X-DN42-Bot-Api-Secret-Token: $S" --data '4242421816' http://$H/restart

# 工具
curl -sS -X POST -H "X-DN42-Bot-Api-Secret-Token: $S" --data '1.1.1.1' http://$H/ping
curl -sS -X POST -H "X-DN42-Bot-Api-Secret-Token: $S" --data '1.1.1.1 443' http://$H/tcping
curl -sS -X POST -H "X-DN42-Bot-Api-Secret-Token: $S" --data '1.1.1.1/32' http://$H/route
```

`peer.json` 最小示例：

```json
{
  "ASN": 4242421816,
  "Channel": "IPv6 & IPv4",
  "MP-BGP": "IPv6",
  "ENH": true,
  "IPv6": "fe80::1816",
  "IPv4": "Not required due to Extended Next Hop",
  "Request-LinkLocal": "fe80::1816",
  "Clearnet": "203.0.113.10:21816",
  "Port": "21816",
  "PublicKey": "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=",
  "Contact": "@peer"
}
```

注意：`/peer` 的 JSON 解码不依赖 `Content-Type`，但建议显式携带，便于中间件/网关处理。

---

## 6. Server 实现规格

### 6.1 启动顺序（必须按序）

1. 关闭 urllib3 的 InsecureRequestWarning。
2. 转义 `CONTACT` 中的 Markdown 特殊字符。
3. 若配置 Sentry DSN，初始化 Sentry（`traces_sample_rate=0`）。
4. `update_china_ip()`。
5. `update_as_route_table()`。
6. `servers_check(startup=True)`（`retry=0`）。
7. 加载 `map.pkl`；失败则立即 `get_map(update=True)`。
8. 若配置 FlapAlerted，`get_flaps(update=True)`。
9. 创建 `BackgroundScheduler`（timezone=UTC，`misfire_grace_time=None`、`coalesce=True`、`replace_existing=True`）。
10. 注册定时任务并 `start()`。
11. 注册自定义过滤器与中间件。
12. 删除旧命令菜单，按“公开命令 / 私聊全量命令”两次 `set_my_commands`。
13. `enable_save_next_step_handlers(delay=2, filename="./step.save")` 并 `load_next_step_handlers`。
14. `remove_webhook()`；配置了 `WEBHOOK_URL` 则生成 32 位 secret、设置 webhook 并启动 aiohttp；否则 `infinity_polling()`。

### 6.2 中间件与过滤器

- `IsPrivateChat`：非私聊时回复“仅私聊可用”（双语）并返回 False。
- `MyMiddleware`（仅 message）：
  - 无文本 → `CancelUpdate`；
  - `命令@botname` 中的 botname 不是自己 → `CancelUpdate`；
  - 命令以 `/` 开头且配置 Sentry 时开启事务，记录 username、fullname、chat_id、chat_type、ASN/特权标记、群标题；
  - 异常时回复“Error encountered! Please contact {CONTACT}”，事务标记 error，否则 ok，并 `finish()`。

### 6.3 命令菜单

公开命令：

```text
ping tcping trace route path whois dig rank stats peer_list flaps(可选) cancel help
```

私聊额外可见：

```text
login logout whoami peer modify remove info restart
```

### 6.4 通用工具函数规格

#### `gen_random_code(length)`

字符集 `ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789`（去掉易混淆的 `I/O/0/1`），使用 `random.SystemRandom()`。

#### `split_long_msg(msg, limit=4000)`

按 `limit` 内最后一个换行切分；找不到换行返回 `None`（表示单行过长，调用方需处理）。

#### `get_whoisinfo_by_asn(asn, item=...)`

- 先用 `extract_asn` 归一化；失败返回 `str(asn)`。
- `item` 默认 `mnt-by`；ASN 在 `[4201270000, 4201280000)` 时默认 `admin-c`。
- 执行 `whois -h {WHOIS_ADDRESS} AS{asn}`（3s 超时），取首个匹配行。
- 去掉首尾的 `MNT` / `AS` / `DN42` 前缀或 `-MNT` / `-AS` / `-DN42` 后缀。
- 任何异常返回 `str(asn)`。

#### `get_asn_mnt_text(asn)`

whois 名与 ASN 不同则返回 `"{name} AS{asn}"`，否则 `"AS{asn}"`。

#### `basic_ip_domain_test(address)`

- 先按 IPv4 字面量测试，成功则尝试 PTR 反解；
- 再按 IPv6 字面量测试，成功则尝试 PTR 反解；
- 最后按域名解析 A 与 AAAA，各取第一条。
- 解析器列表：`127.0.0.1, 172.20.0.53, 172.23.0.53, 8.8.8.8, 8.8.4.4`；`timeout=0.5`，`lifetime=3`。
- 返回 `(raw, ipv4, ipv6, domain)` 或 `None`。

#### `test_ip_domain(testcase)`

返回 `(raw, ipv4, ipv6, domain, asn, mnt, dn42, clearnet)` 或 `None`。

DN42 判定（满足任一）：

1. `raw` 以 `.dn42` 结尾；
2. PTR 得到的 `domain` 以 `.dn42` 结尾；
3. `raw` 等于解析出的 IP，且 IPv4 ∈ `172.20.0.0/14` 或 `10.127.0.0/16`，或 IPv6 ∈ `fc00::/7`。

若判为 DN42：

- 执行 `whois -h ... -T route {ipv4}` 与 `-T route6 {ipv6}`；
- 收集所有 `origin:` 为 ASN 集合，`mnt-by:` 为 MNT；
- 没有任何 origin → 判定失败，回落为 clearnet。

非 DN42 时用 Bogon 列表判定 clearnet（IPv4/IPv6 各一份，见原实现）。若只有一个地址族为公网，另一族强制置 `None`。

#### `gen_peer_me_markup(message)`

在消息末尾附加“Peer with me | 与我 Peer”按钮，但以下情况不附加：

- 私聊且该 chat_id 在特权集合；
- 私聊、已登录且该 ASN 已有任一 Peer（`tools.get_info` 非空）。

#### `gen_login_message(message)`

发送“请先 /login”，附 `?start=login` 深链按钮。

#### `get_from_agent(type, data, server=None, timeout=10, retry=5, backoff_factor=0.1)`

- `server` 缺省为所有在线节点；
- 用 `FuturesSession` 并发 POST，URL 为 `http://{HOSTS[region] 或 region.ENDPOINT}:{API_PORT}/{type}`；
- Header 附带 `API_TOKEN`；
- 结果 `dict[region] = (text, status)`；超时归一为 `408`，其他异常 `500`。

#### `get_info(asn)`

对所有在线节点请求 `/info`，`200` 时把响应 JSON 解析为 dict，解析失败存 `"Error"`；`500` 时存响应文本；其他状态不收录。返回 `dict[region] = dict | str`。

#### `extract_asn(text, privilege=False)`

1. 去 `AS` 前缀（标记 `disallow_extend=True`），转 int；失败返回 `None`。
2. whois 查询 `AS{asn}`，命中 `aut-num` 直接返回。
3. 未命中时：
   - 若输入带 `AS` 前缀：`privilege` 下返回原值，否则 `None`；
   - `asn < 10000` → `asn + 4242420000`；
   - `20000 <= asn < 30000` → `asn + 4242400000`；
   - 其他：`privilege` 下返回原值，否则 `None`。
4. 对补全后的 ASN 再查一次 whois，命中返回，否则按上一条规则回落。
5. whois 执行异常时直接返回 `original_asn`。

### 6.5 定时任务

| 任务 | 频率（UTC） | 说明 |
|---|---|---|
| `servers_check` | 每 3 分钟 | 探测 `/version`；可用节点集合变化时通知所有特权用户 |
| `get_map` | 每 3 分钟 | 拉 DN42 地图并重算中心性 |
| `update_china_ip` | 每日 01:30 | 拉中国 IP 段 |
| `update_as_route_table` | 每小时第 7、22、37、52 分 | 拉 DN42 ROA |
| `get_flaps` | 每 5 分钟 | 仅在配置 `FLAPALERTED_URL` 时 |

`servers_check` 的行为：

- 启动时 `retry=0`，运行期 `backoff_factor=1`；
- 状态非 200 → 离线；版本小于 27 → 过旧；
- 用“在线且版本合格”重建 `base.servers`；
- 若集合发生变化，向特权用户发送在线/离线/过旧清单；
- 启动时若一个可用节点都没有，发送“No available nodes.”。

### 6.6 地图与统计

`get_map(update=...)`：

1. 请求 `https://api.iedon.com/dn42/map?type=json`；
2. 若 `metadata.data_timestamp <= update_time` 直接跳过；
3. 构建无向图（忽略自环）；
4. 计算 `closeness_centrality`、`betweenness_centrality`、每个 ASN 的邻居数；
5. 自定义 `centrality`：两类中心性分别 min-max 线性映射到 `[10, 30]`，betweenness 先取四次方根，最后取平均；
6. 四类指标各自按值降序、ASN 升序排名（并列同名次）；
7. `as-name` 通过 whois 获取并缓存 1 小时；
8. 结果与 `peer_map` 一起写入 `map.pkl`。

`get_flaps()`：

- 请求 `{FLAPALERTED_URL 的 scheme+netloc}/flaps/active/compact`；
- 对每个前缀：已有记录复用 ASN，否则 whois 查 `origin:`，失败记 `-1`；
- 按 ASN 查询时返回该 ASN 的前缀，按网络地址排序。

### 6.7 模块与函数清单

下表可作为实现拆分依据；标 `*` 的是必须严格对齐行为的函数。

#### `server/main.py`

| 函数/对象 | 职责 |
|---|---|
| `IsPrivateChat.check(message)` | 私聊过滤器，非私聊回复并拒绝 |
| `IsForMe.check(message)` | 原实现已定义但未注册，可忽略 |
| `MyMiddleware.pre_process(message, data)` | 空文本/错误 botname 拦截、Sentry 事务、记录上下文字段 |
| `MyMiddleware.post_process(message, data, exception)` | 异常统一回复、事务状态收尾 |
| `scheduler_add_job(func, *args, **kwargs)` | 以统一默认参数注册定时任务 |
| `handle(request)` | webhook 入口，校验 secret 后交给 `bot.process_new_updates` |
| `health(request)` | 返回逗号拼接的 `base.servers.keys()` |

#### `server/tools/tools.py`

| 函数 | 职责 |
|---|---|
| `gen_random_code(length)` | 无易混淆字符的随机码 |
| `split_long_msg(msg, limit=4000)` | 按行切分长消息；单行超限返回 `None` |
| `get_whoisinfo_by_asn(asn, item=...)` | whois 取 `mnt-by`/`admin-c`，清洗前缀后缀 |
| `get_asn_mnt_text(asn)` | 组合 `MNT ASxxxx` 展示文本 |
| `basic_ip_domain_test(address)` | IP/域名 → `raw/ipv4/ipv6/domain` |
| `test_ip_domain(testcase)` | 在上一函数基础上扩展 `asn/mnt/dn42/clearnet` |
| `gen_peer_me_markup(message)` | 判断是否附加“与我 Peer”按钮 |
| `gen_login_message(message)` | 发送登录引导 |
| `get_from_agent(type, data, server=None, *, timeout, retry, backoff)` | 并发调用 Agent |
| `get_info(asn)` | 聚合 `/info`，仅收录 200/500 |
| `extract_asn(text, *, privilege=False)` | ASN 归一化与存在性校验 |
| `get_extra_route(asn)`（在 whois.py） | 从 ROA 表构建路由展示 |
| `global_text` | Markdown 转义后的联系方式 |

#### `server/tools/*` 定时与集成

| 函数 | 职责 |
|---|---|
| `servers_check(startup=False)` | `/version` 探测，重建 `base.servers`，变更通知 |
| `gen_get_map()` → `get_map(*, update=None)` | 地图拉取、中心性计算、`map.pkl` 持久化 |
| `gen_get_flaps()` → `get_flaps(*, update=False, asn=None)` | FlapAlerted 拉取、whois origin 补全 |
| `update_china_ip()` | 中国 IP 段刷新 |
| `update_as_route_table()` | DN42 ROA 路由表刷新 |

#### `server/commands/*`

| 文件 | 主要函数 |
|---|---|
| `start.py` | `startup`（深链分发） |
| `help.py` | `send_welcome`、`get_chatid` |
| `cancel.py` | `cancel` |
| `tools/all_in_one.py` | `gen_generaltest_markup`、`generaltest_callback_query`、`generaltest` |
| `tools/dig.py` | `dig` |
| `tools/whois.py` | `get_extra_route`、`whois` |
| `user_manage/login.py` | `get_email`、`start_login`、`login_input_asn`、`login_choose_email`、`login_verify_code` |
| `user_manage/logout.py` | `start_logout` |
| `user_manage/whoami.py` | `whoami` |
| `peer/peer.py` | `start_peer`、`step_manage`、`init`、`pre_confirm` |
| `peer/info_collect.py` | 下表的 `pre_*`/`post_*` 全部步骤 |
| `peer/modify.py` | `start_modify`、`step_manage`、`recreate_peer_info`、`get_diff_text`、`init`、`pre_node_choose`、`post_node_choose`、`pre_first_action_choose`、`pre_action_choose`、`post_action_choose`、`pre_confirm` |
| `peer/remove.py` | `remove_peer`、`remove_peer_choose`、`remove_peer_confirm` |
| `peer/restart.py` | `restart_peer`、`restart_peer_choose`、`restart_peer_confirm` |
| `peer/info.py` | `convert_size`、`td_format`、`basic_info`、`gen_info_markup`、`get_info_text`、`info_callback_query`、`get_info` |
| `statistics/rank.py` | `gen_rank_markup`、`get_rank_text`、`rank_callback_query`、`get_rank` |
| `statistics/stats.py` | `get_stats`、`stats` |
| `statistics/peer_list.py` | `peer_list` |
| `statistics/flaps.py` | `gen_flaps_markup`、`get_flaps_text`、`flaps_callback_query`、`get_flaps` |

`info_collect.py` 步骤函数与返回：

| 函数 | 读取输入 | 下一步 |
|---|---|---|
| `pre_region` | 否 | `post_region` |
| `post_region` | 节点展示名 | `pre_session_type` |
| `pre_session_type` | 否 | `post_session_type` |
| `post_session_type` | 三选一 | `pre_mpbgp_support` / `pre_ipv6` / `pre_ipv4` |
| `pre_mpbgp_support` | 否 | `post_mpbgp_support` |
| `post_mpbgp_support` | 是/否 | `pre_mpbgp_type` / `pre_ipv6` |
| `pre_mpbgp_type` | 否 | `post_mpbgp_type` |
| `post_mpbgp_type` | IPv6/IPv4 | `pre_enh` / `pre_ipv6` |
| `pre_enh` | 否 | `post_enh` |
| `post_enh` | 是/否 | `pre_ipv6` |
| `pre_ipv6` | 否 | `post_ipv6` |
| `post_ipv6` | IPv6 | `pre_request_linklocal` / `pre_ipv4` / `pre_clearnet` |
| `pre_request_linklocal` | 否 | `post_request_linklocal` |
| `post_request_linklocal` | LLA | `pre_ipv4` / `pre_clearnet` |
| `pre_ipv4` | 否 | `post_ipv4` |
| `post_ipv4` | IPv4 | `pre_clearnet` |
| `pre_clearnet` | 否 | `post_clearnet` |
| `post_clearnet` | 地址/`none` | `pre_clearnet_port` / `pre_port_myside` / `pre_pubkey` |
| `pre_clearnet_port` | 否 | `post_clearnet_port` |
| `post_clearnet_port` | 端口 | `pre_port_myside` / `pre_pubkey` |
| `pre_port_myside` | 否 | `post_port_myside` |
| `post_port_myside` | 端口 | `pre_pubkey` |
| `pre_pubkey` | 否 | `post_pubkey` |
| `post_pubkey` | 公钥 | `pre_contact` |
| `pre_contact` | 否 | `post_contact` |
| `post_contact` | 联系方式 | `pre_confirm`（由 `step_manage` 进入） |
| `post_confirm` | `yes` | 结束 |

#### `agent/*`

| 对象 | 职责 |
|---|---|
| `base.routes` | 全部 `POST` 路由 |
| `simple_run(command, timeout=3)` | `shlex.split` + `subprocess`，返回 stdout+stderr |
| `set_sentry(func)` | 异常上报装饰器 |
| `get_current_peer_num()` | 同时统计 wg/bird 配置，数量不等返回 `None` |
| `route_version` | 返回版本号 |
| `route_pre_peer` | 返回节点画像 |
| `route_info` | 解析配置与运行状态 |
| `route_peer` | 容量检查 + 写配置 + 起服务 |
| `route_remove` | 停服务 + 删配置 |
| `route_restart` | 重启隧道与会话 |
| `route_ping` / `route_trace` / `route_tcping` | 工具执行 |
| `route_route` / `route_path` | `birdc` 路由查询 |

### 6.8 关键函数参考实现

以下片段用于消除歧义，可直接改写进项目。

#### 6.8.1 `extract_asn`

原实现只依赖 whois 输出中的固定标记 `% Information related to 'aut-num/AS`，而不是解析 `aut-num:` 字段：

```python
def extract_asn(text, *, privilege=False):
    if not text:
        return None
    try:
        original_asn = int(str(text).removeprefix("AS").removeprefix("as"))
        disallow_extend = str(text).upper().startswith("AS")
    except ValueError:
        return None

    try:
        out = subprocess.run(
            shlex.split(f"whois -h {config.WHOIS_ADDRESS} AS{original_asn}"),
            stdout=subprocess.PIPE, timeout=3
        ).stdout.decode("utf-8").strip()
        if "% Information related to 'aut-num/AS" in out:
            return original_asn

        if disallow_extend:
            return original_asn if privilege else None
        if original_asn < 10000:
            asn = original_asn + 4242420000
        elif 20000 <= original_asn < 30000:
            asn = original_asn + 4242400000
        else:
            return original_asn if privilege else None

        out = subprocess.run(
            shlex.split(f"whois -h {config.WHOIS_ADDRESS} AS{asn}"),
            stdout=subprocess.PIPE, timeout=3
        ).stdout.decode("utf-8").strip()
        if "% Information related to 'aut-num/AS" in out:
            return asn
        return original_asn if privilege else None
    except BaseException:
        return original_asn
```

注意：原实现捕获异常后返回 `original_asn`，即使调用方是普通用户。这意味着 whois 超时会“放行”格式合法的 ASN；真正阻止登录的是后续邮箱步骤。

#### 6.8.2 `split_long_msg`

```python
def split_long_msg(msg, limit=4000):
    chunks, rest = [], msg
    while rest:
        if len(rest) <= limit:
            chunks.append(rest)
            break
        idx = rest.rfind("\n", 0, limit)
        if idx == -1:
            return None          # ⚠️ 调用方必须处理 None
        chunks.append(rest[:idx + 1])
        rest = rest[idx + 1:]
    return chunks
```

#### 6.8.3 `get_from_agent`

```python
ApiResult = namedtuple("api_result", ["text", "status"])

def get_from_agent(type, data, server=None, *, timeout=10, retry=5, backoff_factor=0.1):
    if not server:
        server = base.servers.keys()
    session = FuturesSession()
    session.mount("http://", HTTPAdapter(max_retries=Retry(
        total=retry, backoff_factor=backoff_factor, allowed_methods=("GET", "POST")
    )))
    futures = []
    for region in server:
        api = config.HOSTS.get(region, f"{region}.{config.ENDPOINT}")
        f = session.post(
            f"http://{api}:{config.API_PORT}/{type}",
            data=data,
            headers={"X-DN42-Bot-Api-Secret-Token": config.API_TOKEN},
            timeout=timeout,
        )
        f.region = region
        futures.append(f)

    result = {}
    for f in futures:
        try:
            r = f.result()
            result[f.region] = ApiResult(r.text, r.status_code)
        except requests.exceptions.Timeout:
            result[f.region] = ApiResult("", 408)
        except BaseException:
            result[f.region] = ApiResult("", 500)
    return result
```

关键点：请求按 `server` 的迭代顺序发出，但结果按 future 列表顺序收集；UI 中“第一个节点”对应 `config.SERVERS` 的声明顺序（`servers` 由它构建）。

#### 6.8.4 状态机调度骨架

```python
def step_manage(next_step, peer_info, message):
    def _call(func):
        try:
            rtn = func(message, peer_info)
        except BaseException:
            traceback.print_exc()
        else:
            if rtn:
                step_manage(*rtn)

    if text := (message.text or "").strip():
        if text == "/cancel":
            bot.send_message(message.chat.id, "Current operation has been cancelled.\n当前操作已被取消。")
            return
    _call(getattr(info_collect, next_step) if next_step != "init" else init)
```

要点：

- 必须先判断 `/cancel`，再做状态分发。
- `pre_` 分支直接调用，`post_` 分支在各自函数里 `register_next_step_handler`。
- 异常只打印，不改变状态，用户看起来“没有反应”；复刻时建议至少回复一条错误提示。

#### 6.8.5 中间件骨架

```python
class MyMiddleware:
    def __init__(self):
        self.transaction = None

    def pre_process(self, message, data):
        if not message.text:
            raise CancelUpdate()
        if message.text.startswith("/") and "@" in message.text.split()[0]:
            if message.text.split()[0].split("@")[1].lower() != bot.get_me().username.lower():
                raise CancelUpdate()
        if config.SENTRY_DSN and message.text.startswith("/"):
            self.transaction = sentry_sdk.start_transaction(name=message.text.split()[0])
            self.transaction.set_tag("username", message.from_user.username or "None")
            self.transaction.set_tag("fullname", message.from_user.full_name or "None")
            self.transaction.set_tag("chatid", message.chat.id)
            self.transaction.set_tag("chattype", message.chat.type)
            self.transaction.set_tag("asn", base.db.get(message.chat.id) or "None")
            self.transaction.set_tag("privilege", message.chat.id in base.db_privilege)
            self.transaction.set_tag("chattitle", getattr(message.chat, "title", "None"))
        return data

    def post_process(self, message, data, exception):
        if exception:
            bot.reply_to(message, f"Error encountered! Please contact {config.CONTACT}\n"
                                  f"遇到错误！请联系 {config.CONTACT}")
            if self.transaction:
                self.transaction.set_status("internal_error")
                self.transaction.finish()
        elif self.transaction:
            self.transaction.set_status("ok")
            self.transaction.finish()
```

⚠️ 原实现的 `self.transaction` 是实例级变量，多个线程并发处理消息时会相互覆盖。复刻时建议改为 `threading.local()` 或把事务放进 `data`。

---

## 7. 命令流程规格

### 7.1 状态机约定

统一使用：

```python
def step_manage(next_step, peer_info, message):
    ...
    if next_step.startswith("pre_"):
        step_manage(next_step, peer_info, message)  # 立即执行
    elif next_step.startswith("post_"):
        bot.register_next_step_handler(msg, partial(step_manage, next_step, peer_info))
```

- `pre_xxx(message, peer_info)`：发送提示，通常返回 `("post_xxx", peer_info, msg)`。
- `post_xxx(message, peer_info)`：读取用户输入，返回下一步。
- 任意步骤输入 `/cancel`（严格等于）即终止流程。
- 注意：`/cancel` 命令本身也有一个 handler 回复“没有正在进行的操作”，用于没有活动流程时。

复刻时必须保证：

1. 每次 `post_` 的校验失败都返回自身 `post_` 并重新注册；
2. 每个提示都应带 `ReplyKeyboardRemove()` 或明确的候选键盘；
3. 结束时清理键盘。

### 7.2 `/start`

解析深链参数：

- `login` → 触发登录
- `peer` → 触发建 Peer
- `info` → 查询自己的信息
- `info_{asn}_{node}` → 查询指定 ASN/节点
- `whoami_{asn}_{node}` → 特权切换身份
- 无参数或解析异常 → `/help` 文案

### 7.3 `/login`（仅私聊）

```
start_login
 ├ 已登录 → 提示先 /logout，结束
 ├ 带参数 /login <asn> → login_input_asn
 └ 无参数 → 发“请输入 ASN”，注册 login_input_asn(None)
```

`login_input_asn(exist_asn, message)`：

1. 输入 `/cancel` → 结束。
2. `extract_asn` 失败：
   - 来自参数（`exist_asn` 非空）→ 提示不是注册 ASN，结束；
   - 来自对话 → 提示重试并继续注册 `login_input_asn(None)`。
3. 成功 → `get_email(asn)`：
   - 键盘列出所有邮箱 + “None of the above”；
   - 注册 `login_choose_email(asn, emails, msg_id)`。

`get_email(asn)`：

- whois ASN 输出跳过前 3 行，找 `admin-c:`；
- 再 whois 该 admin-c，收集 `e-mail:` 与 `contact:` 中匹配 `^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$` 的值；
- 失败返回空集合。

`login_choose_email`：

1. `/cancel` → 结束。
2. 若配置了 `PRIVILEGE_CODE`、且未触发 `SINGLE_PRIVILEGE` 限制、且输入等于该码：
   - 写入 `db`、加入 `db_privilege`、持久化；
   - 删除用户消息与选择提示；
   - 发送 `*[Privilege]*` 欢迎语。
3. 输入不在邮箱集合 → 提示只能使用 Registry 登记邮箱，结束。
4. 发送“正在发送验证码”，生成 16 位码，调用 `config.send_email(asn, mnt, code, email)`：
   - `RuntimeError` → 删除提示并告知稍后重试；
   - 成功 → 提示已发送并注册 `login_verify_code`。

`login_verify_code`：大小写不敏感比较；成功写入 `db` 并持久化；失败提示可用 `/login` 重试。

### 7.4 `/logout`、`/whoami`

`/logout`：

- 未登录 → 提示登录；
- 从 `db` 删除；若在特权集合中移除并加 `*[Privilege]*` 前缀；持久化。

`/whoami`：

| 条件 | 行为 |
|---|---|
| 带 `new_asn` 且非特权 | 拒绝（未登录给登录按钮，否则清键盘） |
| 未登录 | 提示登录 |
| 特权 | 参数或命令文本中的 ASN → `extract_asn(privilege=True)` → 更新 `db` 并持久化，显示当前身份 + 查看信息按钮 |
| 普通 | 显示当前身份 |

### 7.5 `/peer`（仅私聊）

入口构造初始 `peer_info`：

```python
{
  "Region": None, "ASN": None, "Channel": None,
  "MP-BGP": "Not supported", "ENH": None,
  "IPv6": "Not enabled", "IPv4": "Not enabled",
  "Request-LinkLocal": "Not required due to not use LLA as IPv6",
  "Clearnet": None, "PublicKey": None, "Port": None, "Contact": None
}
```

#### 步骤 1：`init`

1. 未登录 → 登录提示，结束。
2. `ASN // 10000 != 424242` 且非特权 → 提示无法自动 Peer，联系管理员，结束。
3. 已 Peer 节点集合 = `get_info(asn).keys()`；若覆盖全部 `SERVERS` → 提示已全部 Peer，结束。
4. 展示“将以该身份创建 Peer”，设置 `ASN` 与 `Port = "2" + str(ASN)[-4:]`。
5. 进入 `pre_region`。

#### 步骤 2：`pre_region`（节点选择）

1. 从地图取该 ASN 的 peer 数 `existed_peers`（找不到按 0）。
2. 并发请求所有节点 `/pre_peer`，逐节点渲染：
   - 展示名；
   - 离线 / 服务器错误；
   - 当前节点 / 已 Peer；
   - 开放状态；
   - 容量 `existed / max`（max=0 显示 Unlimited）；
   - 最低 Peer 数要求与实际 peer 数对比；
   - IPv4 / IPv6 支持、IPv4 NAT 警告、CN 限制、`EXTRA_MSG`。
3. 可 Peer 条件：`open == true` 且（`max == 0` 或 `existed < max`）且（`requirement == 0` 或 `existed_peers >= requirement`）。
4. 不满足且非特权 → 记录 `have_unpeerable` 并跳过；特权则记录 `use_privilege` 并允许。
5. 把可 Peer 项写入 `peer_info["Region"][展示名] = (region, lla, net_support)`。
6. 无可选 → 提示无可用节点，结束。
7. 仅一个 → 自动选择并进入 `post_region`。
8. 多个 → 发键盘，注册 `post_region`。

`post_region`：校验展示名，写入 `Provide-LinkLocal`、`Net_Support`，把 `Region` 替换为短名，进入 `pre_session_type`。

#### 步骤 3：会话类型

`pre_session_type` 提供三个按钮：`IPv6 & IPv4`、`IPv6 only`、`IPv4 only`。

`post_session_type` 归一化输入（大小写不敏感，接受 `both` / `ipv6` / `ipv4`）：

- 双栈 → `pre_mpbgp_support`
- 仅 v6 → 关闭 MP-BGP/ENH → `pre_ipv6`
- 仅 v4 → 关闭 MP-BGP/ENH、`IPv6=Not enabled` → `pre_ipv4`

#### 步骤 4：MP-BGP 与 ENH

- `pre_mpbgp_support`：Yes → `pre_mpbgp_type`；No → 关闭 MP-BGP/ENH → `pre_ipv6`。
- `pre_mpbgp_type`：IPv6 → `pre_enh`；IPv4 → 关闭 ENH → `pre_ipv6`。
- `pre_enh`：Yes → `ENH=True`、`IPv4=Not required due to Extended Next Hop`；No → `ENH=False`；随后 `pre_ipv6`。

#### 步骤 5：IPv6

`pre_ipv6` 的候选按钮：

- 编辑流程中已有的 IPv6（若不为 `Not enabled`）；
- 若 ASN 在 `[4242420000, 4242429999]`，提供 `fe80::{ASN % 10000}`。

`post_ipv6`：

1. 去掉 `/长度` 后缀；
2. 必须是 IPv6 字面量，且 ∈ `fc00::/7` 或 `fe80::/64`；
3. LLA → `pre_request_linklocal`；
4. ULA → `Request-LinkLocal` 置默认；若双栈且 `ENH is not True` → `pre_ipv4`，否则 `IPv4=Not enabled` → `pre_clearnet`。

`pre_request_linklocal` / `post_request_linklocal`：只接受 `fe80::/64`；保存后按同样条件进入 `pre_ipv4` 或 `pre_clearnet`。

#### 步骤 6：IPv4

`pre_ipv4` / `post_ipv4`：

- 去掉 `/长度`；
- 必须是 IPv4 字面量，且 ∈ `172.20.0.0/14` 或 `10.127.0.0/16`；
- 保存 → `pre_clearnet`。

#### 步骤 7：公网端点

`pre_clearnet` 先根据 `Net_Support` 生成提示（仅 v4 / 仅 v6 / 双栈；NAT 时要求对方提供公网），并说明：

- `ALLOW_NO_CLEARNET` → 可输入 `none`；
- 特权 → 可输入 `none`；
- 否则提示联系管理员。

`post_clearnet` 分支：

1. **`none` 分支**：满足（`ALLOW_NO_CLEARNET` 或特权）、输入为 `none`、且节点支持 v6 或非 NAT 的 v4：
   - `Clearnet=None`；
   - 特权 → `pre_port_myside`；否则 → `pre_pubkey`。
2. **端口自动识别**：输入恰好含 1 个 `:`，且冒号前无 `:`、冒号后为 1..65535 → 拆出 `ClearnetPort` 并提示“已自动分离”。
3. **地址校验**：
   - `test_ip_domain` 失败或 `clearnet == False` → 报“无效或不可达”；
   - 节点不支持对应地址族 → 报“该节点不支持 IPv4/IPv6”；
   - 节点 `cn == false` 且解析出的 IP 属于中国段且不在白名单 → 报“不允许与中国大陆 Peer”，并提示不要尝试绕过（数据会被防火墙丢弃）。
4. **成功**：保存 `raw`；若为纯 IPv6 字面量（只含十六进制与冒号）则加方括号。
5. **特权兜底**：校验失败但用户是特权 → 发送 `*[Privilege]*` 提示，仍以原始输入继续。
6. 进入 `pre_clearnet_port`。

`pre_clearnet_port`：把上一步的 `ClearnetPort` 弹出作为按钮；若与 `DN42_ASN % 100000` 不同，再加一个默认值按钮。

`post_clearnet_port`：1..65535 校验；`Clearnet += ":port"`；特权 → `pre_port_myside`，否则 → `pre_pubkey`。

`pre_port_myside`（仅特权）：输入给对方提供的端口，默认按钮为 `Port`。

#### 步骤 8：公钥与联系人

`post_pubkey`：长度必须为 44 且以 `=` 结尾（不校验 base64 内容）。

`pre_contact` 按钮：编辑流程中的旧值；去掉 `@` 后与当前 Telegram username 相同的当前值；特权用户的 whois 名。

`post_contact`：非空，且只能包含：

- 大小写字母、数字、空格；
- `!#$%&()*+,-./:;<=>?@[]^_{|}~`

#### 步骤 9：确认提交

`pre_confirm`：

- 生成确认文本：Region、Basic（ASN/Channel/MP-BGP/IPv6/IPv4/Request-LLA）、Tunnel（Endpoint/PublicKey）、Contact；
- 若 `Contact` 与 whois 名（大小写不敏感）不同，附 `(whois 名)`；
- 要求输入 `yes`，其余一律取消；
- 设置 `InfoText` 与 `ProgressType="peer"`；
- 注册 `post_confirm`。

`post_confirm`：

1. 计算 API 地址（`HOSTS` 优先，否则 `region.ENDPOINT`），`POST /peer`，10 秒超时。
2. `503` → 提示节点未开放或已满，结束。
3. 非 `200` → 抛错进入统一错误提示。
4. `modify` 时：
   - 同节点 → 1 秒后 `POST /restart`；失败提示手动 `/restart`；
   - 跨节点 → 向旧节点 `POST /remove`；失败提示手动 `/remove`。
5. 成功：
   - 回复“Peer 已建立 / Peer 信息已修改”，附 `?start=info_{asn}_{region}` 按钮；
   - 向除自己外的所有特权用户发送 `*[Privilege]*` 通知；
   - 若某特权用户当前身份就是该 ASN，只给“Show info”按钮并注明“已在该身份”，否则附“切换至该身份 + Show info”。

### 7.6 `/modify`（仅私聊）

使用带 `stop_sign` 的变体状态机：

```python
step_manage(next_step, peer_info, stop_sign, message)
```

- 每个 `pre_` 步骤执行前检查 `stop_sign`：命中（字符串或可迭代集合）则跳到 `pre_action_choose`，不再继续子流程。
- 子流程返回三元组时沿用当前 `stop_sign`，返回四元组时可更新 `stop_sign`。

流程：

1. `init`：未登录 → 提示；无 Peer → 提示先 `/peer`；否则提示身份，进入 `pre_node_choose`。
2. `pre_node_choose`：列出离线节点；只有一个 Peer 时自动选；否则键盘选择。
3. `post_node_choose`：
   - 展示名反查 region；
   - `recreate_peer_info()` 从 `/info` 结果重建 `peer_info`；
   - `backup = copy()`；
   - 展示当前信息；
   - 进入 `pre_first_action_choose`。
4. 修改菜单：

| 选项 | 进入 | stop_sign |
|---|---|---|
| Region | `pre_region`（非标准 ASN 且非特权时拒绝） | `pre_session_type` |
| Session Type | `pre_session_type` | `pre_clearnet` |
| DN42 IP | `IPv4 only` 用 `pre_ipv4`，否则 `pre_ipv6` | `pre_clearnet` |
| Clearnet Endpoint | `pre_clearnet` | `pre_pubkey` |
| WireGuard PublicKey | `pre_pubkey` | `pre_contact` |
| Contact | `pre_contact` | `pre_confirm` |
| Finish modification | `pre_confirm` | — |
| Abort modification | 发送取消提示并结束 | — |

5. 每次子流程结束回到 `pre_action_choose`，展示 diff；可继续修改。
6. `pre_confirm`：
   - 弹出 `backup`；
   - 完全相等 → 提示“无变更”并结束；
   - 否则生成 diff，设置 `InfoText`、`OldRegion`、`ProgressType="modify"`，进入 `post_confirm`。

`recreate_peer_info(message, chosen)` 映射规则：

```python
{
  "Region": chosen,
  "ASN": db[chat_id],
  "Channel": None,
  "MP-BGP": "Not supported",
  "ENH": None,
  "IPv6": raw["v6"] or "Not enabled",
  "IPv4": raw["v4"] or "Not enabled",
  "Request-LinkLocal": "Not required due to not use LLA as IPv6",
  "Clearnet": raw["clearnet"],
  "PublicKey": raw["pubkey"],
  "Port": raw["port"],
  "Contact": raw["desc"],
  "Net_Support": raw["net_support"],
  "Provide-LinkLocal": raw["lla"],
}
```

- `raw["v6"]` 为 LLA 时：`Request-LinkLocal = raw["my_v6"]`。
- `session` 映射：

| `session` | Channel | MP-BGP | ENH |
|---|---|---|---|
| `IPv6 Session with IPv6 channel only` | IPv6 only | Not supported | None |
| `IPv4 Session with IPv4 channel only` | IPv4 only | Not supported | None |
| `IPv6 Session with IPv6 & IPv4 Channels` | IPv6 & IPv4 | IPv6 | IPv4 为 Not enabled 时 True，否则 False |
| `IPv4 Session with IPv6 & IPv4 Channels` | IPv6 & IPv4 | IPv4 | None |

`get_diff_text(old, new)`：逐字段输出；不同时输出旧值、`->`、新值；Region 不同时额外在 `new` 中写入 `Origin=old_region`（供 Agent 参考，实际删除旧节点由 Server 完成）。

### 7.7 `/remove`（仅私聊）

1. 未登录 → 提示；无 Peer → 提示。
2. 提示身份；列出离线节点。
3. 只有一个 Peer → 自动选；否则键盘选择。
4. `remove_peer_choose`：
   - 校验展示名；
   - `recreate_peer_info` 得到 `last_info`；
   - 展示“将删除 BGP 会话与 WG 隧道”，附最后一份配置；
   - 非标准 ASN 且非特权 → 额外提示删除后需人工恢复；
   - 生成 32 位随机码，要求原样输入；
   - 注册确认。
5. `remove_peer_confirm`：码不匹配 → 取消；匹配 → `POST /remove`，失败统一报错；成功按 ASN 类型给不同后续提示，并通知所有其他特权用户。

### 7.8 `/restart`（仅私聊）

未登录/无 Peer 提示 → 身份提示 → 离线节点提示 → 选节点（唯一自动）→ 输入 `yes` → `POST /restart` → 成功/失败提示。

### 7.9 `/info`

```python
get_info(message, asn=None, node=None)
```

权限规则：

- 非特权传入 `asn`：
  - 未登录 → 拒绝并给登录按钮；
  - `asn != db[chat_id]` → 拒绝并给“显示我的信息”按钮。
- 未登录且未传 `asn` → 提示登录。
- 未传 `asn` → 取 `db[chat_id]`。
- 特权可通过 `/info <asn>`。

渲染逻辑：

1. `all_peers = get_info(asn)`。
2. 空：
   - 自己 → “尚未 Peer” + `?start=peer` 按钮，并列出因抖动被封的前缀；
   - 特权看别人 → `*[Privilege]* 该用户无 Peer`，同样列抖动前缀。
3. 未指定节点：
   - 仅一个 → 自动；
   - 多个 → 提示选择，附节点按钮。
4. 节点不存在 → 提示重选。
5. 节点返回非 dict → 展示错误原文。
6. 正常渲染：
   - 节点头；
   - 对端信息：ASN、Endpoint、公钥、DN42 地址（ULA/LLA/IPv4 标注）；
   - 本端信息：ASN（`DN42_ASN`）、Endpoint（`{node}.{ENDPOINT}:{port}`）、公钥、地址（仅当对端启用对应族）；
   - WireGuard：最近握手时间（UTC ISO + “多久以前”）、收发字节（自动单位）；
   - Bird：会话描述、每个会话状态与路由数；
   - 抖动前缀警告；
   - Contact，与 whois 名不一致时附注。
7. 按钮：
   - `LG_DOMAIN` 存在时：单会话给一个 LG 按钮；双会话给 IPv4/IPv6 两个（URL 为 `{LG}/detail/{node}/{session_base}_v4|_v6`）；
   - 多节点：每节点一个按钮，当前节点加 ✅；
   - 单节点：Refresh 按钮；
   - 特权且查看他人：追加“切换至该身份”。

回调 `info_{asn}_{node}` 重新渲染并 `edit_message_text`（异常静默）。

### 7.10 工具命令（`all_in_one.py`）

支持命令：

```text
ping ping4 ping6
trace trace4 trace6 traceroute traceroute4 traceroute6 mtr mtr4 mtr6
route route4 route6
tcping tcping4 tcping6
path
```

参数解析：

1. 无参数 → 打印用法：`/{cmd} [ip/domain]{ {port}} {node1} {node2} ...`。
2. `route` / `path` 且目标含 `/` → 拆出 `netlen`（必须为 int，否则忽略）。
3. `test_ip_domain` 失败 → 报“IP 不正确或域名无法解析”。
4. `DN42_ONLY` 且非 DN42 → 报“不属于 DN42”。
5. `4/6` 后缀：强制对应地址族，缺失则报错并结束。
6. 无后缀：优先 IPv4，其次 IPv6。
7. `traceroute` / `mtr` 归一为 `trace`。
8. 节点筛选：从第 3 个参数起转小写；先精确匹配 `SERVERS` 键，再前缀匹配；无匹配则全部节点。

命令构造：

| 命令 | Agent 请求体 | 超时 |
|---|---|---|
| ping | `ip` | 10s |
| tcping | `ip port`（第一个参数若为 1..65535 视为端口，默认 80） | 12s |
| trace | `ip` | 10s |
| route | `ip` 或 `ip/netlen` | 10s |
| path | 同上 | 10s |

发送“Querying”占位消息并持续 `typing`；并发请求后逐节点解析：

- 节点不在在线集合 → “Node is offline.”
- 在线但无结果 → “Something went wrong.”
- `408` → “Request Timeout”
- `path` 的 `404` → “Not found”
- 其他非 200 → 通用错误
- `200` 时：
  - ping：若首行是 `PING ...`，替换为带域名的标题；
  - trace：若首行是 `traceroute to ...`，替换标题；
  - route/path：若首行以 `BIRD ` 开头则去掉；
  - tcping：加“TCPing 地址 端口”标题后拼接输出。

最终把每个节点结果包成：

````text
```{Command}Result-{NODE}
...
```
````

`route` 结果若包含 `BGP.local_pref: 0`，追加“该路由被标记为 blocked，请联系 CONTACT”。

用 `uuid4` 去掉连字符作为 `data_id` 存入缓存；先展示第一个节点结果，并生成节点切换按钮 `generaltest_{data_id}_{node}`。回调时若缓存过期提示重跑，否则换文本与按钮。

### 7.11 `/dig`

- 接受 0..3 个位置参数；解析 `@server` 与“不含点号的类型”。
- 类型白名单：`ANY A AAAA CNAME MX TXT NS SOA SRV PTR`。
- `@server` 必须是合法 IP；`DN42_ONLY` 时必须是 DN42 段。
- 域名做 punycode 转换；`DN42_ONLY` 时必须 `.dn42` 结尾。
- 执行 `dig +noall +answer +comments +multiline {target} {type} {@server}`，8 秒超时。
- 空结果 → “No result.”；超过 4000 字符按 `split_long_msg` 分片并用“To be continued...”串联。

### 7.12 `/whois`

- 只取第 2 个参数；字符白名单：字母数字与 `_-./:`。
- 先查 `whois -h {WHOIS_ADDRESS} {input}`。
- 若结果无效（行数 ≤1、含 `% 404`、或 inetnum/inet6num 段数量不等于 1）：
  - 纯整数按 DN42 规则补全 ASN 后再查；
  - 非整数且 `DN42_ONLY` 关闭时回退 `whois -I {input}`。
- 结果附加：
  - ROA 路由（`% Routes for 'AS{asn}'`，按地址排序）；
  - 统计数据（centrality/closeness/betweenness/peer count）。
- 超长分片规则同 dig。

### 7.13 `/rank`、`/stats`、`/peer_list`、`/flaps`

- `/rank`：默认每页 30 条，4 种指标切换；带 ASN 参数时转调 `/stats`。
  - 按钮：上一页/当前页/下一页 + 指标按钮（✅ 标记当前）；回调 `rank_{page}_{type}`。
- `/stats [asn]`：无参数且私聊已登录时用自己的 ASN；否则要求参数。
  - ASN 兼容简写补全；输出 asn、mnt、四项指标及“更新时间”。
- `/peer_list [asn]`：输出邻居 ASN 与 as-name，末尾 `N peers in total`。
- `/flaps`：仅配置了 `FLAPALERTED_URL` 可用；支持 `Count / RateSec / FirstSeen / ASN` 四种排序，每页 5 条；回调 `flaps_{page}_{type}`。

### 7.14 文案清单（1:1 对齐）

> 本节给出**可直接照抄**的提示文本。约定：
> - `{...}` 为运行时替换，落地时不要保留花括号（若用 `str.format` 需转义）。
> - `\n` 为真实换行；代码块内的缩进、空行、反引号、Emoji 都必须一致。
> - 未标注 `parse_mode` 的调用使用纯文本发送；标注 `Markdown` 的必须保留反引号。
> - 英文在前、中文在后是原实现的统一风格，不要只保留中文。

#### 7.14.1 通用文案

**（1）私聊限制**（`IsPrivateChat`，群聊中触发私聊命令时回复）

```text
This command can only be used in private chat.
此命令只能在私聊中使用。
```

**（2）未登录**（`tools.gen_login_message`，附 `Login now | 立即登录` 按钮，URL 为 `https://t.me/{bot}?start=login`）

```text
You are not logged in yet, please use /login first.
你还没有登录，请先使用 /login
```

**（3）取消当前流程**（所有 `step_manage` 与多轮 `register_next_step_handler`）

```text
Current operation has been cancelled.
当前操作已被取消。
```

**（4）`/cancel` 本身**（`commands/cancel.py`，无正在进行流程时）

```text
No ongoing operations
没有正在进行的操作
```

**（5）流程中无效输入**（区域、节点、枚举选择等）

```text
Invalid input, please try again. Use /cancel to interrupt the operation.
输入不正确，请重试。使用 /cancel 终止操作。
```

**（6）节点离线提示**（`/modify`、`/remove`、`/restart`、`/info` 开头；`{node}` 用反引号包裹）

```text
The following servers are currently offline, please try again later:
以下服务器目前处于离线状态，如有需要请稍后再试：
`{node}`
```

**（7）仅一个可选节点**（自动选择并继续）

```text
Only one available node, automatically select `{node}`
只有一个可选节点，自动选择 `{node}`

If not wanted, use /cancel to interrupt the operation.
如非所需，使用 /cancel 终止操作。
```

**（8）命令内部异常**（中间件 `post_process`，`exception` 非空）

```text
Error encountered! Please contact {CONTACT}
遇到错误！请联系 {CONTACT}
```

**（9）通用执行失败**（各命令的 `except BaseException`）

```text
Error encountered, please try again. If the problem remains, please contact {CONTACT}
遇到错误，请重试。如果问题依旧，请联系 {CONTACT}
```

**（10）附错误信息的失败**（`modify.recreate_peer_info` 取到非 dict 时）

````text
Error encountered! Please contact {CONTACT} the following error message
遇到错误！请附带下述错误信息联系 {CONTACT}

```ErrorMsg
{error}
```
````

#### 7.14.2 `/start`、`/help`、`/chatid`

`/help` 第一条消息由 `WELCOME_TEXT` 与固定后缀拼接：

```text
{WELCOME_TEXT}
The command list is in the next message.
指令列表在下一条消息中。

You can always use /cancel to interrupt current operation.
你始终可以使用 /cancel 终止当前正在进行的操作。

When something unexpected happens or the bot can't meet your needs, please contact {CONTACT}
当出现了什么意料之外的，或者机器人无法满足你的需求，请联系 {CONTACT}
```

第二条为完整指令列表（`parse_mode="Markdown"`，三反引号块）：

````text
Command List 指令列表
```Commands
Tools:
  - /ping [ip/domain]
  - /tcping [ip/domain] {port}
  - /trace [ip/domain]
  - /route [ip/domain]
  - /path [ip/domain]
  - /whois [something]
  - /dig [domain] {type}

User Manage:
  - /login
    Login to verify your ASN
    登录以验证你的 ASN
  - /logout
    Logout current logged ASN
    退出当前登录的 ASN
  - /whoami
    Get current login user
    获取当前登录用户

Peer:
  - /peer
    Set up a peer
    设置一个 Peer
  - /modify
    Modify peer information
    修改 Peer 信息
  - /remove
    Remove a peer
    移除一个 Peer
  - /info
    Show your peer info and status
    查看你的 Peer 信息及状态
  - /restart
    Restart tunnel and Bird session
    重启隧道及 Bird 会话

Statistics:
  - /rank
    Show DN42 global ranking
    显示 DN42 总体排名
  - /stats [asn]
    Show DN42 user basic info & statistics
    显示 DN42 用户基本信息及数据
  - /peer_list [asn]
    Show the peer situation of a user
    显示某 DN42 用户的 Peer 情况
```
````

`/chatid`：

```text
Your chat ID is `{chat_id}`.
你的聊天 ID 是 `{chat_id}`。
You can use this ID to report issues or for other purposes.
你可以使用这个 ID 来报告问题或其他用途。
```

#### 7.14.3 `/login`、`/logout`、`/whoami`

| 场景 | 文案 |
|---|---|
| 已登录再 `/login` | “You are already logged in as `{asn_mnt}`, please use /logout to log out.\n你已经以 `{asn_mnt}` 的身份登录了，请使用 /logout 退出。” |
| 要求输入 ASN | `Enter your ASN\n请输入你的 ASN` |
| ASN 无效（带参数） | `Input is not a registered DN42 ASN, please try again.\n输入不是已注册的 DN42 ASN，请重试。` |
| ASN 无效（多轮） | `Input is not a registered DN42 ASN, please try again. Use /cancel to interrupt the operation.\n输入不是已注册的 DN42 ASN，请重试。使用 /cancel 终止操作。` |
| 选择邮箱 | `Select the email address to receive the verification code. Use /cancel to interrupt the operation.\n选择接收验证码的邮箱。使用 /cancel 终止操作。` |
| 邮箱按钮兜底 | `None of the above 以上都不是` |
| 非登记邮箱 | `Sorry. For now, you can only use the email address you registered in the DN42 Registry to authenticate.\n抱歉。暂时只能使用您在 DN42 Registry 中登记的邮箱完成验证。\nPlease contact {CONTACT} for manual handling.\n请联系 {CONTACT} 人工处理。` |
| 发送中 | `Sending verification code...\n正在发送验证码...\n\nHold on, this may take up to 2 minutes to send successfully.\n稍安勿躁，最多可能需要 2 分钟才能成功发送。` |
| 发送失败 | `Sorry, we are unable to send the verification code to your email address at this time. Please try again later.\n抱歉，暂时无法发送验证码至您的邮箱。请稍后再试。\nPlease contact {CONTACT} if it keeps failing.\n如果一直发送失败请联系 {CONTACT} 处理。` |
| 已发送 | `Verification code has been sent to your email.\n验证码已发送至您的邮箱。\nPlease contact {CONTACT} if you can not receive it.\n如果无法收到请联系 {CONTACT}\n\nEnter your verification code:\n请输入验证码：` |
| 验证成功 | “Welcome! `{asn_mnt}`\n欢迎你！`{asn_mnt}`” |
| 验证失败 | `Verification code error!\n验证码错误！\nYou can use /login to retry.\n你可以使用 /login 重试。` |
| 特权码成功 | “*[Privilege]*\nWelcome! `{asn_mnt}`\n欢迎你！`{asn_mnt}`” |
| `/logout` | “You have logged out as `{asn_mnt}`.\n你已经退出 `{asn_mnt}` 身份。”（特权用户前缀 `*[Privilege]*\n`） |
| `/whoami` | “Current login user:\n当前登录用户：\n`{asn_mnt}`”（特权用户前缀 `*[Privilege]*\n`） |
| 越权切换 | `You are not allowed to switch to other's ASN directly.\n你无权直接切换至他人的 ASN。` |

#### 7.14.4 `/peer`

**（1）身份确认（`peer.init`）**

```text
You will create a peer with me through the following identity:
你将通过以下身份创建一个与我的 Peer：
`{asn_mnt}`

If it is wrong, please use /cancel to interrupt the operation.
如果有误请输入 /cancel 终止操作。

Any problems with the creation process, please contact {CONTACT}
创建过程中产生任何问题，请联系 {CONTACT}
```

非标准 ASN（非 `424242xxxx` 且非特权）：

```text
Your ASN is not in standard DN42 format (`AS424242xxxx`), so it cannot be auto-peered, please contact {CONTACT} for manual peer.
你的 ASN 不是标准 DN42 格式 (`AS424242xxxx`)，因此无法进行 AutoPeer，请联系 {CONTACT} 进行人工 Peer。
```

已与全部节点建连：

```text
You already peer with all my nodes.
你已经和我的所有节点 Peer 了。

Use /info for more information.
使用 /info 查看更多信息。
```

**（2）节点列表（`pre_region`）**

标题固定为 `Node List 节点列表`，每个节点一行 ``- `{display_name}` ``，随后按情况拼接：

```text
  Server offline, please try again later.
  服务器离线，请稍后重试。

  Server error, please try again later.
  服务器错误，请稍后重试。

  ℹ️ Current Node
  ℹ️ Already Peered
  ✔️ Open For Peer
  ❌ Not Open For Peer
  ✔️ Capacity: {existed} / Unlimited
  ✔️ Capacity: {existed} / {max}
  ❌ Capacity: {existed} / {max}
  ✔️ No minimum number of peers requirement
  ✔️ You have {existed_peers} peers (minimum required: {requirement})
  ❌ You have {existed_peers} peers (minimum required: {requirement})
  ⚠️ IPv4: Behind NAT
  ✔️ IPv4: Yes
  ⚠️ IPv4: No
  ✔️ IPv6: Yes
  ⚠️ IPv6: No
  ⚠️ Not allowed to peer with Chinese Mainland
  {data["msg"]}
```

> 注意：每个节点块之间有一个空行；`msg.strip()` 后整体发送，`parse_mode="Markdown"`。

特权绕过提示：

```text
*[Privilege]*
Some nodes do not meet the requirements, using privilege to continue. Use /cancel to exit if not wanted.
部分节点不符合要求，使用特权继续。如不应继续请使用 /cancel 退出。
```

全部不满足且非特权：

```text
Some nodes do not meet peer requirements. If you really need a peer, please contact {CONTACT}
部分节点不符合 Peer 要求。如您确实需要 Peer，请联系 {CONTACT}
```

无可用节点：

```text
No node is available for peering at the moment.
目前没有节点可供 Peer。
```

选择节点：`Which node do you want to choose?\n你想选择哪个节点？`

**（3）会话类型与 BGP 能力**

| 步骤 | 文案 | 键盘 |
|---|---|---|
| `pre_session_type` | `What routes do you want to transmit with me?\n你想和我传递哪些路由？` | `IPv6 & IPv4` / `IPv6 only` / `IPv4 only`（每行 3 个） |
| `pre_mpbgp_support` | `Do you support Multi-Protocol BGP?\n你支持多协议 BGP 吗？` | `Yes` / `No` |
| `pre_mpbgp_type` | `What address do you want to use to establish an MP-BGP session with me?\n你想使用什么地址与我建立多协议 BGP 会话？` | `IPv6` / `IPv4` |
| `pre_enh` | `Do you support Extended Next Hop?\n你支持扩展的下一跳吗？` | `Yes` / `No` |

**（4）地址采集**

`pre_ipv6`（`parse_mode="Markdown"`）：

```text
Input your DN42 IPv6 address.
请输入你的 DN42 IPv6 地址。

Both Link-Local and ULA address are support. Link-Local is preferred for Bird users while ULA is preferred for other BGP clients.
Link-Local 和 ULA 地址均支持。Bird 用户首选 Link-Local，其他 BGP 客户端首选 ULA。
```

> 键盘快捷值：当前 `IPv6`；若 ASN 在 `4242420000..4242429999`，额外提供 `fe80::{ASN % 10000}`。

`post_ipv6` 校验失败：

```text
Invalid DN42 IPv6 address, please try again. Use /cancel to interrupt the operation.
输入不是有效的 DN42 IPv6 地址，请重试。使用 /cancel 终止操作。
```

`pre_request_linklocal`（检测到 LLA 时）：

```text
Link-Local address detected. You can enter the address required on my side as needed.
检测到 Link-Local 地址。你可以按需输入所需的我这边的地址。

Make modifications only if you know exactly what it is and are convinced it's needed, otherwise please directly select the option below.
仅在你明确知道这是什么并且确信有必要时再做出修改，否则请直接选择下方的选项。
```

`post_request_linklocal` 失败：

```text
Invalid DN42 IPv6 Link-Local address, please try again. Use /cancel to interrupt the operation.
输入不是有效的 DN42 IPv6 Link-Local 地址，请重试。使用 /cancel 终止操作。

Make modifications only if you know exactly what it is and are convinced it's needed, otherwise please directly select the option below.
仅在你明确知道这是什么并且确信有必要时再做出修改，否则请直接选择下方的选项。
```

`pre_ipv4`：`Input your DN42 IPv4 address.\n请输入你的 DN42 IPv4 地址。`

`post_ipv4` 失败：

```text
Invalid DN42 IPv4 address, please try again. Use /cancel to interrupt the operation.
输入不是有效的 DN42 IPv4 地址，请重试。使用 /cancel 终止操作。
```

**（5）公网地址（`pre_clearnet`）**

固定头：

```text
Input your clearnet address for WireGuard tunnel.
请输入你用于 WireGuard 隧道的公网地址。
```

能力描述（二者取一）：

```text
You can use IPv4 or IPv6 to establish a tunnel with me.
你可以使用 IPv4 或者 IPv6 与我建立隧道。
```
```text
You can only use IPv4 to establish a tunnel with me.
你只能使用 IPv4 与我建立隧道。
```
```text
You can only use IPv6 to establish a tunnel with me.
你只能使用 IPv6 与我建立隧道。
```

NAT 追加（直接拼在上句后，无空格）：

```text
 Since my IPv4 is behind NAT, you are required to provide a clearnet address.
由于我的 IPv4 位于 NAT 之后，所以需要你提供公网地址。
```

`none` 提示三选一（前置两个换行）：

```text
If you don't have a clearnet address or is behind NAT, please enter `none`
如果你没有公网地址，或你的服务器在 NAT 网络中，请输入 `none`
```
```text
*[Privilege]*
If your peer don't have a clearnet address or is behind NAT, please enter `none`
如果对方没有公网地址，或对方的服务器在 NAT 网络中，请输入 `none`
```
```text
If you don't have a clearnet address or is behind NAT, please contact {CONTACT}
如果你没有公网地址，或你的服务器在 NAT 网络中，请联系 {CONTACT}
```

端口自动分离提示（`parse_mode="Markdown"`）：

```text
Port number `{port}` detected, automatically separated.
识别到端口号 `{port}`，已自动分离。

If this is not the correct port number, please try to restart the process, do not include the port number here, and contact {CONTACT} to help improving the recognition accuracy.
识别可能有误。如果这不是正确的端口号，请尝试重新开始流程，在此处输入时不要包含端口号，并联系 {CONTACT} 以帮助提升识别准确性。
```

`post_clearnet` 校验失败（非特权）：

```text
{reason}, please try again.
{reason_zh}，请重试。

The check procedure may sometimes be wrong, if it is confirmed to be valid, just resubmit. If the error keeps occurring please contact {CONTACT}
判定程序可能出错。如果确认有效，重新提交即可。重复出错请联系 {CONTACT}

Use /cancel to interrupt the operation.
使用 /cancel 终止操作。
```

其中 `reason` 取值：

```text
IPv4 is not supported on this node / 该节点不支持IPv4
IPv6 is not supported on this node / 该节点不支持IPv6
Peering with Chinese Mainland is not allowed on this node / 该节点不允许与中国大陆 Peer
Invalid or unreachable clearnet address / 输入不是有效的公网地址或该地址不可达
```

中国大陆拦截额外追加（注意原文末尾自带两个换行）：

```text
Please note that do NOT try to bypass this restriction. Even if you successfully make the bot record your address for now, your data will be dropped by the firewall.
请注意，不要尝试绕过该限制。即使你现在成功让 Bot 记录了你的地址，与你的数据也会被防火墙丢弃。
```

特权放行：

```text
*[Privilege]*
{reason}.
{reason_zh}。

Use the privilege to continue the process. Use /cancel to exit if there is a mistake.
使用特权，流程继续。如确认有误请使用 /cancel 退出。
```

**（6）端口、公钥、联系方式**

| 步骤 | 文案 |
|---|---|
| `pre_clearnet_port` | `Input your port for WireGuard tunnel.\n请输入你用于 WireGuard 隧道的端口。` |
| `post_clearnet_port` 失败 | `Invalid port, please try again. Use /cancel to interrupt the operation.\n输入不是有效的端口，请重试。使用 /cancel 终止操作。` |
| `pre_port_myside`（特权） | `*[Privilege]*\nEnter the port number provided to your peer\n请输入给对方提供的端口号` |
| `pre_pubkey` | `Input your WireGuard public key\n请输入你的 WireGuard 公钥` |
| `post_pubkey` 失败 | `Invalid public key, please try again. Use /cancel to interrupt the operation.\n输入不是有效的公钥，请重试。使用 /cancel 终止操作。` |
| `pre_contact` | `Input your contact information (Telegram or Email)\n请输入你的联系方式（Telegram 或 Email）` |

`post_contact` 白名单失败（`parse_mode="Markdown"`）：

```text
Only non-empty strings which contain only upper and lower case letters, numbers, spaces and the following special symbols are accepted.
只接受仅由大小写英文字母、数字、空格及以下特殊符号组成的非空字符串。

`!#$%&()*+,-./:;<=>?@[]^_{|}~`

Please try again. Use /cancel to interrupt the operation.
请重试。使用 /cancel 终止操作。
```

**（7）确认与结果**

`/peer` 确认（`parse_mode="Markdown"`）：

````text
Please check all your information
请确认你的信息

```PeerInfo
Region:
    {display_name}
Basic:
    ASN:         {asn}
    Channel:     {channel}
    MP-BGP:      {mpbgp}
    IPv6:        {ipv6}
    IPv4:        {ipv4}
    Request-LLA: {request_lla}
Tunnel:
    Endpoint:    {clearnet}
    PublicKey:   {pubkey}
Contact:
    {contact}
```
Please enter `yes` to confirm. All other inputs indicate the cancellation of the operation.
确认无误请输入 `yes`，所有其他输入表示取消操作。
````

成功后：

```text
Peer has been created
Peer 已建立
```

按钮：`Show info | 查看信息` → `https://t.me/{bot}?start=info_{asn}_{region}`。

特权广播（`parse_mode="Markdown"`，发给除操作者外的所有特权用户）：

````text
*[Privilege]*
New Peer!   新 Peer！
```PrivilegeNote
{info_text}
```
````

若接收者当前身份正是该 ASN，消息末尾追加 `Already as this user 已在该身份`，且按钮只有 `Show info | 查看信息`；否则追加 `Switch to it | 切换至该身份`（`start=whoami_{asn}_{region}`）与 `Show info | 查看信息` 两个按钮。

修改成功时对应文案为 `Peer information has been modified\nPeer 信息已修改`，广播首行为 `Peer Modified!   Peer 信息修改！`。

#### 7.14.5 `/modify`

**（1）身份与节点**

```text
You will modify a peer with me through the following identity:
你将通过以下身份修改一个与我的 Peer：
`{asn_mnt}`

If it is wrong, please use /cancel to interrupt the operation.
如果有误请输入 /cancel 终止操作。

Any problems with the modification process, please contact {CONTACT}
修改过程中产生任何问题，请联系 {CONTACT}
```

选择节点：`Which node's peer information do you want to change?\n你想要修改哪个节点的 Peer 信息？`

**（2）当前信息**

````text
Current information is as follows
当前信息如下
```CurrentInfo
{diff_text}```
````

`diff_text` 的格式由 `get_diff_text` 生成：

```text
Region:
    {display_name}
Basic:
    ASN:         {asn}
    Channel:     {channel}
    MP-BGP:      {mpbgp}
    IPv6:        {ipv6}
    IPv4:        {ipv4}
    Request-LLA: {request_lla}
Tunnel:
    Endpoint:    {clearnet}
    PublicKey:   {pubkey}
Contact:
    {contact}
```

字段发生变化时：

```text
    {prefix}{old_value}
         ->
           {new_value}
```

Region 变化时为：

```text
    {old_display}
  ->
    {new_display}
```

**（3）操作菜单**

首次进入：

```text
Select the item to be modified:
选择想要修改的内容：

- `Region`
  Migration to another node
  迁移到另一节点
- `Session Type`
  Change BGP session type (MP-BGP, ENH)
  修改 BGP 会话类型 (多协议 BGP、扩展的下一跳)
- `DN42 IP`
  Change DN42 IP (Include IPv6 & IPv4)
  修改 DN42 IP 地址 (含 IPv6 及 IPv4)
- `Clearnet Endpoint`
  Change clearnet endpoint and port of WireGuard tunnel
  修改用于 WireGuard 隧道的公网地址及端口
- `WireGuard PublicKey`
  Change public key of WireGuard tunnel
  修改 WireGuard 公钥
- `Contact`
  Change contact
  修改联系方式

- `Finish modification`
  Finish modification and submit
  完成修改并提交
- `Abort modification`
  Abort modification (equivalent to /cancel)
  放弃修改 (相当于 /cancel)
```

键盘（每行两个）：

```text
Region | Clearnet Endpoint
Session Type | WireGuard PublicKey
DN42 IP | Contact
Finish modification | Abort modification
```

修改后回到菜单：

````text
You have modified the following information
已修改以下信息

```ModifiedInfo
{diff_text}```
You can continue to modify, or choose to `Finish modification` or `Abort modification`.
你可以继续修改，或者选择 `Finish modification` 以提交，或者选择 `Abort modification` 放弃修改。
````

放弃：`Abort modification, operation has been canceled.\n放弃修改，操作已取消。`

无变更：`No changes detected, operation cancelled.\n未检测到任何变更，操作已取消。`

**（4）确认**

````text
Please check all your information
请确认你的信息

```ComfirmInfo
{diff_text}```
Please enter `yes` to confirm. All other inputs indicate the cancellation of the operation.
确认无误请输入 `yes`，所有其他输入表示取消操作。
````

> `ComfirmInfo` 是原仓库拼写（少一个 `r`），为保持兼容**不要改成** `ConfirmInfo`。

#### 7.14.6 `/remove`

身份提示：

```text
You will remove a peer with me through the following identity:
你将通过以下身份删除一个与我的 Peer：
`{asn_mnt}`

If it is wrong, please use /cancel to interrupt the operation.
如果有误请输入 /cancel 终止操作。

Any problems with the removal process, please contact {CONTACT}
删除过程中产生任何问题，请联系 {CONTACT}
```

选择节点：`Which node do you want to delete the information with?\n你想要删除与哪个节点的信息？`

未建连：

```text
You are not peer with me yet, you can use /peer to start.
你还没有与我 Peer，可以使用 /peer 开始。
```

待删除信息（`parse_mode="Markdown"`）：

````text
Peer information with `{display_name}` will be deleted (including BGP Sessions and WireGuard tunnels), and you can always re-create it using /peer.
将要删除与 `{display_name}` 的 Peer 信息（包括 BGP Session 和 WireGuard 隧道），你可以随时使用 /peer 重新建立。
```LastInfo
{diff_text}```
If you want to modify Peer information, you can use the /modify command instead of deleting and recreating.
如果你想要修改 Peer 信息，可以使用 /modify 命令，而无需删除再重建。
````

非标准 ASN 追加：

```text
Attention 注意

Your ASN is not in standard DN42 format (`AS424242xxxx`), so it cannot be auto-peered
你的 ASN 不是标准 DN42 格式 (`AS424242xxxx`)，因此无法进行 AutoPeer
After deleting peer information, you need to contact {CONTACT} for manual operation if you need to re-peer.
删除 Peer 信息后，如需重新 Peer，需要联系 {CONTACT} 进行人工操作。
```

确认码（32 位）：

```text
Enter the following random code to confirm the deletion.
输入以下随机码以确认删除。

`{code}`

All other inputs indicate the cancellation of the operation.
所有其他输入表示取消操作。
```

成功（标准 ASN）：

```text
Peer information has been deleted.
Peer 信息已删除。

You can always re-create it using /peer.
你可以随时使用 /peer 重新建立。
```

成功（非标准 ASN）：

```text
Peer information has been deleted.
Peer 信息已删除。

Contact {CONTACT} if you need to re-peer.
如需重新 Peer 请联系 {CONTACT}
```

特权广播：

````text
*[Privilege]*
Peer Removed!   有 Peer 被删除！
```PrivilegeNote
{last_info}
```
````

#### 7.14.7 `/restart`

身份提示：

```text
You will restart a peer with me through the following identity:
你将通过以下身份重启一个与我的 Peer：
`{asn_mnt}`

If it is wrong, please use /cancel to interrupt the operation.
如果有误请输入 /cancel 终止操作。

Any problems with the restarting process, please contact {CONTACT}
删除过程中产生任何问题，请联系 {CONTACT}
```

> 末句中文“删除过程中”是原仓库的复制粘贴错误。若要 1:1 复刻请保留；若要修正，请同步更新验收用例。

选择节点：`Which node do you want to restart the tunnel and Bird session with?\n你想要重启与哪个节点的隧道及 Bird 会话？`

确认：

```text
The tunnel and Bird sessions with the following nodes will be restarted soon.
即将重启与以下节点的隧道及 Bird 会话。

`{display_name}`

Please enter `yes` to confirm. All other inputs indicate the cancellation of the operation.
确认无误请输入 `yes`，所有其他输入表示取消操作。
```

成功：

```text
The tunnel and Bird sessions have been restarted.
隧道及 Bird 会话已重启。
```

#### 7.14.8 `/info`

权限与状态文案：

| 场景 | 文案 | 按钮 |
|---|---|---|
| 非特权查他人且未登录 | `You are not allowed to view information of other ASN.\n你无权查看其他 ASN 的信息。` | `Login now \| 立即登录` |
| 非特权查他人且已登录 | 同上 | `Show my info \| 显示我的信息`（`info_{self_asn}_`） |
| 未登录 | `You are not logged in yet, please use /login first.\n你还没有登录，请先使用 /login` | `Login now \| 立即登录` |
| 无 Peer（本人） | `You are not peer with me yet, you can use /peer to start.\n你还没有与我 Peer，可以使用 /peer 开始。` | `Peer now \| 立即 Peer` |
| 无 Peer（特权查他人） | `*[Privilege]*\nThis user has no peer at the moment, may have been deleted already.\n该用户目前无 Peer，可能已经被对方删除` | 无 |
| 多节点未指定 | `Select an available node from the list below to get information\n从下方列表中选择一个可用节点以获取信息` | 节点按钮 |
| 节点不存在 | `Node does not exist, please select another available node\n节点不存在，请选择其他可用节点` | 节点按钮 |

抖动前缀追加（无 Peer 场景）：

```text
\n\nHowever, the following prefix(es) of your ASN have been blocked due to recent flaps:
然而，你的 ASN 的以下前缀由于近期抖动已经被封锁：
`{prefix}`
```

特权查他人场景为：

```text
\n\nThe following prefix(es) of this ASN have been blocked due to recent flaps:
该 ASN 的以下前缀由于近期抖动已经被封锁：
`{prefix}`
```

节点数据异常：

```text
{display_name}:
Error occurred. Please contact {CONTACT} with following message.
遇到错误。请联系 {CONTACT} 并附带下述结果。
`{raw}`
```

正常信息块（`parse_mode="Markdown"`，整体包在 ```` ```Info ... ``` ```` 中）：

```text
Node:
    {display_name}
Information on your side:
    ASN:
        AS{asn}
    Endpoint:
        {clearnet}
    WireGuard Public Key:
        {pubkey}
    DN42 Address:
        IPv6 ULA: {v6}/128        （或 IPv6 Link-Local: {v6}/64）
        IPv4: {v4}/32
Information on my side:
    ASN:
        AS{DN42_ASN}
    Endpoint:
        {node}.{ENDPOINT}:{port}
    WireGuard Public Key:
        {my_pubkey}
    DN42 Address:
        {my_v6}/128 或 /64
        IPv4: {my_v4}/32
WireGuard Status:
    Latest handshake:
        {iso8601 Z}
        {N days, N hours ago}
    Transfer:
        {recv} received, {sent} sent
Bird Status:
    {session}
    {bird_state}
    {bird_detail}
    IPv4:
        {v4_state}
    IPv6:
        {v6_state}
Contact:
    {contact}
    ({whois_mnt})
```

细节：

- 无握手时 `Latest handshake:` 下一行是 `Never`，且不显示相对时间。
- 单会话时 BIRD 只显示一个状态；双会话时分别显示 `IPv4:` / `IPv6:`。
- 抖动拦截追加：

```text
[!] The following prefix(es) have been blocked
    due to recent flaps:
    - {prefix}
```

- `Contact` 与 whois 名称不一致时，追加一行 `    ({whois_mnt})`。
- `convert_size` 规则：`0 → 0B`，其余 `{round(x/1024^i,2)} {B|KB|MB|GB|TB|PB|EB|ZB|YB}`（数字与单位间有空格）。
- `td_format` 只输出英文，单位 `day/hour/minute/second`，大于 1 加 `s`，末尾 ` ago`；`<=0` 输出 `now`。

#### 7.14.9 工具命令

**通用查询头**（`all_in_one`，`parse_mode="Markdown"`）：

````text
```Querying
{CommandText} {address}{addon}...
```
````

其中 `CommandText ∈ {Ping, TCPing, Traceroute, Route to, AS-Path of}`；`address` 为 `domain (ip)` 或 `ip`；`addon` 为 ` Port {port}`（仅 tcping）。

**用法提示**：

```text
Usage: /{cmd} [ip/domain]{addon} {node1} {node2} ...
用法：/{cmd} [ip/domain]{addon} {node1} {node2} ...
```

> `cmd` 为 `ping{4|6}` 这类占位写法，原样输出花括号。

**错误提示**（`gen_peer_me_markup` 附带 `Peer with me | 与我 Peer` 按钮）：

```text
IP is incorrect or domain can't be resolved
IP 不正确或域名无法被解析
```
```text
IP/Domain not in DN42
IP/域名不属于 DN42
```
```text
Not IPv4 address or domain can't resolve IPv4 record
不是 IPv4 地址或域名无法解析出 IPv4 记录
```
```text
Not IPv6 address or domain can't resolve IPv6 record
不是 IPv6 地址或域名无法解析出 IPv6 记录
```

**节点级结果**：

```text
Node is offline.
节点离线。
```
```text
Request Timeout 请求超时
```
```text
Not found 未找到
```
```text
Something went wrong.
发生了一些错误。
```

结果块标签：```` ```{CommandText}Result-{NODE} ````，其中 `CommandText` 去掉连字符（`Traceroute`、`TCPing`、`Ping`、`Route`、`ASPath`）。

`route` 命中 `BGP.local_pref: 0` 时追加：

```text
Note: The route has local preference 0, which indicates it has been blocked. Contact {CONTACT} for more information.
```

结果过期：`The result is expired, please run it again.\n结果已失效，请重新运行。`

**`/dig`**：

用法（`parse_mode="Markdown"`）：

```text
Usage: /dig [domain] {type} {@dns\_server}
用法：/dig [domain] {type} {@dns\_server}

Only accept following types
只接受以下类型的查询
`ANY`, `A`, `AAAA`, `CNAME`, `MX`, `TXT`, `NS`, `SOA`, `SRV`, `PTR`
```

错误：

```text
Invalid DNS server.
无效的 DNS 服务器。
```
```text
Only accept DN42 DNS server.
只接受 DN42 DNS 服务器。
```
```text
Invalid domain.
无效的域名。
```
```text
Only accept `.dn42` domain.
只接受 `.dn42` 域名。
```

执行结果：

```text
Request timeout.
请求超时。
```
```text
Something went wrong.
发生了一些错误。
```
```text
No result.
没有结果。
```

结果块 ```` ```DigResult\n{content}``` ````，分片时非末片追加 `To be continued...`。

**`/whois`**：

```text
Usage: /whois [something]
用法：/whois [something]
```
```text
Invalid input.
输入无效

Only non-empty strings which contain only upper and lower case letters, numbers, spaces and the following special symbols are accepted.
只接受仅由大小写英文字母、数字、空格及以下特殊符号组成的非空字符串。
`_-./:`
```
```text
Request timeout.
请求超时。
```
```text
Something went wrong.
发生了一些错误。
```

附加段：

```text
% Routes for 'AS{asn}':
route4:             {prefix}
route6:             {prefix}
```

```text
% Statistics for 'AS{asn}':
centrality:         {value}
closeness:          {value}
betweenness:        {value}
peer count:         {peer}
```

结果块 ```` ```WhoisResult\n{content}``` ````，分片同上。

#### 7.14.10 统计命令

**`/rank`**（每页 30 条）：

````text
```Rank
                      DN42 Global Rank
                        Centrality

Rank  ASN         MNT                   Value
   1  4242420001  EXAMPLE-MNT           0.12345
```
Updated {N}s ago
({YYYY-MM-DD HH:MM:SS UTC})
````

- 列宽：`Rank` 右宽 4，`ASN` 左宽 10，`MNT` 左宽 20（超长截断为前 17 字符 + `...`），浮点值保留 `5 - len(str(int(value)))` 位小数。
- 指标显示名：`Centrality`、`Peer count`、`Closeness`、`Betweenness`。
- 按钮：`⬅️` / 当前页数字 / `➡️`，第二行起为指标按钮，当前项前缀 `✅ `，无意义占位按钮 text 与 callback 均为单个空格。

**`/stats`**：

```text
Usage: /stats [asn]
用法：/stats [asn]
```

````text
```Statistics
asn          {asn}
mnt          {mnt}
centrality   {value}  #{rank}
closeness    {value}  #{rank}
betweenness  {value}  #{rank}
peer count   {value}  #{rank}
```
Updated {N}s ago
({YYYY-MM-DD HH:MM:SS UTC})
````

无数据：```` ```Statistics\nNo data available.\n暂无数据。```{update_str} ````。

**`/peer_list`**：

```text
Usage: /peer_list [asn]
用法：/peer_list [asn]
```

````text
```PeerList
No data available.
暂无数据。```
Updated {N}s ago
({...})
````

````text
```PeerList
{peer_asn:<10}  {as_name}
```
`{count}` peers in total
Updated {N}s ago
({...})
````

分片时非末片追加 `To be continued...`，页尾统计只出现在最后一片。

**`/flaps`**：

未配置：`Flapalerted integration is not configured.\n未配置 Flapalerted 集成。`

````text
```Flaps
- ASN:       {asn}
  MNT:       {mnt}
  Prefix:    {prefix}
  Count:     {count}
  RateSec:   {rate}
  FirstSeen: {YYYY-MM-DD HH:MM:SS UTC}
```
Updated {N}s ago
({YYYY-MM-DD HH:MM:SS UTC})
````

无数据：```` ```Flaps\nNo recent flaps.\n```Updated {N}s ago\n({...}) ````。

分页 5 条/页，排序类型显示名：`Count`、`RateSec`、`FirstSeen`、`ASN`，当前项前缀 `✅ `。

### 7.15 回调与深链参数总表

#### 7.15.1 Inline 回调

| 前缀 | 格式 | 解析方式 | 参数取值 | 行为 |
|---|---|---|---|---|
| `info_` | `info_{asn}_{node}` | `split("_", 2)` | `asn` 为十进制整数；`node` 可为空串 | 重新渲染 `/info`，`edit_message_text` |
| `generaltest_` | `generaltest_{data_id}_{node}` | `split("_", 2)` | `data_id` 为 32 位无连字符 UUID hex | 从缓存取结果并切换节点 |
| `rank_` | `rank_{page}_{type}` | `split("_", 2)` | `page` 从 0 开始；`type ∈ centrality/peer/closeness/betweenness` | 翻页/换指标 |
| `flaps_` | `flaps_{page}_{type}` | `split("_", 2)` | `type ∈ Count/RateSec/FirstSeen/ASN` | 翻页/换排序 |
| 空格 | `" "` | — | 占位按钮 | 无操作（仍会触发回调，需容错） |

要点：

- 所有回调都应 `try/except` 包裹 `edit_message_text`，忽略“message is not modified”等错误。
- `info_` 的 `asn` 在非特权场景仍需二次鉴权（见 §7.14.8），不能只依赖按钮不可见。
- `generaltest_` 的 `data_id` 不在缓存中时，原实现因 `cache.get` 不抛异常而实际走到 `data[node]` 的 `TypeError`，被 `except` 吞掉；复刻时建议显式判空并提示过期。

#### 7.15.2 深链（`/start` 参数）

| 深链 | 格式 | 解析 | 说明 |
|---|---|---|---|
| 登录 | `start=login` | 精确匹配 | 等价 `/login` |
| 建 Peer | `start=peer` | 精确匹配 | 等价 `/peer` |
| 我的信息 | `start=info` | 精确匹配 | 等价 `/info`（忽略参数） |
| 指定信息 | `start=info_{asn}_{node}` | `split("_", 3)` | `node` 可为空；`asn` 必须是整数，否则 `int()` 抛错 → 回落到欢迎页 |
| 切换身份 | `start=whoami_{asn}_{node}` | `command[7:].split("_")` | 仅特权生效；`node` 用于生成“查看信息”按钮 |
| 其他/空 | 任意 | `IndexError`/`ValueError` | 发送 `/help` 欢迎消息 |

**URL 按钮**：

| 按钮 | URL |
|---|---|
| `Login now \| 立即登录` | `https://t.me/{bot}?start=login` |
| `Peer now \| 立即 Peer` | `https://t.me/{bot}?start=peer` |
| `Peer with me \| 与我 Peer` | `https://t.me/{bot}` |
| `Show info \| 查看信息` | `https://t.me/{bot}?start=info_{asn}_{node}` |
| `Switch to it \| 切换至该身份` | `https://t.me/{bot}?start=whoami_{asn}_{node}` |
| `Looking Glass` | `{LG_DOMAIN}/detail/{node}/{session_name}` |
| `Looking Glass (IPv4)` | `{LG_DOMAIN}/detail/{node}/{session_name}_v4` |
| `Looking Glass (IPv6)` | `{LG_DOMAIN}/detail/{node}/{session_name}_v6` |

**LG 链接生成规则**（`gen_info_markup`）：

- `session_name` 长度为 2（双栈双会话）时，取第一个名字去掉最后一个下划线段作为前缀，分别拼 `_v4`、`_v6`。
- 长度为 1 时只生成一个 `Looking Glass` 按钮。
- `LG_DOMAIN` 为空则不生成任何 LG 按钮。

**节点切换按钮**：

- 可用节点数 > 1：每个节点一行，当前节点前缀 `✅ `。
- 可用节点数 = 1：改为 `Refresh | 刷新`，callback 仍为 `info_{asn}_{node}`。
- 特权用户查看他人信息时，额外追加一行 `Switch to it | 切换至该身份`（若 `node` 为空则用空串）。

### 7.16 实现陷阱（⚠️ 汇总）

下列条目均来自基线版本的真实行为。复刻时**至少要知道它们存在**：标 `保留` 的表示为了行为一致应照做，标 `修正` 的表示建议在复刻版中改掉并同步验收用例。

#### 7.16.1 状态机与多轮对话

| # | 现象 | 原因 | 建议 |
|---|---|---|---|
| 1 | 用户发送图片/贴纸后流程“卡死” | 中间件 `pre_process` 对 `message.text is None` 直接 `CancelUpdate()`，该更新被丢弃，`register_next_step_handler` 不会触发 | 保留；或在流程内提示“请发送文本” |
| 2 | 重启后旧流程仍可继续，但提示消息 ID 失效 | `enable_save_next_step_handlers(delay=2, filename="./step.save")` 会把 `partial` 与消息对象 pickle 到磁盘，`load_next_step_handlers` 在启动时恢复 | 保留；升级/迁移前先清理 `step.save`，避免旧代码结构反序列化失败 |
| 3 | `peer.step_manage` 只解包 3 元组，返回 4 元组会 `ValueError` | `peer.py` 与 `modify.py` 各有一套 `step_manage`，只有 `modify` 支持 `(next, info, msg, stop_sign)` | 保留两套；新增步骤时严禁跨文件复用 |
| 4 | `stop_sign` 使用字符串时按“子串”匹配 | `str` 也是 `Iterable`，`modify.step_manage` 先判断 `not isinstance(stop_sign, Iterable)`，对字符串永远走 `next_step in stop_sign` 分支 | 现存取值恰好互为子串，未出错；修正方案：显式写 `isinstance(stop_sign, str)` 优先判等 |
| 5 | 修改流程第二次确认时 `KeyError: 'backup'` | `modify.pre_confirm` 用 `peer_info.pop("backup")` 取旧值，重复进入确认步骤时键已不存在 | 修正：改为读取后删除，或在 `post_confirm` 前重新快照 |
| 6 | 确认步骤重试时 `KeyError: 'ProgressType'` | `post_confirm` 一开始 `pop` 掉 `ProgressType`、`InfoText`、`OldRegion`，若用户重复发送 `yes` 且 handler 仍被注册，会二次执行 | 修正：确认成功后立刻注销 handler，或改为 `get` |
| 7 | `pre_*` 步骤递归调用导致深栈 | `step_manage` 对 `pre_` 直接同步递归，`/peer` 最长链路约 10 层，尚安全；若新增大量“自动跳过”步骤需注意 `RecursionError` | 保留；新增步骤改为循环驱动 |

#### 7.16.2 数据判定与外部依赖

| # | 现象 | 原因 | 建议 |
|---|---|---|---|
| 8 | Agent 宕机时被判定为“未建 Peer”，用户可重复建 Peer | `tools.get_info` 只收录 `status == 200` 的结果，404/408/500 全部丢弃 | **修正（高优先级）**：返回值区分“无此 Peer（404）”与“节点不可用（408/500）”，`/peer`、`/info`、`/remove` 分别处理 |
| 9 | whois 超时/不可用时任意 ASN 都能通过校验 | `extract_asn` 的 `except BaseException: return original_asn` 会“放行” | **修正**：whois 异常应返回 `None`（fail-closed），并提示稍后重试 |
| 10 | whois 结果含 `% Information related to 'aut-num/AS...` 才认为已注册；前缀匹配可能误判 | 使用子串匹配而非严格解析 | 保留现状；如需加固，按 `aut-num:` 行精确匹配 |
| 11 | ASN 简写补全规则不一致 | `extract_asn`：`<10000 → +4242420000`，`20000..29999 → +4242400000`；`whois` 命令里另写了一套（`AS42424{20000+x}`） | 保留两处；重构时统一到单一函数并加单元测试 |
| 12 | `get_whoisinfo_by_asn` 对 4201270000..4201279999 取 `admin-c`，其余取 `mnt-by` | 原实现的“特殊段”约定 | 保留；剥离 `MNT-`/`AS-`/`DN42-` 前后缀的循环会把 `DN42-XXX-MNT` 处理成 `XXX` 之类的意外值，测试时需覆盖 |
| 13 | 公网地址校验“有时误判” | `basic_ip_domain_test` 使用 5 个 DNS（含 `127.0.0.1`），`timeout=0.5`、`lifetime=3`，任一解析失败即判无效；且 `clearnet` 需要 A/AAAA 与 PTR 同时可用 | 保留提示“判定程序可能出错”；修正方案：失败重试、区分“解析失败”与“地址不可达” |
| 14 | `get_map()` 无数据时 `/peer` 的 `existed_peers` 计算抛 `TypeError` | `next(i[3] for i in tools.get_map()[1]["peer"] ...)` 只捕获 `StopIteration`，`get_map()[1]` 为 `None` 时直接异常 | 修正：先判空，失败按 `0` 处理 |
| 15 | 地图/Flap 数据长期不更新但命令仍显示旧时间 | 定时任务异常只打印堆栈，不改变缓存 | 保留“Updated Ns ago”；运维需监控该值（见 §15） |

#### 7.16.3 消息渲染与分片

| # | 现象 | 原因 | 建议 |
|---|---|---|---|
| 16 | 超长单行内容导致发送失败或 `TypeError` | `split_long_msg` 找不到换行时返回 `None`；`dig`、`whois`、`peer_list` 直接 `for m in None` | **修正**：返回 `[msg]` 或按字符硬切；调用方判空 |
| 17 | `edit_message_text` 偶发报错 | 内容未变化、消息过旧、Markdown 实体非法都会抛异常 | 保留静默策略；建议仅忽略 `message is not modified`，其余记日志 |
| 18 | 结果按钮点击后“没反应” | `generaltest_callback_query` 的 `cache.get` 不抛异常，过期时 `data[node]` 抛 `TypeError` 被 `except` 吞掉；“结果已失效”分支实际不可达 | **修正**：显式 `if data is None` 后提示过期 |
| 19 | `info_` 回调点击后无变化 | `info_callback_query` 全异常静默；常见于 ASN 无权限或节点已下线 | 保留静默；建议加 toast（`answer_callback_query`）提示原因 |
| 20 | `Markdown` 解析失败（尤其是用户可控的 Contact/域名） | 结果直接插入三反引号块或裸文本，未转义反引号 | 保留现状（代码块内相对安全）；`Contact` 等字段渲染到块外时需转义 |

#### 7.16.4 命令解析与边界

| # | 现象 | 原因 | 建议 |
|---|---|---|---|
| 21 | `/tcping host 65535` 的端口被当成节点名 | 判定条件为 `0 < int(port) < 65535`，漏掉 65535；且 `server_list[0]` 可能不是数字 | 修正：`1 <= port <= 65535`，并仅在“纯数字”时消费 |
| 22 | `/route 1.2.3.4/abc` 静默丢弃 `/abc` | 先 `rsplit("/", 1)` 再尝试 `int`，失败后 `netlen=None` 但 `target` 已被截断 | 修正：先校验再截断 |
| 23 | `/dig` 把含点的类型（不存在）或含点的 DNS 服务器误判 | 类型判定用“是否含 `.`”，DNS 服务器用 `@` 前缀 | 保留；帮助文本已限定白名单 |
| 24 | `/whois` 对数字输入会二次补全并重试 | 首次结果不满足“单条 inetnum/inet6num”时，把纯数字改写成 `AS...` 再查；仍失败且 `DN42_ONLY=0` 时改用 `whois -I` | 保留；注意循环最多 3 次，勿写成死循环 |
| 25 | `/peer_list` 在群聊无参数时报用法，即使发言人已登录 | 仅私聊读取 `db[chat_id]` | 保留 |
| 26 | `/rank` 带 ASN 参数时转调 `/stats`，但 `/stats` 会再次解析命令文本 | `stats(message)` 直接复用原消息，`/rank 4242420001` 中 `split()[1]` 恰好是 ASN，才成立 | 保留；若改命令名/参数位置需同步调整 |
| 27 | 深链 `whoami_` 参数含多余下划线会导致回落欢迎页 | `command[7:].split("_")` 不限制分割次数，超过 2 段时 `whoami` 收到过多位置参数 → `TypeError` → `/start` 的 `except` 发欢迎消息 | 保留；生成链接时节点名不应含下划线 |
| 28 | `info_{asn}_{node}` 的 `node` 含下划线可正常解析（`split("_", 3)`） | 与 `whoami_` 规则不同 | 记录差异，避免统一重构时破坏兼容 |

#### 7.16.5 权限与通知

| # | 现象 | 原因 | 建议 |
|---|---|---|---|
| 29 | `/remove` 在所有节点离线时可能发出“空键盘”消息 | `removable` 来自 `get_info`（离线节点已被过滤），为空时仍走 `len != 1` 分支构造无按钮的 `ReplyKeyboardMarkup` | 修正：`removable` 为空时直接提示“无可用节点”并返回 |
| 30 | `recreate_peer_info` 失败后继续执行导致二次异常 | 该函数在信息非 dict 时只发错误消息并返回 `None`，`/modify`、`/remove` 调用方未判空 | 修正：返回 `None` 时终止流程 |
| 31 | 特权广播可能重复或漏发 | `db_privilege - {chat_id}` 为集合，顺序不定；接收者若已切换身份会收到“已在该身份”变体 | 保留；测试时不要依赖顺序 |
| 32 | `SINGLE_PRIVILEGE=1` 时无法再用特权码新增特权用户 | `login_choose_email` 条件 `not (config.SINGLE_PRIVILEGE and db_privilege)` | 保留；运维需预留一个可用的特权账号 |
| 33 | `/logout` 会同时移除特权身份 | 代码无条件 `db_privilege.remove()` | 保留；提示运维“退出即失去特权” |
| 34 | 特权码可被无限次尝试 | 无失败计数、无冷却 | **修正**：按 `chat_id` 限制尝试次数并告警 |

#### 7.16.6 并发、部署与可观测性

| # | 现象 | 原因 | 建议 |
|---|---|---|---|
| 35 | Sentry 事务串台、`finish()` 重复调用 | `MyMiddleware` 把 `transaction` 存在实例属性上，多线程处理并发消息时互相覆盖 | **修正（高优先级）**：改用 `threading.local()` 或每次请求新建上下文 |
| 36 | 多 worker 部署后登录状态/流程错乱 | `db`、`step.save` 均为进程内/pickle 状态 | **必须单进程**；扩容方案见 §10.1 |
| 37 | `POST /version` 返回 405 | 客户端误用 GET | 保留“全部端点均为 POST”的约定，联调脚本统一 POST |
| 38 | Agent 返回明文 500 且无日志 | `aiohttp` 未捕获异常，仅返回堆栈 | 修正：Agent 侧统一异常处理并写结构化日志（见 §15） |
| 39 | 升级 Server 后 Agent 全部 500 | `MIN_AGENT_VERSION` 校验未通过 | 按 §2.4.8 先升 Agent 再升 Server |
| 40 | 定时任务时间漂移 | 调度器固定 `timezone=utc`，`misfire_grace_time=None` 表示允许无限延迟补跑 | 保留；主机时钟必须 NTP 同步，否则“Updated Ns ago”会出现负数 |

---

## 8. Agent 实现规格

### 8.1 启动

- 加载 `agent_config.json`，任一键缺失/非法 → 打印错误并 `exit(1)`。
- 创建 `aiohttp.web.Application`，挂载 `base.routes`。
- 注册 `POST /version`（注意仓库中该端点也是 POST，与其余 API 一致）。
- 监听 `HOST:PORT`。

### 8.2 通用执行函数

```python
def simple_run(command, timeout=3):
    # shlex.split 后 subprocess.check_output，stderr 合并到 stdout
    # CalledProcessError 时返回其 output
```

不得使用 `shell=True`。

### 8.3 WireGuard 配置模板（必须逐字兼容 `/info` 正则）

```ini
# {ASN} - {Contact}
[Interface]
ListenPort = {Port}
Table = off
MTU = 1420
PostUp = wg set %i private-key /etc/wireguard/dn42-privatekey
PostUp = ip addr add {MY_LLA}/64{ peer LLA}/64 dev %i
PostUp = ip addr add {MY_ULA}/128{ peer ULA}/128 dev %i
PostUp = ip addr add {MY_IPV4}/32{ peer IPv4}/32 dev %i
PostUp = sysctl -w net.ipv6.conf.%i.autoconf=0

[Peer]
PublicKey = {peer PublicKey}
Endpoint = {Clearnet}
AllowedIPs = 172.20.0.0/14, 10.0.0.0/8, 172.31.0.0/16, fd00::/8, fe80::/64
```

规则：

- `{ peer X}` 只在对应值存在时展开为 ` peer {value}/{prefix}`。
- `Request-LinkLocal` 非法时使用 `MY_DN42_LINK_LOCAL_ADDRESS`。
- `Clearnet is None` 时删除整行 `Endpoint = None`。
- 注释首行带 `# {ASN} - {Contact}`。

`/info` 使用的解析正则（复刻时保持分组顺序一致）：

```python
r"\[Interface\]\n"
r"ListenPort = ([0-9]+)\n"
r"Table = off\n"
r"(?:MTU = [0-9]+\n)?"
r"PostUp = wg set %i private-key /etc/wireguard/dn42-privatekey\n"
r"PostUp = ip addr add (fe80::[0-9a-f:]+)/64(?: peer (fe80::[0-9a-f:]+)/64)? dev %i\n"
r"PostUp = ip addr add {MY_ULA}/128(?: peer (f[cd][0-9a-f:]+)/128)? dev %i\n"
r"PostUp = ip addr add {MY_IPV4}/32(?: peer ([0-9.]+)/32)? dev %i\n"
r"PostUp = sysctl -w net.ipv6.conf.%i.autoconf=0\n\n"
r"\[Peer\]\n"
r"PublicKey = (.{43}=)\n"
r"(?:Endpoint = (.+:[0-9]{,5})\n)?"
r"AllowedIPs = "
```

分组映射：

| 索引 | 含义 |
|---|---|
| 0 | `ListenPort` |
| 1 | 本节点 LLA |
| 2 | 对端 LLA（若使用 LLA 会话） |
| 3 | 对端 ULA |
| 4 | 对端 IPv4 |
| 5 | 对端公钥 |
| 6 | Endpoint（含端口） |

派生：

- `v6 = group2 if group2 else group3`
- `my_v6 = group1 if group2 else MY_ULA`
- `my_v4 = MY_IPV4 if group4 else None`
- `clearnet = group6 or None`

### 8.4 BIRD 配置生成矩阵

通用协议模板：

```text
protocol bgp DN42_{ASN}_v{version} from dn42_peers {
    neighbor {IPv4 或 IPv6} % 'dn42-{ASN}' external;
    description "{Contact}";
    [单栈屏蔽块]
}
```

单栈屏蔽块：

```text
    ipv4 {
        import none;
        export none;
    };
```

（当会话为 v6 时屏蔽 `ipv4`；当会话为 v4 时屏蔽 `ipv6`。）

| Channel | MP-BGP | 输出 |
|---|---|---|
| IPv6 only | — | `v6` 会话 + 屏蔽 `ipv4` |
| IPv4 only | — | `v4` 会话 + 屏蔽 `ipv6` |
| IPv6 & IPv4 | IPv6 | `v6` 会话，不屏蔽 |
| IPv6 & IPv4 | IPv4 | `v4` 会话，不屏蔽 |
| IPv6 & IPv4 | Not supported | `v6` 屏蔽块 + 空行 + `v4` 屏蔽块（两个会话） |

注意 `neighbor` 值取自 `peer_info["IPv6"]` 或 `peer_info["IPv4"]`，因此双栈 + MP-BGP v6 时必须保证 `IPv6` 是有效地址。

### 8.5 `/info` 的 BIRD 解析

会话识别正则：

```python
bird_regex_v4 = r"protocol bgp DN42_{ASN}_v4 from dn42_peers \{\n(?:(?: +.*?\n)*?.*\n)+?\}"
bird_regex_v6 = r"protocol bgp DN42_{ASN}_v6 from dn42_peers \{\n(?:(?: +.*?\n)*?.*\n)+?\}"
```

单栈判定正则（在会话块内查找）：

```python
bird_regex_v4_only = (
    r" {4}ipv6 \{\n"
    r"(?: {4,}.*?\n)*?"
    r"(?:(?: {8}import none;\n(?: {4,}.*?\n)*? {8}export none;)"
    r"|(?: {8}export none;\n(?: {4,}.*?\n)*? {8}import none;))\n"
    r"(?: {4,}.*?\n)*?"
    r" {4}\};"
)
```

`bird_regex_v6_only` 同理，只是把 `ipv6` 换成 `ipv4`。

description 提取：`^ {4}description "(.*)";$`。

会话状态：

- `birdc show protocols {name}` 必须正好 3 行，否则 `500 "bird error"`；
- 第 3 行 `split(maxsplit=6)`：索引 5 为状态，索引 6（若存在）为附加信息；
- 状态为 `Established` 时执行 `birdc show protocols all {name}`，按 `Channel ` 切分，解析每个 `ipv*` 通道的 `State`、`Output filter`、`Routes`；仅 `UP` 且输出过滤器为 `(unnamed)` 的通道计入路由数。

WG 状态：

- `wg show dn42-{ASN} latest-handshakes`：首字段必须等于配置中的公钥，否则 `500 "wg error"`；无设备时记 0。
- `wg show dn42-{ASN} transfer`：同上，得到 `[received, sent]`。

### 8.6 建 Peer 的完整副作用顺序

```text
写 wg 配置
写 bird 配置
systemctl daemon-reload
systemctl enable wg-quick@dn42-{ASN}
systemctl restart wg-quick@dn42-{ASN}
birdc c
[可选] vnstat --add -i dn42-{ASN}
```

删除：

```text
systemctl stop wg-quick@dn42-{ASN}
systemctl disable wg-quick@dn42-{ASN}
rm /etc/wireguard/dn42-{ASN}.conf
rm /etc/bird/dn42_peers/{ASN}.conf
birdc c
[可选] vnstat --remove -i dn42-{ASN} --force
```

---

## 9. 交互与文案规范

1. **双语**：所有面向用户的提示同时给出英文和中文，英文在前，中文在后，用换行分隔。
2. **键盘策略**：
   - 流程采集用 `ReplyKeyboardMarkup(resize_keyboard=True)`，每个流程开始/结束时都要 `ReplyKeyboardRemove()`；
   - 节点切换、分页、刷新用 `InlineKeyboardMarkup`。
3. **可见性**：
   - 修改身份、Peer、修改、删除、重启、`/info` 均限定 `is_private_chat=True`；
   - 查询类命令（ping/rank/stats 等）允许群聊使用。
4. **深链**：Telegram URL 按钮无法携带 callback，统一使用 `https://t.me/{bot}?start={action}`：
   - `login`、`peer`、`info`、`info_{asn}_{node}`、`whoami_{asn}_{node}`。
5. **Markdown**：结果块统一用三反引号 + 语义标签（`PeerInfo`、`CurrentInfo`、`ModifiedInfo`、`ComfirmInfo`、`Info`、`Rank`、`Flaps`、`PeerList`、`DigResult`、`WhoisResult`、`{Command}Result-{NODE}`）。
6. **错误处理**：命令内部异常统一提示“Error encountered, please try again / 联系 CONTACT”，同时上报 Sentry；`edit_message_text` 的“消息未变化”错误可静默。
7. **长消息**：4000 字符为上限，优先在换行处切分。

---

## 10. 安全要求

复刻时必须保留以下防护：

1. 所有外部命令用 `shlex.split` + `subprocess`，禁止 `shell=True`。
2. 用户输入必须经过结构化校验：
   - IPv6：`ipaddress` + 网段判断；
   - IPv4：`ipaddress` + 网段判断；
   - 端口：整数且 `1..65535`；
   - 公钥：长度 44 且以 `=` 结尾；
   - 联系人/查询字符串：字符白名单；
   - 域名：punycode 归一。
3. Agent 所有端点必须校验 Header Secret；webhook 必须校验 `X-Telegram-Bot-Api-Secret-Token`。
4. 高危操作需要二次确认：`/peer` 输 `yes`，`/remove` 输 32 位随机码，`/restart` 输 `yes`。
5. 特权操作在所有关键分支都要显式判断 `chat_id in db_privilege`。

已知风险（复刻时可作为改进项）：

| 风险 | 说明 | 建议 |
|---|---|---|
| 明文 HTTP | Agent API 无 TLS | 内网隔离 / WireGuard / mTLS |
| Secret 明文 | JSON 配置中的 `SECRET` | 文件权限 600、独立低权限账户（但需 root 执行，建议用受控 sudo 或 systemd 单元） |
| pickle | `user_db.pkl`、`map.pkl`、`step.save` | 确保目录不可被低权限写入；长期可改 JSON/SQLite |
| 无速率限制 | 公开工具命令可被刷 | 按 chat_id 做令牌桶 |
| 单进程状态 | 多 worker 会不一致 | 固定单进程，或把状态外置 Redis |
| 未鉴权 `/health` | 泄露节点名 | 仅内网暴露 |
| 异常吞掉 | 排障困难 | 统一日志 + Sentry |
| 特权码无尝试限制 | 可被暴力尝试 | 加失败计数与告警 |

### 10.1 安全加固方案

> 本节面向生产部署。§10 的“必须保留”是**功能兼容底线**，§10.1 是**在不改变交互契约的前提下**可以叠加的加固措施。

#### 10.1.1 威胁模型

| 资产 | 暴露面 | 主要威胁 |
|---|---|---|
| Agent API（root 执行 wg/birdc） | 内网或公网 `API_PORT` | 伪造请求、重放、SSRF 横向 |
| Bot Token | 配置文件/环境变量 | 泄露后他人可完全接管 Bot |
| 特权码 | 登录流程输入 | 暴力枚举、内部人滥用 |
| `user_db.pkl` | 工作目录 | 篡改实现身份冒用 |
| whois/dig/ping 子进程 | 用户可控参数 | 参数注入、资源耗尽 |
| Webhook 入口 | 公网 443 | 伪造更新、重放 |

#### 10.1.2 Agent 通道加固

**（1）TLS + 双向认证（推荐）**

在每台节点上用 nginx 终止 TLS，Agent 只监听 `127.0.0.1`：

```nginx
server {
    listen 8443 ssl;
    server_name node1.example.com;

    ssl_certificate     /etc/dn42-bot/agent.crt;
    ssl_certificate_key /etc/dn42-bot/agent.key;
    ssl_client_certificate /etc/dn42-bot/ca.crt;
    ssl_verify_client   on;

    location / {
        if ($ssl_client_verify != SUCCESS) { return 403; }
        proxy_pass http://127.0.0.1:5000;
        proxy_set_header X-DN42-Bot-Api-Secret-Token $http_x_dn42_bot_api_secret_token;
        client_max_body_size 1m;
    }
}
```

Server 侧只需把 `API_PORT` 改为 `8443`、`HOSTS` 指向域名，并在 `get_from_agent` 中把 `http://` 换成 `https://` 且传入 `verify="/etc/dn42-bot/ca.crt"`、`cert=(client.crt, client.key)`。

**（2）Secret 轮换**

- Secret 至少 32 字节随机值（可用 `gen_random_code(32)`），三处一致：Server `API_TOKEN` / Agent `SECRET` / 代理透传头。
- 轮换步骤：新增第二个可用 Secret（Agent 支持列表）→ 灰度 Server → 删除旧值。若不想改 Agent，则按“先停 Server → 改两端 → 启 Server”的短窗口执行。
- 禁止把 Secret 写进 URL、日志、Sentry breadcrumb。

**（3）网络层**

- Agent 端口只允许 Server 出口 IP，默认拒绝：
  ```bash
  iptables -A INPUT -p tcp --dport 5000 -s <server_ip> -j ACCEPT
  iptables -A INPUT -p tcp --dport 5000 -j DROP
  ```
- 若跨公网，优先走 WireGuard 内网地址，而不是直接暴露端口。

#### 10.1.3 Server 入口加固

- **Webhook**：必须使用 `secret_token`，并校验 `X-Telegram-Bot-Api-Secret-Token`；令牌随机生成、只存内存、重启即换（原实现即如此）。反代层再加 IP/速率限制。
- **`/health`**：原实现返回 `,`.join(节点名)，会泄露拓扑。加固方案：
  - 只监听 `127.0.0.1`，由本机探针访问；
  - 或改为 `{"status":"ok","nodes":N}`，不返回节点名；
  - 如需节点名，增加独立 Token 校验。
- **Polling 模式**：不要同时启用 `WEBHOOK_URL`；启动时先 `remove_webhook()` 再按配置选择模式。

#### 10.1.4 限流与防刷

原实现无任何速率限制。建议在中间件层加**按 chat_id 的令牌桶**，且只对公开工具命令生效：

```python
import time
from collections import defaultdict

class RateLimiter:
    def __init__(self, rate=10, burst=20):
        self.rate = rate          # 每秒补充的令牌
        self.burst = burst        # 桶容量
        self.state = defaultdict(lambda: [burst, time.monotonic()])

    def allow(self, key):
        tokens, last = self.state[key]
        now = time.monotonic()
        tokens = min(self.burst, tokens + (now - last) * self.rate)
        if tokens < 1:
            self.state[key] = [tokens, now]
            return False
        self.state[key] = [tokens - 1, now]
        return True
```

建议阈值：

| 命令类别 | 速率 | 突发 | 超限行为 |
|---|---|---|---|
| `/ping` `/tcping` `/trace` `/route` `/path` | 1 次/10s | 3 | 回复 `Too many requests, please try again later.\n请求过于频繁，请稍后再试。` |
| `/dig` `/whois` | 1 次/5s | 5 | 同上 |
| `/peer` `/modify` `/remove` `/restart` | 1 次/30s | 2 | 同上 |
| `/login` 验证码 | 1 次/60s | 2 | 同时记录失败次数，≥5 次锁定 15 分钟 |

注意：限流状态同样不能跨进程，必须与单进程部署一致，或放入 Redis。

#### 10.1.5 状态外置（扩容路径）

若必须多 worker/多机，按以下方式替换进程内状态：

| 现状 | 替换为 | 说明 |
|---|---|---|
| `db: dict[chat_id, asn]` | Redis Hash `dn42bot:user` | 读写加锁即可 |
| `db_privilege: set` | Redis Set `dn42bot:privilege` | — |
| `step.save`（pickle） | Redis `dn42bot:step:{chat_id}` + 序列化后的状态 | 需要把 `partial` 改为“步骤名 + peer_info”可序列化结构 |
| `map.pkl` / `flaps` 缓存 | Redis String（JSON） | 定时任务只由一个实例执行（分布式锁） |
| `all_in_one` 结果缓存 | Redis + TTL | 键为 `data_id`，TTL 3 天 |
| 定时任务 | 单实例 + 分布式锁 | 避免重复抓取地图/Flap |

#### 10.1.6 输入与命令执行加固

- 保持 `shlex.split` + 参数列表，禁止拼接 shell；禁止 `shell=True`。
- 所有“用户输入直接进入子进程”的位置做**白名单**：
  - `/dig`：类型白名单 + punycode + `DN42_ONLY` 时强制 `.dn42`；
  - `/whois`：字符集 `A-Za-z0-9_-./:`；
  - `/ping` 等：先经 `test_ip_domain` 归一为 IP，再传给 Agent。
- Agent 侧对 `asn` 做 `int` 校验并限制范围（`1..4294967295`），对 `ifname` 只允许 `dn42-{数字}`。
- 子进程统一设置 `timeout`（whois 3s、dig 8s、ping/trace 10s、tcping 12s），并限制并发数（`asyncio.Semaphore`）。
- 禁止把用户输入拼进 BIRD 模板的注释/描述字段；`Contact` 仅写入 WG 注释时也要过滤换行。

#### 10.1.7 密钥与文件权限

```bash
chmod 600 /opt/dn42-bot/server/config.py
chmod 600 /opt/dn42-bot/agent/agent_config.json
chmod 700 /opt/dn42-bot/server
chown -R dn42bot:dn42bot /opt/dn42-bot/server
```

- Agent 需要 root 执行 `wg-quick`/`birdc`：建议用 systemd 单元 + `ExecStart` 固定脚本，或为专用用户配置最小化 sudoers：
  ```sudoers
  dn42bot ALL=(root) NOPASSWD: /usr/bin/wg-quick up dn42-*, /usr/bin/wg-quick down dn42-*, /usr/bin/birdc *
  ```
  注意 sudoers 通配符仍有风险，最稳妥是写一个只接受固定子命令的包装脚本。
- Bot Token、SMTP 密码优先用环境变量或 systemd `EnvironmentFile`，不要提交到仓库。

#### 10.1.8 日志与审计

- 必须记录：时间、`chat_id`、`asn`、命令、目标节点、Agent 状态码、耗时、结果摘要。
- 禁止记录：Bot Token、API Secret、验证码明文、完整公钥（可只记后 4 位）。
- 特权操作（特权码登录、切换身份、代他人修改/删除）单独审计日志，保留 ≥180 天。
- `user_db.pkl` 每次写入前后记录 hash，便于发现篡改。

#### 10.1.9 加固后的回归清单

- [ ] Agent 在 TLS/mTLS 下 `/version`、`/peer`、`/info` 均正常。
- [ ] Secret 错误时返回 401/403，且不会执行任何命令。
- [ ] 限流触发后提示文案正确，且不影响正常用户。
- [ ] `/health` 不再泄露节点名（或已限制来源）。
- [ ] 状态外置后，重启 Server 不丢登录态与进行中的流程。
- [ ] 审计日志可通过 `chat_id` 还原一次完整的建 Peer 操作。

---

## 11. 建议实现顺序

1. **骨架**：`base.py` + `main.py`，完成 bot 启动、命令注册、`servers_check`。
2. **Agent 最小闭环**：`/version`、`/pre_peer`、`/info`、`/peer`、`/remove`、`/restart`。
3. **通用库**：`extract_asn`、`test_ip_domain`、`get_whoisinfo_by_asn`、`get_from_agent`。
4. **登录体系**：`/login`、`/logout`、`/whoami`、pickle 持久化。
5. **建 Peer 状态机**：`peer.py` + `info_collect.py`，先跑通单节点单栈。
6. **修改/删除/重启**：复用 `info_collect`，加入 `stop_sign`。
7. **查询命令**：`/ping`、`/trace`、`/tcping`、`/route`、`/path`、`/dig`、`/whois`。
8. **信息与统计**：`/info` 渲染、`/rank`、`/stats`、`/peer_list`、`/flaps`。
9. **打磨**：Sentry、webhook、lg 按钮、长消息切分、离线提示。

---

## 12. 验收用例

### 12.1 认证

| 用例 | 预期 |
|---|---|
| `/login` 输入 `123` | 自动补全为 `AS4242420123` 后查询邮箱 |
| `/login` 输入 `1816` | 命中 `AS4242421816` |
| 输入不存在的 ASN | 提示未注册并允许重试 |
| 选择非 Registry 邮箱 | 拒绝并提示联系管理员 |
| 输错验证码 | 提示错误，可重新 `/login` |
| 输入特权码 | 直接成为特权用户；`SINGLE_PRIVILEGE=true` 且已有特权时拒绝 |
| `/logout` 特权用户 | 同时移出特权集合 |

### 12.2 建 Peer

| 用例 | 预期 |
|---|---|
| 未登录 `/peer` | 提示登录 |
| ASN 非 `424242xxxx` 且非特权 | 拒绝自动 Peer |
| 已与全部节点 Peer | 提示无需再建 |
| 仅一个可用节点 | 自动选择 |
| 节点容量已满且非特权 | 节点不可选；全部不可选时提示无可用节点 |
| `MIN_PEER_REQUIREMENT` 未达标 | 节点不可选并显示差距 |
| IPv6 输入 `fd00::1/128` | 通过并去掉 `/128` |
| IPv6 输入 `fe80::1` | 进入“我这边 LLA”确认步骤 |
| IPv4 输入 `172.20.1.2` | 通过 |
| IPv4 输入 `8.8.8.8` | 拒绝 |
| Clearnet 输入 `example.com:21816` | 自动拆出端口并校验 |
| Clearnet 输入 `none` 且允许 | 生成不含 Endpoint 的配置 |
| Clearnet 为中国大陆 IP 且节点 `cn=false` | 拒绝；特权可继续 |
| 公钥长度不是 44 | 拒绝 |
| 联系人含中文 | 拒绝 |
| 确认页输入非 `yes` | 取消 |
| Agent 返回 503 | 提示节点未开放/已满 |
| 成功后 | 显示“Show info”按钮；其他特权用户收到通知 |

### 12.3 修改

| 用例 | 预期 |
|---|---|
| 无 Peer 时 `/modify` | 提示先 `/peer` |
| 只改 Contact | 只经过 Contact 步骤，diff 正确 |
| 只改 Region | 新节点建成功后再删旧节点；旧节点删除失败有明确提示 |
| 只改公钥 | 同节点提交后自动 `/restart` |
| 未做任何修改 | 提示无变更并结束 |
| 选择 Abort | 取消且不提交 |
| 会话类型从双栈 MP-BGP 改为 IPv4 only | 生成的 bird 只保留 v4 且屏蔽 v6 |

### 12.4 删除与重启

| 用例 | 预期 |
|---|---|
| `/remove` 输错随机码 | 取消，不调用 Agent |
| 删除成功 | 文件与服务均清理，特权用户收到通知 |
| `/restart` 输 `yes` | 隧道与两个 BGP 会话重启 |
| 会话不存在 | Agent 返回 404，Bot 提示失败 |

### 12.5 查询

| 用例 | 预期 |
|---|---|
| 部分节点离线执行 `/ping 1.1.1.1` | 离线节点显示 “Node is offline.”，其余正常 |
| 点击节点按钮 | 原地切换为该节点结果 |
| 缓存超过 3 天 | 提示结果失效需重跑 |
| `/route` 结果含 `local_pref: 0` | 追加封锁提示 |
| `/path` 无 AS Path | 显示 “Not found” |
| `/dig example.dn42 A` | 返回 A 记录 |
| `/dig x.com ANY` 且 `DN42_ONLY=true` | 拒绝非 `.dn42` |
| `/whois 1816` | 补全为 ASN 并返回 whois + 路由 + 统计 |
| `/rank` 翻页/切指标 | 内容与按钮同步更新 |
| `/flaps` 未配置 | 提示未启用 |
| `/info` 非特权查他人 | 拒绝 |

---

## 13. 行为一致性检查清单

- [ ] `pre_` 步骤立即执行，`post_` 步骤等待输入，`/cancel` 在任何步骤都能终止。
- [ ] 所有节点请求都带 `X-DN42-Bot-Api-Secret-Token`。
- [ ] `servers_check` 只把“在线且版本 ≥ 27”的节点放进 `base.servers`。
- [ ] `Port = "2" + ASN 后四位`；对端默认端口 `DN42_ASN % 100000`。
- [ ] WG 模板与 `/info` 正则逐字兼容。
- [ ] BIRD 配置严格按 5 种组合生成。
- [ ] `session` 字符串严格使用 5 种枚举，`/modify` 能正确反推。
- [ ] `/remove` 只有随机码完全一致才执行。
- [ ] 特权用户在所有“本应拒绝”的分支都有绕过路径，并提示 `*[Privilege]*`。
- [ ] 新 Peer / 修改 / 删除都会通知其他特权用户。
- [ ] 地图与 Flap 结果都带“更新于 N 秒前”。
- [ ] 超长结果按 4000 字符切分。
- [ ] 所有网络命令超时返回 408，非 200 有统一中文提示。
- [ ] 单进程运行，工作目录为 `server/`，三个 pickle 文件可读写。

---

## 14. 最小可行里程碑（MVP）

若只想先复刻核心价值，可按以下顺序交付：

1. Server：`/start`、`/help`、`/login`、`/logout`、`/whoami`。
2. Agent：`/version`、`/pre_peer`、`/peer`、`/info`、`/remove`、`/restart`。
3. Server：单节点、双栈、MP-BGP 支持的 `/peer` 全流程。
4. Server：`/info` 渲染 WireGuard 与 BIRD 状态。
5. Server：`/modify`、`/remove`、`/restart`。
6. 查询：`/ping`、`/trace`、`/route`、`/path`。
7. 统计：`/rank`、`/stats`、`/peer_list`（地图接口 + rustworkx）。
8. 可选：`/flaps`、Looking Glass 按钮、webhook、Sentry、CN IP 拦截。

完成 1-5 即具备“自助建 Peer + 状态查询 + 生命周期管理”的完整闭环。

---

## 15. 运维手册

### 15.1 进程与端口清单

| 进程 | 数量 | 监听 | 依赖 | 权限 |
|---|---|---|---|---|
| `server/main.py` | 1（**严禁多副本**） | polling 无端口；webhook 模式监听 `WEBHOOK_LISTEN_HOST:WEBHOOK_LISTEN_PORT` | Telegram API、Agent API、whois、DNS、地图 API、SMTP | 普通用户 |
| 各节点 `agent/main.py` | 每节点 1 | `HOST:PORT`（默认常见为 `0.0.0.0:5000`） | `wg-quick`、`birdc`、`ping`、`tcping`、`vnstat` | root |

必须固定的工作目录：`server/`（因为 `./user_db.pkl`、`./map.pkl`、`./step.save` 都是相对路径）。

### 15.2 日志与指标

**（1）日志采集**

- systemd 单元统一加：
  ```ini
  StandardOutput=append:/var/log/dn42-bot/server.log
  StandardError=append:/var/log/dn42-bot/server.log
  ```
- 或使用 `journald`：`journalctl -u dn42-bot-server -f`。
- 建议 `logrotate`：
  ```text
  /var/log/dn42-bot/*.log {
      daily
      rotate 14
      compress
      missingok
      notifempty
      copytruncate
  }
  ```

**（2）必须打点的业务指标**

| 指标 | 来源 | 告警阈值建议 |
|---|---|---|
| Agent 在线数 | `servers_check` 结果 | < 总节点数 立即告警 |
| Agent `/version` 低于 `MIN_AGENT_VERSION` | 启动自检 | 任一节点 → 告警 |
| 地图更新时间 | `get_map()[0]` | 超过 15 分钟未更新 |
| Flap 更新时间 | `get_flaps()[0]` | 超过 15 分钟未更新 |
| 命令异常率 | 中间件 `post_process` | 5 分钟内 > 5 次 |
| 建 Peer 成功率 | `/peer` 结果 | 连续 3 次失败 |
| 登录验证码发送失败 | `send_email` 抛 `RuntimeError` | 连续 3 次 |
| `step.save` 大小 | 文件 stat | 异常增长（>10MB） |

**（3）日志关键字**

```text
Traceback
Error encountered
failed to restart
failed to remove
Agent version
Unauthorized
```

### 15.3 日常巡检脚本

```bash
#!/usr/bin/env bash
set -u
echo "== systemd =="
systemctl is-active dn42-bot-server
for u in $(systemctl list-units --type=service --state=running | awk '/dn42-bot-agent/{print $1}'); do
  echo "$u: $(systemctl is-active "$u")"
done

echo "== agent health =="
for host in $(jq -r '.[]' /opt/dn42-bot/agent_hosts.json); do
  code=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H "X-DN42-Bot-Api-Secret-Token: $API_TOKEN" \
    "http://$host:5000/version")
  echo "$host -> $code"
done

echo "== state files =="
ls -lh /opt/dn42-bot/server/{user_db.pkl,map.pkl,step.save} 2>/dev/null

echo "== wireguard =="
wg show | grep -c 'peer:'

echo "== disk =="
df -h /opt /var/log
```

建议用 cron 每 5 分钟执行一次，异常时通过独立通道（而非本 Bot）告警。

### 15.4 故障排查决策树

| 症状 | 优先检查 | 处理 |
|---|---|---|
| Bot 完全无响应 | `systemctl status`、进程是否退出、Token 是否失效 | 看日志；Token 失效需重新签发并更新配置 |
| 群聊可用、私聊无响应 | 是否 `is_private_chat=True` 命令、用户是否 block Bot | 让用户 `/start`；检查 Bot 隐私模式 |
| 所有命令提示“Error encountered” | 中间件异常；Sentry；`step.save` 反序列化 | 临时移除 `step.save` 后重启 |
| `/peer` 列表全部离线 | Server → Agent 网络、Secret、Agent 进程 | 按 §5.4 用 curl 逐节点验证 |
| `/peer` 提示某节点“Server error” | Agent 返回非 200 / JSON 解析失败 | 看 Agent 日志与 `/pre_peer` 原始响应 |
| 建 Peer 成功但 BGP 不 up | `birdc show protocols`、WG handshake、对端配置 | 让用户 `/info` 核对双方地址与公钥 |
| `/info` 显示 `Latest handshake: Never` | 对端未发起、端口/防火墙、公钥不匹配 | 检查 UDP 端口与 NAT；必要时 `/restart` |
| `/info` 显示节点 `Error occurred` | Agent `/info` 返回非 dict | 看 Agent 解析 WG/BIRD 的正则是否匹配 |
| `/modify` 卡在“Current information” | 原 Peer 信息缺失字段（老数据） | 手工核对，必要时 `/remove` 后重建 |
| `/remove` 提示离线但仍有节点 | `base.servers` 与 `config.SERVERS` 不一致 | 等 `servers_check` 下一轮；或重启 Server |
| `/rank`、`/stats` 显示 N/A | 地图接口失败 / ASN 不在数据中 | 检查 `get_map` 日志与 API 可用性 |
| `/flaps` 无数据 | `FLAPALERTED_URL` 未配置或接口失败 | 配置后重启；检查定时任务 |
| 深链按钮打开后只发欢迎语 | 参数格式错误（ASN 非整数、下划线过多） | 核对 §7.15.2 的格式 |
| 结果按钮点击无反应 | 缓存过期 / 消息过旧 / 权限不足 | 重新执行命令；查看回调异常日志 |
| 重启后用户需重新登录 | `user_db.pkl` 丢失或工作目录错误 | 恢复备份；确认 `WorkingDirectory` |

### 15.5 典型故障处置

**（1）Agent 全部 500**

1. 在 Server 上执行 §5.4 的 curl，确认是网络、鉴权还是业务异常。
2. 若返回 401/403：核对 `API_TOKEN` 与 Agent `SECRET`。
3. 若连接被拒：检查 Agent 是否监听、防火墙、`HOST` 配置。
4. 若返回 500 且日志有 `Traceback`：按堆栈修复；常见为 WG 文件不存在、`birdc` 路径错误、`vnstat` 缺失。

**（2）地图长期不更新**

1. 手动触发：在 Server 容器内 `python -c "import tools; tools.get_map(update=True)"`。
2. 检查 `api.iedon.com/dn42/map?type=json` 是否可达、返回结构是否变化。
3. 检查 `map.pkl` 是否可写、磁盘是否已满。

**（3）`step.save` 损坏导致启动失败**

```bash
systemctl stop dn42-bot-server
mv /opt/dn42-bot/server/step.save /opt/dn42-bot/server/step.save.bak.$(date +%s)
systemctl start dn42-bot-server
```

影响：所有进行中的多轮流程丢失，用户需重新执行命令。建议在升级前主动清理。

**（4）误删 Peer 的恢复**

- Bot 无“撤销”。若用户仍有旧配置，可用 `/peer` 重建；端口、公钥、地址需与旧配置一致。
- 特权用户可通过 `/whoami {asn}` 切换身份后 `/info` 核对。
- 节点侧可检查 `/etc/wireguard/dn42-{ASN}.conf` 与 `/etc/bird/peers/dn42-{ASN}.conf` 是否已被删除。

### 15.6 备份与恢复

**备份对象**（每日一次，保留 30 天）：

```text
server/user_db.pkl
server/map.pkl          # 可选，可重新抓取
server/config.py        # 含密钥，加密存储
agent/agent_config.json # 每节点，加密存储
/etc/wireguard/dn42-*.conf
/etc/bird/peers/dn42-*.conf
```

**备份命令示例**：

```bash
tar -czf /backup/dn42-bot-$(date +%F).tar.gz \
  -C /opt/dn42-bot server/user_db.pkl server/config.py \
  -C /etc wireguard bird/peers
gpg --encrypt --recipient ops@example.com /backup/dn42-bot-$(date +%F).tar.gz
```

**恢复顺序**：

1. 停 Server；
2. 恢复 `user_db.pkl` 与 `config.py`；
3. 恢复各节点 WG/BIRD 配置；
4. 启动 Agent → 启动 Server；
5. 用 `/version`、`/whoami`、`/info` 验证。

### 15.7 发布与回滚

| 步骤 | Server | Agent |
|---|---|---|
| 1 | 备份状态文件 | 备份配置 |
| 2 | 停止服务 | 逐节点停止 |
| 3 | 更新代码与依赖 | 更新代码与依赖 |
| 4 | 启动并观察 5 分钟 | 逐节点启动并验证 `/version` |
| 5 | 验证 `/peer`、`/info`、`/remove` | 验证 WG/BIRD 未受影响 |

**顺序约束**：Agent 版本必须 ≥ Server 的 `MIN_AGENT_VERSION`。升级时**先 Agent 后 Server**；回滚时**先 Server 后 Agent**。

**回滚判定**：出现以下任一情况立即回滚：

- `/version` 大面积 500；
- `/info` 解析全部失败；
- 新建 Peer 后 BGP 无法建立且回滚前正常；
- Server 启动即异常退出。

### 15.8 容量与性能基线

| 项 | 基线 | 说明 |
|---|---|---|
| 单节点 Peer 数 | 数十到数百 | WG 接口数、BIRD peer 数线性增长 |
| `servers_check` | 每 3 分钟 | 节点多时注意超时叠加 |
| 地图抓取 | 每 3 分钟 | `rustworkx` 计算为 CPU 密集，节点多时可达数秒 |
| 单次 `/ping` 全节点 | ≈ 最慢节点耗时 | 并发请求，超时 10s |
| `get_from_agent` 重试 | 5 次，退避 0.1 | 节点宕机时会拖长整体耗时 |
| `step.save` | 随进行中流程数增长 | 建议每月清理一次 |

### 15.9 监控告警建议

- **P1（立即）**：Server 进程退出、全部 Agent 离线、`user_db.pkl` 不可读。
- **P2（15 分钟内）**：单节点离线、地图/Flap 超 15 分钟未更新、命令异常率突增。
- **P3（当日）**：磁盘 > 80%、`step.save` 异常增长、验证码发送失败、Agent 版本落后。

---

## 16. 改进建议

> 按“投入产出比”排序。P0/P1 建议在复刻版中直接做掉；P2 起属于架构演进，按实际规模决定。

### 16.1 P0：正确性（不改变交互）

1. **区分“无 Peer”与“节点不可用”**：让 `get_info` 返回 `(peers, errors)`，`/peer` 在存在 408/500 时拒绝继续并提示“节点暂时不可用”，避免重复建 Peer。
2. **whois 失败 fail-closed**：`extract_asn` 在子进程异常/超时时返回 `None`，而不是放行。
3. **`split_long_msg` 永不返回 `None`**：超长单行按字符硬切；所有调用方判空。
4. **确认步骤幂等**：`post_confirm` 用 `get` 而非 `pop`，成功后注销 handler，避免重复点击导致 `KeyError`。
5. **`recreate_peer_info` 失败即终止**：返回 `None` 时 `/modify`、`/remove` 直接退出。
6. **`/remove` 无可用节点时提前返回**，不构造空键盘。
7. **`/tcping` 端口边界修正**为 `1..65535`，且只消费纯数字参数。

### 16.2 P1：安全

1. Agent 全链路 TLS + mTLS（§10.1.2）。
2. 中间件限流 + 登录失败计数（§10.1.4）。
3. `MyMiddleware.transaction` 改为 `threading.local()`，消除并发串台。
4. `/health` 去敏或限制来源。
5. 验证码改为“一次性 + 5 分钟过期 + 尝试次数限制”，并只存哈希。
6. 审计日志独立落盘，覆盖特权码登录、身份切换、代操作。

### 16.3 P2：架构

1. **状态外置**：`user_db`、`step`、`map`、结果缓存迁移到 Redis（§10.1.5），为多副本与滚动发布铺路。
2. **把 `register_next_step_handler` 改为显式状态机**：`(chat_id) -> (step, peer_info, expires_at)`，可观测、可超时、可迁移。
3. **Agent 异步化**：`subprocess.run` 改为 `asyncio.create_subprocess_exec`，加信号量与每节点并发上限。
4. **配置校验**：启动时用 schema 校验 `config.py` / `agent_config.json`，缺失即失败（Agent 已如此，Server 建议补齐）。
5. **数据层**：`peer_info` 改 dataclass/TypedDict，消除字符串哨兵；WG/BIRD 解析改为“结构化读取 + 模板渲染”双向一致。

### 16.4 P3：体验

1. 流程内支持 `/back` 回退一步（需状态栈）。
2. 建 Peer 前预检：公钥格式、地址冲突、端口占用一次性提示。
3. `/info` 增加“一键复制配置”文本块（WG + BIRD 片段）。
4. 结果消息加“刷新”按钮，替代重复执行命令。
5. 中英双语按用户语言自动选择（`from_user.language_code`），保留现有文案作为默认。

### 16.5 P4：可观测性

1. 结构化日志（JSON），字段：`ts`、`chat_id`、`asn`、`cmd`、`node`、`status`、`latency_ms`。
2. OpenTelemetry Trace：Server 命令 → Agent 端点 → 子进程。
3. 每个 Agent 暴露 `/metrics`（仅内网），包含 WG peer 数、BIRD session up 数、子进程耗时。
4. 建 Peer 全链路事件表，支持按 ASN 追溯。

### 16.6 不建议做的事

- **不要**为了“看起来更现代”而更换交互范式（例如把多轮问答改成 slash 参数），这会破坏与现有用户的习惯和本文档的验收基线。
- **不要**在未做状态外置前开启多 worker/多副本。
- **不要**把 Agent 的 root 执行改为“普通用户 + 宽泛 sudo”，除非已用包装脚本收敛命令集。
- **不要**删除字符串哨兵值（`Not enabled` 等）而不迁移 `/modify` 的反推逻辑与 `/info` 的解析逻辑，否则老数据会全部失效。
