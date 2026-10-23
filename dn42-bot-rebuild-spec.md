# DN42 Bot 复刻开发文档

> 目标：依据本文档可以从零实现一个与 `Potat0000/dn42-bot` 行为等价的系统。
> 原文仓库：`https://github.com/Potat0000/dn42-bot`
> 文档范围：架构、数据模型、双端 API 契约、配置项、全部命令流程、校验规则、配置模板、定时任务、测试用例。

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
