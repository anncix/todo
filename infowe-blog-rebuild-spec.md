# infowe Blog 复刻开发文档

> 目标仓库：`https://github.com/Contribuv/infowe_blog`
> 分析基线：`13b5c4363e08ccd958e05f75865969ccfb178b33`（2026-10-09），`VERSION = '1.3.63'`
> 文档定位：**从零复刻一份行为等价、可独立部署的个人技术博客系统**。不是源码导读，而是「按本文写完即可上线」的施工图。

---

## 阅读方式与符号约定

| 记号 | 含义 |
| --- | --- |
| **必须** | 缺失会导致功能不可用、数据错乱或安全失守，复刻时不可省略 |
| **建议** | 原实现的取舍，省略后仍能跑，但体验/性能会退化 |
| **原实现** | 对上游代码事实的陈述，用于对齐行为细节 |
| **⚠️** | 已知缺陷或高风险点，复刻时应修掉而不是照抄 |
| `app.py#L379` | 上游源码行号锚点，便于逐段比对 |

文档中的代码片段是**伪实现/骨架**，用于固定数据流与边界条件；变量名、函数名尽量与上游一致，以便对照。上游是单文件 6814 行，本文按职责拆章，但**不强制**你拆文件——拆与不拆不影响可复刻性，只影响可维护性。

---

## §0 速查

### 0.1 这是什么系统

一个**单管理员、单进程可跑、SQLite 落盘、服务端渲染**的个人技术博客：

- 前台：首页（精选区 + 文章流）、归档、文章详情（Markdown 渲染 + 目录 + 评论）、标签云、项目页（GitHub 元数据 + README 渲染 + 评论）、友链、关于（技能条 + 时间线）、服务状态（HTTP 探活 + 证书到期 + 云主机到期）、RSS。
- 后台：仪表盘、文章、分类、项目、友链、时间线、评论审核、媒体上传、孤儿文件清理、服务监控、主题切换、站点设置、数据导出、在线升级。
- 认证：单账号 + PBKDF2 + 可选 TOTP 双因子 + 恢复码 + 忘记密码（邮件）。
- 扩展点：主题目录、`settings` K/V、GitHub Token、SMTP、阿里云/腾讯云 OpenAPI、ip2region 离线 IP 库。

它刻意**不包含**：多用户/注册、角色权限、CSRF token、ORM、蓝图、缓存中间件、异步任务队列、对象存储。这些「没有」本身就是设计的一部分——复刻时不要自作主张补齐，否则会改变行为语义（见 §16）。

### 0.2 规模基线

| 指标 | 数值 |
| --- | --- |
| `app.py` | 6814 行 |
| 路由数 | 83（`@app.route`） |
| 后台受保护路由 | 57（`@admin_required`） |
| 数据表 | 10（`posts` `settings` `users` `projects` `links` `comments` `timeline` `memories` `categories` `service_checks`） |
| 模板 | 52 个 `.html`（`admin/` 24、`default/` 17、`tech/` 15，另有根级 `_footer_text.html`） |
| 前端 JS | 7 个文件 1425 行 |
| 前端 CSS | 7 个文件 5345 行 |
| 依赖 | 6 个（`requirements.txt`） |
| 数据库 | 单文件 SQLite，WAL 模式 |

**复刻工作量参考**：后端 ~5.5k 行、模板 ~2.5k 行、CSS ~5k 行、JS ~1.5k 行。若只求功能等价、不追求视觉 1:1，可压缩到 40% 左右。

### 0.3 依赖清单

```text
flask==3.0.0
markdown==3.5.1
Pillow>=10.0.0
pillow-heif>=0.15.0
certifi>=2023.7.22
gunicorn>=21.0.0
```

- `Pillow` / `pillow-heif` 是**可选依赖**：上游用 `try/except` 探测 `_HAS_PIL` / `_HAS_HEIF`，缺失时跳过压缩与 HEIC 转换，上传仍可用。复刻时**必须**保持这种软依赖，否则缺库会导致启动失败。
- `certifi` 用于 GitHub / 升级下载的 SSL 上下文（部分服务器 CA 库过期）。
- `gunicorn` 仅生产用。

### 0.4 常量总表（照抄即可）

| 常量 | 值 | 作用 |
| --- | --- | --- |
| `VERSION` | `'1.3.63'` | 后台显示 + 在线升级比较基准 |
| `PAGE_SIZE` | `20` | 前台列表兜底分页 |
| `MAX_CONTENT_LENGTH` | `32 MB` | Flask 级请求体上限 |
| `_VIEW_COOLDOWN_WINDOW` | `60` 秒 | 同一 IP 对同一文章重复计数冷却 |
| `_COMMENT_COOLDOWN` | `30` 秒 | 同一 IP 评论间隔 |
| `MONITOR_INTERVAL` | `300` 秒 | 服务探活周期 |
| `_LOGIN_MAX_FAILS` | `5` | 锁定前允许失败次数 |
| `_LOGIN_LOCK_SECONDS` | `900` | 锁定时长 |
| `_LOGIN_BASE_DELAY` | `0.5` 秒 | 失败退避基数 |
| `_LOGIN_CAPTCHA_FAILS` | `3` | 第几次失败起要求算术验证码 |
| `_OTP_STEP` | `30` 秒 | TOTP 时间步 |
| `_OTP_DIGITS` | `6` | TOTP 位数 |
| `_OTP_WINDOW` | `1` | TOTP 允许前后偏移步数 |
| `_OTP_RECOVERY_N` | `10` | 恢复码数量 |
| `UPGRADE_MAX_BYTES` | `200 MB` | 升级包下载上限 |
| `UPGRADE_LOCK_TTL` | `600` 秒 | 升级互斥锁 TTL |
| `_THUMB_SIZE` | `(800, 600)` | 分享缩略图尺寸（4:3） |
| `_README_IMG_MAX` | `8 MB` | README 单图下载上限 |
| `_AVATAR_MAX_AGE` | `15 天` | 头像磁盘缓存有效期 |
| 上传单文件 | `20 MB` | `_save_upload` 内判定 |
| 图片最长边 | `1920 px` | 压缩基准 |
| JPEG 质量 | `82` | 压缩基准 |
| 评论内容上限 | `2000` 字 | 前后端双限 |
| 昵称上限 | `30` 字 | |
| 网址上限 | `200` 字 | |

### 0.5 目录树（复刻必须对齐的部分）

```text
project/
├── app.py                  # 唯一后端文件（可拆，但入口名必须为 app:app）
├── requirements.txt
├── gunicorn.conf.py
├── blog.service            # systemd 样例
├── deploy_<domain>.conf    # Nginx 样例
├── posts/                  # 旧版 Markdown 文章（首次迁移后不再读）
├── fonts/
│   └── wqy-microhei.ttc    # 水印中文字体（仓库自带）
├── templates/
│   ├── _footer_text.html
│   ├── admin/              # 24 个后台模板，不参与主题
│   └── <theme>/            # 每个主题一个目录
│       ├── info.json       # {name, author, description, version}
│       ├── theme.css       # 可选，覆盖默认样式
│       ├── theme.js        # 可选
│       ├── preview.png     # 可选，后台预览图
│       └── *.html          # 与 default 同名的页面覆盖
├── static/
│   ├── css/  js/  icons/  images/
│   ├── cache/avatars/      # 头像代理落盘缓存
│   └── vendor/             # font-awesome / highlight.js / qrcode / vditor
├── uploads/                # 运行时上传根（不在 static 下）
│   ├── 2026/09/xxx.jpg
│   ├── .originals/         # 无痕原图（公网不可达）
│   ├── avatar/
│   └── projects/<slug>/readme/
├── data/
│   ├── blog.db  blog.db-wal  blog.db-shm
│   ├── .secret_key
│   ├── .initial_admin_password
│   ├── .otp_disable
│   ├── posts.json          # 旧版数据（迁移源）
│   ├── project_gh_cache.json
│   ├── project_sync_state.json
│   ├── upgrade_cache.json
│   └── share_thumbs/
├── backups/
└── vendor/ip2region/       # 约 48MB 离线 IP 库
```

**硬约束**：

1. `uploads/` 必须在项目根、与 `static/` 平级。放 `static/` 下会被 `theme_static` 与版本指纹扫描污染，且与旧迁移逻辑冲突（**原实现** v1.0.6 起迁移）。
2. `data/` 必须存在且可写。首次启动自动建库，但目录本身不会自动创建（**原实现** `init_db()` 只建表）。
3. `vendor/ip2region/` 缺失时 IP 归属地功能静默降级，不报错——复刻时**建议**保留该降级路径。

### 0.6 路由总表

前台 26 条：

| 方法 | 路径 | 端点 | 说明 |
| --- | --- | --- | --- |
| GET | `/` | `index` | 首页；带 `?tag=`/`?q=` 时切换为筛选列表 |
| GET | `/posts` | `posts_page` | 归档（按年份分组）或筛选 |
| GET | `/post/<int:post_id>` | `post_detail` | 文章详情 |
| POST | `/post/<int:post_id>/view` | `post_view` | 阅读量 +1（`sendBeacon`） |
| POST | `/post/<int:post_id>/comment` | `post_comment` | 文章评论提交 |
| POST | `/projects/<int:project_id>/comment` | `project_comment` | 项目评论提交 |
| GET | `/tags` | `tags` | 标签云 |
| GET | `/about` | `about` | 关于 |
| GET | `/status` | `status_page` | 服务状态页 |
| GET | `/api/status` | `api_status` | 状态 JSON |
| GET | `/projects` | `projects_page` | 项目列表 |
| GET | `/projects/<int:project_id>` | `project_detail` | 项目详情（README） |
| GET | `/links` | `links_page` | 友链 |
| GET/POST | `/links/apply` | `links_apply` | 友链申请 |
| GET | `/search` | `search` | 302 到 `/?q=` |
| GET | `/feed.xml` | `rss_feed` | RSS 2.0 |
| GET | `/uploads/<path:filename>` | `uploaded_file` | 上传文件服务 |
| GET | `/share-thumb/<path:filename>` | `share_thumb` | 4:3 分享缩略图 |
| GET | `/themes/<path:filename>` | `theme_static` | 主题静态资源 |
| GET | `/avatar/<key>/<int:size>.png` | `avatar_proxy` | 头像站内代理 |
| GET | `404` | `not_found` | |
| GET | `500` | `server_error` | |

管理端 13 条（未计 `@admin_required` 子路由）：

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/admin` | 302 到 dashboard 或 login |
| GET/POST | `/admin/login` | 登录（含验证码） |
| GET | `/admin/logout` | 登出（⚠️ GET 可被跨站触发） |
| GET/POST | `/admin/otp` | 二次验证 |
| GET/POST | `/admin/otp/recover` | 恢复码 |
| GET/POST | `/admin/forgot` | 邮件找回 |
| GET | `/admin/otp/setup` | 生成 base32 + otpauth URI |
| POST | `/admin/otp/clear-emergency` | 清除紧急禁用标记 |

其余 44 条后台路由见 §11 完整表。

---

## §1 系统架构

### 1.1 拓扑

```text
             ┌──────────────────────────────────────────────┐
  浏览器 ───▶│ Nginx :443                                   │
             │  /static  /uploads  → alias 直接读磁盘        │
             │  其余              → proxy_pass 127.0.0.1:5000│
             └───────────────────────┬──────────────────────┘
                                     │ X-Forwarded-For / Proto / Host
                          ┌──────────▼───────────┐
                          │ gunicorn (4 × sync)  │
                          │ ProxyFix(x_for=1…)   │
                          └──────────┬───────────┘
                                     │
        ┌────────────────────────────┼─────────────────────────────┐
        │                            │                             │
   ┌────▼─────┐              ┌───────▼────────┐            ┌───────▼────────┐
   │ Flask app │              │ SQLite (WAL)   │            │ 文件系统        │
   │ 83 routes │◀────────────▶│ data/blog.db   │            │ uploads/ data/ │
   └────┬─────┘              └────────────────┘            └───────┬────────┘
        │                                                          │
        │ 后台 daemon 线程                                          │
        ├── 服务探活（300s）───────────────────────────────────────┤ 写 service_checks
        ├── 评论通知 SMTP ────────────────────────────────────────▶ 外部 SMTP
        ├── IP 归属地（ip2region 本地库）───────────────────────────┤ 内存 mmap
        ├── 项目同步（GitHub API + README 图片下载）───────────────▶ api.github.com
        └── 历史图水印重刷（Pillow）───────────────────────────────┤ 读写 uploads/
```

关键事实：

- **Nginx 直接服务** `/static` 与 `/uploads`，不经过 Flask。这意味着上传目录的权限控制只有「路径不可猜」+ 隐藏目录拦截，**没有鉴权**。⚠️ 私密评论可以配置为仅管理员可见，但其头像/附件 URL 仍是公开的。
- **gunicorn 多 worker**：所有进程内状态（登录失败计数、评论冷却、监控线程、水印刷新标记）都是 **per-worker** 的。原实现用「磁盘为权威」缓解了项目同步状态（`project_sync_state.json`）与调价缓存，其余未处理。复刻时若用 4 worker，限流阈值实际是 4×。
- **一个进程内启动一个监控线程**：`_start_monitor_thread()` 只在 `WERKZEUG_RUN_MAIN` 或非 debug 时启动，否则 reloader 会启两份。

### 1.2 单文件内的逻辑分层

上游没有物理分层，但逻辑边界清晰，复刻时可按此拆分模块（**建议**，非必须）：

| 逻辑层 | 上游位置 | 职责 |
| --- | --- | --- |
| 常量与启动 | L1–L380 | 版本、路径、secret、ProxyFix、图标缓存、DB 连接 |
| 主题系统 | L91–L230, L3388 | 主题发现、模板查找链、静态资源、版本指纹 |
| DB 初始化与迁移 | L379–L790 | 建表、补列、表重建、时区迁移、单管理员触发器、JSON 迁移 |
| 设置系统 | L800–L900 | `settings` 表 → `app.config` 全量同步 |
| 安全工具 | L1641–L1930 | 密码校验、防爆破、IP、TOTP、恢复码 |
| 数据访问 | L1933–L2410, L2869–L3370 | `db_*` 函数族 |
| 内容渲染 | L2130–L2204 | Markdown → HTML |
| 外部集成 | L2342–L2870, L1008–L1620, L3123–L3230 | GitHub、云 API、证书、头像代理 |
| 账户/认证路由 | L4306–L4670 | 登录、OTP、找回 |
| 后台路由 | L4651–L6814 | 57 条 |
| 前台路由 | L3517–L4300 | 26 条 |
| 媒体管线 | L5257–L5990 | 压缩、水印、上传、孤儿清理 |
| 导出/升级 | L6302–L6814 | JSON/Markdown/DB、在线升级 |
| 错误处理与响应头 | L3367–L3450 | CSP、HSTS、404/500 |

### 1.3 请求生命周期

```text
请求进入
  │
  ├─ ProxyFix 还原 remote_addr / scheme / host
  │
  ├─ before_request:
  │     load_settings()       # 每次请求把 settings 表全量读进 app.config
  │     _sync_theme_cache()   # 若 active_theme 变化，清 jinja_env.cache
  │
  ├─ 视图函数
  │     get_db()              # 首次调用建连接，挂到 g._db_conn
  │     db_*()                # 复用同一连接
  │
  ├─ context_processor: inject_globals()
  │     注入 30+ 变量（站点信息、导航、主题、标签、友链…）
  │
  ├─ 模板渲染（ThemeLoader 三级查找）
  │
  ├─ after_request: _security_headers()
  │     CSP / X-Frame-Options / nosniff / Referrer-Policy / HSTS(仅 https)
  │
  └─ teardown_appcontext: _close_db()   # 关闭 g 上的连接
```

**为什么 `load_settings()` 放在 `before_request` 而不是缓存**：站点设置改动要在**下一次请求**立即生效，且必须对多 worker 生效。SQLite 单表全量读的成本（约 45 行）远低于维护跨进程失效通知的复杂度。这是刻意用性能换正确性的取舍。

**⚠️ 每请求一次全表 SELECT**：在 QPS 高的场景是明显浪费。复刻时若想优化，**必须**保证后台保存设置后能主动失效（例如 `settings.updated_at` 版本号 + 进程内 TTL），否则会退化成「改设置不生效」。

### 1.4 信任边界

| 边界 | 内 | 外 | 控制手段 |
| --- | --- | --- | --- |
| 公网 ↔ Nginx | 服务器 | 任意客户端 | TLS、`client_max_body_size 20m` |
| Nginx ↔ Flask | 可信代理 | — | `ProxyFix(x_for=1)`，只信任一层 |
| Flask ↔ SQLite | 应用 | — | 参数化 SQL；`foreign_keys=ON`；单管理员触发器 |
| Flask ↔ 文件系统 | 应用 | — | 扩展名白名单、路径归一校验、拒绝隐藏目录 |
| 管理员 ↔ 后台 | `session['admin_logged_in']` | 匿名 | `@admin_required` + 可选 TOTP |
| 应用 ↔ 第三方 | GitHub/SMTP/云 API | — | HTTPS + 可选 Token；失败静默降级 |

**没有 CSRF token**。所有写操作依赖 `SameSite=Lax` Cookie。这意味着跨站 `POST` 表单默认不带 Cookie（Lax 只允许顶层 GET 导航携带），但**同站 XSS 或子域**可绕过。见 §16。

### 1.5 复刻时的架构取舍

| 选项 | 结论 |
| --- | --- |
| 拆蓝图 | **建议**拆（`auth` / `admin` / `public` / `media`），但 URL 与端点名必须保持不变，否则模板里的 `url_for` 全崩 |
| 上 ORM | **不建议**。上游大量依赖 SQLite 特性（`INSERT OR IGNORE`、触发器、`PRAGMA table_info`、`COALESCE(?, col)`），ORM 会引入行为差异 |
| 上 Redis | 仅在多机部署时需要；单机单进程用进程内字典即可 |
| 上 Celery | **不建议**。上游所有后台任务都是 daemon 线程 + 落盘状态，够用且零运维 |
| 换 PostgreSQL | 可行但需重写 4 处：`INSERT OR IGNORE`、`PRAGMA`、`AUTOINCREMENT`、触发器语法 |

### 1.6 实现陷阱

1. **`before_request` 里不要开数据库连接做重活**。上游只做 `load_settings()`（一次 SELECT）与主题缓存比对。
2. **`context_processor` 在模板加载之后才执行**——所以「换主题清 Jinja 缓存」**必须**放在 `before_request`，放 context_processor 已经来不及（模板已按旧主题解析）。
3. **`ProxyFix` 的 `x_for=1` 是安全前提**。若站点前面有两层代理（CDN + Nginx），必须改成 `x_for=2` 并确保最外层剥离客户端伪造头，否则 IP 可伪造，进而绕过登录限流与评论冷却。
4. **不要在 `after_request` 里读 `request.form`**，会触发 413/400 之外的解析异常。

---

## §2 从零跑起来（最小可运行复刻）

本章目标：**30 分钟内得到一个能登录、能发文章、能评论的站点**。后续章节再补齐项目页、状态页、升级等。

### 2.1 环境

- Python **3.8+**（上游未使用 3.9+ 语法；`zoneinfo` 未使用，时区靠 `timedelta(hours=8)` 硬编码）
- Linux / macOS / Windows 均可开发；生产建议 Linux
- 无 Node、无构建步骤、无 CDN 依赖（vendor 全部本地化）

### 2.2 步骤

```bash
# 1. 取代码
git clone https://github.com/Contribuv/infowe_blog.git
cd infowe_blog

# 2. 建虚拟环境
python3 -m venv venv
source venv/bin/activate          # Windows: venv\Scripts\activate

# 3. 装依赖
pip install -r requirements.txt

# 4. 准备目录（必须）
mkdir -p data uploads backups

# 5. 启动（开发）
python app.py
# → http://127.0.0.1:5000
```

首次启动会发生：

1. `init_db()` 建 10 张表、建索引、跑迁移；
2. `users` 表为空时创建 `admin`，密码为 `secrets.token_hex(8)`（16 位十六进制）；
3. 密码同时打印到 stdout 并写入 `data/.initial_admin_password`（权限 600）；
4. 写入约 45 条 `settings` 默认值；
5. `migrate_from_json()` 检查 `data/posts.json`，存在且 `posts` 表为空时导入文章；
6. 启动监控线程（首次探活要等 300 秒后才写第二条，但启动时会立即跑一轮）。

**⚠️ 找不到初始密码**：只能删 `data/blog.db` 重来，或用 `sqlite3` 手动重置 `users.password_hash`（见 §18.4）。

### 2.3 首次登录必须做的三件事

1. 用 `admin` + `.initial_admin_password` 登录 `/admin/login`；
2. **立刻改密码**（后台 → 设置 → 账号），改完 `.initial_admin_password` 自动删除；
3. 配置 `BLOG_SECRET_KEY`（生产必须），否则换机器/删 `data/.secret_key` 会导致所有 session 失效。

### 2.4 生产部署（Nginx + gunicorn + systemd）

**gunicorn**（`gunicorn.conf.py`）：

```python
bind = "127.0.0.1:5000"
workers = int(os.environ.get("GUNICORN_WORKERS", "4"))
worker_class = "sync"
max_requests = 1000
max_requests_jitter = 50
timeout = 60
graceful_timeout = 30
keepalive = 5
accesslog = "-"
errorlog = "-"
loglevel = "info"
pidfile = "gunicorn.pid"
reload = False
```

**systemd**（`blog.service`）：

```ini
[Unit]
Description=infowe.site Flask Blog (gunicorn)
After=network.target

[Service]
WorkingDirectory=/var/www/infowe.site
User=www-data
Group=www-data
Environment=BLOG_SECRET_KEY=<64位随机串>
Environment=FLASK_DEBUG=0
Environment=GUNICORN_WORKERS=4
ExecStart=/var/www/infowe.site/venv/bin/gunicorn -c gunicorn.conf.py app:app
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

**Nginx**：

```nginx
server {
    listen 80;
    server_name example.com www.example.com;

    client_max_body_size 20m;

    location /static {
        alias /var/www/infowe.site/static;
        expires 30d;
        access_log off;
    }
    location /uploads {
        alias /var/www/infowe.site/uploads;
        expires 30d;
        access_log off;
    }
    location / {
        proxy_pass http://127.0.0.1:5000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $host;
        proxy_redirect off;
        proxy_connect_timeout 60s;
        proxy_read_timeout 60s;
    }
}
```

**⚠️ 目录权限**：`data/`、`uploads/`、`backups/` 必须对运行用户可写；`templates/`、`static/` 只读即可。在线升级功能需要**代码目录可写**——这与最小权限原则冲突，见 §16.6。

### 2.5 上线检查清单

- [ ] `BLOG_SECRET_KEY` 已设置且长度 ≥ 32
- [ ] `FLASK_DEBUG=0`（或未设置）
- [ ] `data/` `uploads/` `backups/` 可写
- [ ] `vendor/ip2region/` 存在（否则状态页 IP 归属地为空）
- [ ] `fonts/wqy-microhei.ttc` 存在（否则中文水印变方块）
- [ ] Nginx `client_max_body_size` ≥ 20m
- [ ] Nginx 透传 `X-Forwarded-For` / `X-Forwarded-Proto`
- [ ] HTTPS 已启用（否则 HSTS 不生效、session Secure 不生效）
- [ ] 初始密码已改，`data/.initial_admin_password` 已消失
- [ ] 后台 → 设置 → 检查更新，确认 `VERSION` 与上游一致
- [ ] 备份策略已配置（见 §18.2）

### 2.6 实现陷阱

1. **不要用 `python app.py` 跑生产**。`__main__` 里 `host='0.0.0.0'`，且 `FLASK_DEBUG=1` 时会开 debugger（可执行任意代码）。
2. **`workers` 不要盲目调大**。每个 worker 都会启一个探活线程、各有一份头像/项目缓存；4 个是原实现的甜点。
3. **`max_requests=1000` 会周期性重启 worker**，进程内的项目同步状态会丢——上游用 `project_sync_state.json` 兜底，复刻时必须保留该落盘逻辑。
4. **Windows 下 `os.chmod(0o600)` 无效**，上游用 `try/except (OSError, NotImplementedError)` 吞掉。不要把「密钥文件权限」当成安全保证。

---

## §3 配置与启动入口

### 3.1 路径常量

```python
BASE_DIR   = os.path.dirname(os.path.abspath(__file__))
DB_PATH    = os.path.join(BASE_DIR, 'data', 'blog.db')
POSTS_DIR  = os.path.join(BASE_DIR, 'posts')
DATA_FILE  = os.path.join(BASE_DIR, 'data', 'posts.json')
ICONS_DIR  = os.path.join(BASE_DIR, 'static', 'icons')
UPLOAD_DIR = os.path.join(BASE_DIR, 'uploads')
OLD_UPLOAD_DIR = os.path.join(BASE_DIR, 'static', 'uploads')
```

`TEMPLATE_DIR` 因为要在 `BASE_DIR` 之前使用，上游单独用 `__file__` 推导：

```python
TEMPLATE_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'templates')
```

**⚠️ 顺序陷阱**：`THEME` 相关函数在模块顶部定义，但依赖 `TEMPLATE_DIR`；`BASE_DIR` 在 L235 才定义。复刻时若把常量集中到一个 `config.py`，注意 `secret_key` 的生成逻辑依赖 `BASE_DIR`，必须晚于它执行。

### 3.2 secret_key 三级策略

```python
_secret_file = os.path.join(BASE_DIR, 'data', '.secret_key')
if os.environ.get('BLOG_SECRET_KEY'):
    app.secret_key = os.environ['BLOG_SECRET_KEY']           # ① 环境变量
elif os.path.isfile(_secret_file):
    app.secret_key = open(_secret_file).read().strip()       # ② 已落盘
else:
    _generated = secrets.token_hex(32)                       # ③ 生成并落盘
    os.makedirs(os.path.dirname(_secret_file), exist_ok=True)
    open(_secret_file, 'w').write(_generated)
    os.chmod(_secret_file, 0o600)                            # 尽力而为
    app.secret_key = _generated
```

**必须**保留「落盘」这一步。若每次启动随机生成，gunicorn 多 worker 会各自持有不同密钥，session 随机失效。

**⚠️ 历史缺陷**：v1.3.56 之前源码里硬编码了 secret_key，且初始密码固定为 `admin123`。复刻时不要「为了省事」写死。

### 3.3 上传扩展名白名单

```python
ALLOWED_IMAGE_EXT = {'.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp', '.heic', '.heif'}
ALLOWED_MEDIA_EXT = {'.mp4', '.webm', '.ogg', '.mov', '.avi'}
ALLOWED_FILE_EXT  = {'.zip', '.rar', '.pdf', '.doc', '.docx', '.xls', '.xlsx',
                     '.ppt', '.pptx', '.txt', '.md', '.py', '.js', '.json'}
```

**⚠️ 刻意排除 `.svg`**：SVG 可内嵌 `<script>`，在同源 `/uploads/` 下打开即存储型 XSS。这是原实现的明确取舍（注释写在 L242）。若业务确实需要 SVG，必须单独走「强制 `Content-Disposition: attachment` + `Content-Security-Policy: sandbox`」的下载路由。

### 3.4 ProxyFix

```python
app.wsgi_app = ProxyFix(app.wsgi_app, x_for=1, x_proto=1, x_host=1, x_port=1)
```

四个参数都要开：

- `x_for` → `request.remote_addr` 变真实 IP（评论归属地、限流依赖它）
- `x_proto` → `request.is_secure` 正确（HSTS 与 Secure Cookie 依赖它）
- `x_host` / `x_port` → `url_for(_external=True)` 生成的绝对 URL 正确（分享图、RSS、邮件链接依赖它）

### 3.5 图标内联缓存

```python
_ICON_CACHE = {}
def _load_icons():
    for fname in os.listdir(ICONS_DIR):
        if fname.endswith('.svg'):
            _ICON_CACHE[fname[:-4]] = open(...).read().strip()

def icon_svg(name, size=20, class_name=''):
    raw = _ICON_CACHE.get(name, '')
    if not raw: return ''
    svg = raw.replace('width="24"', f'width="{size}"').replace('height="24"', f'height="{size}"')
    if class_name: svg = svg.replace('<svg', f'<svg class="{class_name}"', 1)
    return svg

app.jinja_env.globals['icon'] = icon_svg
```

模板里 `{{ icon('home', 18, 'nav-icon') | safe }}`。**必须** `| safe`，否则 SVG 被转义成文本。

**⚠️ 替换 `width="24"` 的脆弱性**：图标必须严格带 `width="24" height="24"` 属性，否则尺寸参数无效。复刻时建议改成正则替换 `<svg[^>]*>` 内的宽高。

### 3.6 settings 全量表

`settings` 是唯一配置源。`load_settings()` 把每一行塞进 `app.config[key]`，因此模板/代码里统一用 `app.config.get(key, default)`。

| 分组 | key | 默认值 | 说明 |
| --- | --- | --- | --- |
| 站点 | `blog_name` | `infowe` | 站点名 |
| | `blog_subtitle` | `Python · Code · Life` | 副标题 |
| | `author` | `Linus` | 博主名 |
| | `author_bio` | 多行文本 | 侧栏简介 |
| | `about_intro` | 一段话 | 关于页导语 |
| | `avatar` | `''` | 头像 URL（`/uploads/...`） |
| | `home_title` | `''` | 首页大标题（空则用 blog_name） |
| | `home_posts_count` | `6` | 首页文章条数 |
| | `posts_per_page` | `20` | 列表分页 |
| 社交 | `github_username` | `''` | 关于页展示 |
| | `social_github` | `''` | 链接 |
| | `contact_email` | `''` | 联系邮箱 |
| | `github_token` | `''` | GitHub API Token（提升限额） |
| 技能 | `skills` | 7 项 JSON | `[{"name","level"}]` |
| 评论 | `comments_enabled` | `1` | 全局评论开关 |
| | `comment_notify` | `1` | 邮件通知开关 |
| | `smtp_host` | `''` | |
| | `smtp_port` | `465` | 465 走 SSL，其他走 STARTTLS |
| | `smtp_user` | `''` | |
| | `smtp_pass` | `''` | ⚠️ 明文存储 |
| | `smtp_sender_name` | `''` | 空则用 blog_name |
| | `notify_email` | `''` | 博主邮箱；评论者邮箱等于它即免审核 |
| 导航 | `nav_posts` `nav_tags` `nav_projects` `nav_links` `nav_status` `nav_about` | 均 `1` | 关闭后对应页面 404 |
| 备案 | `icp_beian` | `''` | ICP 号 |
| | `police_beian` | `''` | 公安备案号 |
| 统计 | `stats_code` | `''` | 统计脚本，消毒后注入 `</body>` 前 |
| 云 | `aliyun_access_key` / `aliyun_access_secret` / `aliyun_region` / `aliyun_instance_id` | 空 / `cn-hangzhou` | 阿里云到期查询 |
| | `tencent_secret_id` / `tencent_secret_key` / `tencent_domain` | 空 | 腾讯云域名到期 |
| | `expiry_aliyun` / `expiry_tencent` | 空 | 手动兜底日期 |
| 监控 | `monitor_services` | `[]` | `[{"id","name","url"}]` JSON |
| 水印 | `watermark_enabled` | `1` | |
| | `watermark_text` | `''` | 空则「站点名 · 域名」 |
| | `watermark_position` | `br` | `br/bl/tr/tl/bc` |
| | `watermark_size` | `m` | `s/m/l` |
| 主题 | `active_theme` | 不存在 | 缺失即用 `default` |
| 迁移 | `schema_version` | 不存在 | 见 §4.6 |

**⚠️ `active_theme` 的特殊处理**：`load_settings()` 末尾若发现该 key 指向不存在的主题，会 `config.pop('active_theme')` 而不是保留脏值。复刻时必须做同样的事，否则 `ThemeLoader` 回退链会每请求多一次 stat。

### 3.7 会话配置

```python
app.config.update(
    SESSION_COOKIE_SAMESITE='Lax',
    SESSION_COOKIE_HTTPONLY=True,
    SESSION_COOKIE_SECURE=not app.debug,      # 生产 True
    PERMANENT_SESSION_LIFETIME=3600,
)
```

**⚠️ `PERMANENT_SESSION_LIFETIME` 实际不生效**：上游从未设置 `session.permanent = True`，所以 Cookie 仍是浏览器会话级（关浏览器即失效）。该配置是「写了但没用」。复刻时二选一：要么显式 `session.permanent = True` 让 1 小时生效，要么删掉该配置避免误导。

### 3.8 响应头

```python
@app.after_request
def _security_headers(resp):
    resp.headers['Content-Security-Policy'] = (
        "default-src 'self'; "
        "img-src 'self' data: https:; "
        "script-src 'self' 'unsafe-inline' https:; "
        "style-src 'self' 'unsafe-inline' https:; "
        "font-src 'self' data: https:; "
        "object-src 'none'; base-uri 'self'; frame-ancestors 'none'")
    resp.headers['X-Frame-Options'] = 'SAMEORIGIN'
    resp.headers['X-Content-Type-Options'] = 'nosniff'
    resp.headers['Referrer-Policy'] = 'strict-origin-when-cross-origin'
    resp.headers['Permissions-Policy'] = 'unload=*'
    if request.is_secure:
        resp.headers['Strict-Transport-Security'] = 'max-age=31536000; includeSubDomains'
    return resp
```

**⚠️ CSP 的 `'unsafe-inline'` 是被迫的**：模板里有大量内联 `<script>`（主题防闪烁、阅读进度、微信分享初始化），去掉会白屏。这意味着 CSP 对 XSS 的实际防护接近于零，只剩 `frame-ancestors` / `object-src` 的价值。见 §16.4。

**⚠️ `Permissions-Policy: unload=*`** 是反向用法：默认 `unload` 被禁用，这里显式放开，因为 `main.js` 用 `unload` 做清理。复刻时若改用 `pagehide`，可删掉该头。

### 3.9 实现陷阱

1. **`load_settings()` 必须在每次请求前跑**，且在 `inject_globals()` 里再跑一次（上游两处都调）。后者是为了 `context_processor` 在直接 `render_template` 场景（错误页）也能拿到配置。
2. **`app.config` 与 `settings` 表可能不一致**：后台保存时是「先写表、再同步 `app.config`」。若写表成功、同步前进程崩溃，会出现「重启后才生效」。复刻时保持这个顺序（先持久化，再内存）。
3. **布尔值全部用字符串 `'1'`/`'0'` 存**。Python 里 `bool('0')` 是 `True`——这就是 v1.3.63 修的 OTP 开关 bug。所有布尔读取必须写 `str(v).strip().lower() in ('1','on','true','yes')`。
4. **`stats_code` 必须消毒**。它被 `| safe` 注入页面，等价于「管理员可执行任意 JS」。上游用 `_sanitize_stats_code()` 白名单过滤 `<script>`，但这是启发式，不是安全边界——所以它只允许管理员改。

---

## §4 数据模型

### 4.1 连接管理

```python
def _new_db_conn():
    conn = sqlite3.connect(DB_PATH, timeout=15)
    conn.row_factory = sqlite3.Row
    conn.execute('PRAGMA foreign_keys=ON')
    conn.execute('PRAGMA busy_timeout=15000')
    return conn

def get_db():
    if has_app_context():
        conn = g.get('_db_conn')
        if conn is None or not _conn_alive(conn):
            conn = _new_db_conn()
            g._db_conn = conn
        return conn
    return _new_db_conn()

@app.teardown_appcontext
def _close_db(exc):
    db = g.pop('_db_conn', None)
    if db: db.close()
```

三条硬规则：

1. **每个连接都开 `foreign_keys=ON`**。SQLite 默认关闭外键，不显式开启则 `ON DELETE CASCADE` 完全不生效。
2. **`journal_mode=WAL` 只在 `init_db()` 里设一次**，不在 `_new_db_conn()` 里设。WAL 是数据库级持久属性；每次连接都执行该 PRAGMA 需要拿写锁，高并发下会抛 `database is locked`。
3. **不在请求上下文时，调用方负责 `close()`**。上游的 `db_load_links` 等函数用 `has_request_context()` 判断，后台线程里用完即关。

**⚠️ `_conn_alive(conn)`**：上游用一个轻量探针（`SELECT 1` 或 `conn.execute` 捕获异常）判断连接是否被 WAL checkpoint 或异常关闭。复刻时若省略，长请求中连接被回收会导致 `ProgrammingError: Cannot operate on a closed database`。

### 4.2 十张表

#### posts

| 列 | 类型 | 默认 | 说明 |
| --- | --- | --- | --- |
| `id` | INTEGER PK AUTOINCREMENT | | |
| `title` | TEXT NOT NULL | | 标题 |
| `slug` | TEXT UNIQUE NOT NULL | | URL 标识，自动生成去重 |
| `content` | TEXT NOT NULL | `''` | Markdown 原文 |
| `excerpt` | TEXT | `''` | 摘要；空则渲染时截取 |
| `tags` | TEXT | `'[]'` | JSON 数组字符串 |
| `cover` | TEXT | `''` | 封面图 URL |
| `read_time` | INTEGER | `3` | 分钟，`max(1, words//200)` |
| `views` | INTEGER | `0` | 阅读量（迁移列） |
| `status` | TEXT | `'published'` | `published` / `draft` |
| `created_at` | TIMESTAMP | `CURRENT_TIMESTAMP` | ⚠️ 实际写入用 `_now()`（CST） |
| `updated_at` | TIMESTAMP | `CURRENT_TIMESTAMP` | 同上 |
| `is_featured` | INTEGER | `0` | 迁移列，置顶/精选 |
| `category_id` | INTEGER | `NULL` | 迁移列，外键逻辑关联 |

**`tags` 的存储格式是 JSON 字符串**，查询靠 `LIKE '%"tag"%'`。这是一种反范式设计：优点是零关联表，缺点是标签名含 `"` 会破坏匹配、大小写敏感、无法走索引。

#### settings

| 列 | 类型 | 说明 |
| --- | --- | --- |
| `key` | TEXT PK | |
| `value` | TEXT NOT NULL | 一律字符串 |

#### users

| 列 | 类型 | 说明 |
| --- | --- | --- |
| `id` | INTEGER PK | |
| `username` | TEXT UNIQUE NOT NULL | 2–30 位，`^[a-zA-Z0-9_\u4e00-\u9fff-]{2,30}$` |
| `password_hash` | TEXT NOT NULL | `pbkdf2:sha256:...` |

配套触发器（**必须在迁移 v3 中创建**）：

```sql
CREATE TRIGGER IF NOT EXISTS users_single_admin_guard
BEFORE INSERT ON users
WHEN (SELECT COUNT(*) FROM users) >= 1
BEGIN
    SELECT RAISE(ABORT, '博客仅支持单个管理员账号（users 表已有账号，禁止新增）');
END;
```

#### projects

| 列 | 类型 | 默认 |
| --- | --- | --- |
| `id` | INTEGER PK | |
| `name` | TEXT NOT NULL | |
| `description` | TEXT | `''` |
| `url` | TEXT | `''` |
| `stars` | INTEGER | `0` |
| `language` | TEXT | `''` |
| `topics` | TEXT | `'[]'` |
| `sort_order` | INTEGER | `0` |
| `featured` | INTEGER | `0` |
| `github_repo` | TEXT | `''` 迁移列 |
| `custom_name` | INTEGER | `0` 迁移列：名字被自定义，同步时不覆盖 |
| `languages` | TEXT | `'[]'` 迁移列：`[[name, pct], ...]` |
| `created_at` | TIMESTAMP | |

**⚠️ 没有 `updated_at`**。`admin_dashboard` 里 `recent = sorted(posts, key=lambda x: x['updated_at'])` 只用于 `posts`，项目页不要照抄。

#### links

| 列 | 类型 | 默认 |
| --- | --- | --- |
| `id` | INTEGER PK | |
| `name` | TEXT NOT NULL | |
| `url` | TEXT NOT NULL | |
| `description` | TEXT | `''` |
| `avatar` | TEXT | `''` |
| `sort_order` | INTEGER | `0` |
| `status` | TEXT | `'approved'` |
| `created_at` | TIMESTAMP | |

#### comments

| 列 | 类型 | 默认 | 说明 |
| --- | --- | --- | --- |
| `id` | INTEGER PK | | |
| `post_id` | INTEGER | `NULL` | 与 `project_id` 二选一 |
| `project_id` | INTEGER | `NULL` | |
| `parent_id` | INTEGER | `NULL` | 盖楼 |
| `author` | TEXT NOT NULL | `'Anonymous'` | 昵称 |
| `email` | TEXT | `''` | 明文邮箱，仅用于回复通知，**不出现在任何页面** |
| `email_hash` | TEXT | `''` | md5(小写邮箱)，用于头像/Cravatar |
| `website` | TEXT | `''` | |
| `content` | TEXT NOT NULL | | 纯文本（不渲染 Markdown） |
| `status` | TEXT | `'pending'` | `pending` / `approved` / `rejected` |
| `is_private` | INTEGER | `0` | 仅管理员可见 |
| `qq` | TEXT | `''` | 从 QQ 邮箱提取，用于 qlogo 头像 |
| `ip_text` | TEXT | `''` | 原始 IP |
| `ip_location` | TEXT | `''` | 省份，后台线程回填 |
| `created_at` | TIMESTAMP | | |

外键：`FOREIGN KEY (post_id) REFERENCES posts(id) ON DELETE CASCADE`。

**⚠️ `project_id` 没有外键**。删项目时上游在 `db_delete_project()` 里显式 `DELETE FROM comments WHERE project_id=?`，不能依赖级联。

#### timeline / memories / categories / service_checks

```sql
CREATE TABLE timeline (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  date TEXT NOT NULL,
  content TEXT NOT NULL,
  sort_order INTEGER DEFAULT 0,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE memories (            -- 建表但前台未使用，属预留
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  title TEXT NOT NULL DEFAULT '',
  text  TEXT NOT NULL DEFAULT '',
  image TEXT NOT NULL DEFAULT '',
  date  TEXT DEFAULT '',
  sort_order INTEGER DEFAULT 0,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE categories (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  slug TEXT UNIQUE NOT NULL,
  sort_order INTEGER DEFAULT 0,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE service_checks (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  service_id TEXT NOT NULL,
  checked_at REAL NOT NULL,          -- unix 秒
  ok INTEGER NOT NULL DEFAULT 0,
  latency_ms INTEGER DEFAULT 0,
  cert_days INTEGER DEFAULT -1,      -- -1 表示无证书/未检测
  detail TEXT DEFAULT ''
);
CREATE INDEX idx_service_checks ON service_checks (service_id, checked_at);
```

**⚠️ 索引缺失**：除 `idx_service_checks` 外全库无二级索引。`posts(status, created_at)`、`comments(post_id, status)`、`comments(project_id, status)`、`links(status)` 在数据量上万后会全表扫描。复刻时**建议**补上，不影响语义：

```sql
CREATE INDEX IF NOT EXISTS idx_posts_status_time ON posts(status, created_at);
CREATE INDEX IF NOT EXISTS idx_comments_post ON comments(post_id, status);
CREATE INDEX IF NOT EXISTS idx_comments_project ON comments(project_id, status);
CREATE INDEX IF NOT EXISTS idx_links_status ON links(status, sort_order);
```

### 4.3 时区约定

**全库时间统一为 CST（UTC+8）字符串**，格式 `YYYY-MM-DD HH:MM:SS`。

```python
def _now():
    return datetime.now().strftime('%Y-%m-%d %H:%M:%S')
```

**必须**在所有 `INSERT`/`UPDATE` 中显式传 `_now()`，不要依赖 `DEFAULT CURRENT_TIMESTAMP`（那是 UTC）。上游在 `db_save_comment` 等函数里显式写时间，就是为了避免新老数据混时区。

### 4.4 迁移三手法

上游没有迁移框架，靠三种幂等手法叠加：

**手法一：`CREATE TABLE IF NOT EXISTS` + 逐列探针**

```python
try:
    db.execute("SELECT is_featured FROM posts LIMIT 1")
except sqlite3.OperationalError:
    db.execute("ALTER TABLE posts ADD COLUMN is_featured INTEGER DEFAULT 0")
```

用 `LIMIT 1` 而不是 `PRAGMA table_info`，因为前者在空表上也会因列不存在而报错，且更短。缺点：列存在但表为空时也能通过，符合预期。

**手法二：`PRAGMA table_info` + 批量补列**（`_migrate_comments`）

```python
cols = {r['name'] for r in db.execute("PRAGMA table_info(comments)")}
for name, ddl in [('parent_id', 'INTEGER DEFAULT NULL'), ('email', "TEXT DEFAULT ''"), ...]:
    if name not in cols:
        db.execute(f"ALTER TABLE comments ADD COLUMN {name} {ddl}")
```

**⚠️ `ALTER TABLE ADD COLUMN` 不能加 `NOT NULL`（无默认值）**，也不能改约束。

**手法三：建新表 → 拷交集列 → 删旧表 → 改名**

用于「放宽 `post_id NOT NULL`」这种 SQLite 无法直接改的约束：

```python
info = db.execute("PRAGMA table_info(comments)").fetchall()
post_col = next(r for r in info if r['name'] == 'post_id')
if post_col and post_col['notnull']:
    new_cols = ('id','post_id','project_id','parent_id','author','email','email_hash',
                'website','content','status','is_private','qq','ip_text','ip_location','created_at')
    old_cols = {r['name'] for r in info}
    copy = [c for c in new_cols if c in old_cols]     # 取交集，兼容手工加列
    cols_sql = ', '.join('"%s"' % c for c in copy)
    db.execute("CREATE TABLE comments_rebuild (...)")
    db.execute(f"INSERT INTO comments_rebuild ({cols_sql}) SELECT {cols_sql} FROM comments")
    db.execute("DROP TABLE comments")
    db.execute("ALTER TABLE comments_rebuild RENAME TO comments")
```

四条要点：

1. **幂等判断用 `PRAGMA notnull`**，不要用 `schema_version`（表重建可能被中途打断）。
2. **交集拷贝**：老库可能有手工加的列，新表没有；直接 `SELECT *` 会列数不匹配。
3. **重建前先 `DROP TABLE IF EXISTS comments_rebuild`**，避免上次中断留下残表。
4. **重建会丢索引与触发器**，重建后要补。

### 4.5 `schema_version` 控制的一次性迁移

| 版本 | 迁移内容 |
| --- | --- |
| `< 2` | UTC → CST（+8h）：`posts.created_at` 跳过 `' 12:00:00'`（Hexo 导入占位），其余表全量平移 |
| `< 3` | 单管理员：多于 1 条时保留 `id` 最小者，删其余；创建 `users_single_admin_guard` 触发器 |

```python
_ver = int(db.execute("SELECT value FROM settings WHERE key='schema_version'").fetchone()[0])
if _ver < 2:
    ...
    db.execute("INSERT OR REPLACE INTO settings (key,value) VALUES ('schema_version','2')")
if _ver < 3:
    ...
    db.execute("INSERT OR REPLACE INTO settings (key,value) VALUES ('schema_version','3')")
```

**⚠️ 时区迁移的取舍**：`' 12:00:00'` 跳过是启发式规则。若你的历史数据里真有 12:00:00 的 UTC 时间，会被误判为「本地占位」而不平移。复刻时若数据源可控，**建议**改成「只迁移 `created_at` 与 `updated_at` 相差 0 秒且年份早于某阈值」的规则，或直接不做迁移。

### 4.6 旧 JSON 迁移

```python
def migrate_from_json(db):
    if db.execute("SELECT COUNT(*) FROM posts").fetchone()['c'] > 0:
        return
    if not os.path.isfile(DATA_FILE):
        return
    for item in json.load(open(DATA_FILE, encoding='utf-8')):
        db.execute("INSERT INTO posts (...) VALUES (...)", (...))
```

只在 `posts` 表为空时执行，避免重复导入。**⚠️ 上游此函数还会把 `data/posts.json` 里的评论一并导入**；复刻时若不需要兼容老数据，可以整段删掉，但**必须**保留「`posts` 表为空才导」的幂等判断习惯。

### 4.7 实现陷阱

1. **`sqlite3.Row` 不支持 `.get()`**。上游用 `row_to_dict()` 转换后再用。复刻时若直接 `row.get('x')` 会 `AttributeError`。
2. **`db.commit()` 的粒度**：上游大量「一个函数一次 commit」。批量删除 1000 条评论时是 1000 次 commit，慢但简单。**建议**改为单事务，但要注意失败回滚语义。
3. **`posts.tags` 的 `LIKE` 查询对大小写敏感**（SQLite `LIKE` 默认对 ASCII 不敏感、对中文敏感）。标签统一小写可规避。
4. **删除文章时外键级联只删 `comments`**，不删磁盘文件。文件清理在 `db_delete_post()` 里单独做，且**必须**比对「是否还有其他文章引用同一 URL」（见 §7.6）。
5. **`categories` 删除后 `posts.category_id` 不会自动置空**（没建外键）。上游在 `db_delete_category()` 里先 `UPDATE posts SET category_id=NULL`，复刻时不能省。

---

## §5 请求生命周期与数据访问层

### 5.1 `before_request`

```python
@app.before_request
def _before_theme_sync():
    load_settings()
    _sync_theme_cache()
```

`load_settings()`：

```python
def load_settings():
    db = _request_db()
    for row in db.execute("SELECT key, value FROM settings").fetchall():
        app.config[row['key']] = row['value']
    if 'active_theme' in app.config and not os.path.isdir(
            os.path.join(TEMPLATE_DIR, app.config['active_theme'])):
        app.config.pop('active_theme')
```

`_sync_theme_cache()`：

```python
_LAST_THEME_KEY = [None]

def _sync_theme_cache():
    key = _active_theme_key()
    if _LAST_THEME_KEY[0] != key:
        _LAST_THEME_KEY[0] = key
        app.jinja_env.cache.clear()      # 换主题必须清，否则旧模板命中
```

**⚠️ 为什么用列表 `_LAST_THEME_KEY = [None]` 而不是全局变量**：避免 `global` 声明，在多处引用时少踩作用域坑。功能等价。

**⚠️ 清缓存必须放在 `before_request`**：Jinja 在 `render_template` 时按名字取模板，`context_processor` 在那之后才执行。

### 5.2 数据访问层约定

上游所有 `db_*` 函数遵循统一签名风格：

```python
def db_load_posts(tag=None, search=None, status='published', page=1, per_page=None):
    per_page = per_page or int(app.config.get('posts_per_page', 20))
    in_request = has_request_context()
    db = _request_db()
    where, params = [], []
    if status:
        where.append("status=?")
        params.append(status)
    if tag:
        where.append("tags LIKE ?")
        params.append(f'%"{tag}"%')
    if search:
        where.append("(title LIKE ? OR content LIKE ?)")
        params += [f'%{search}%', f'%{search}%']
    sql = "SELECT * FROM posts"
    if where:
        sql += " WHERE " + " AND ".join(where)
    total = db.execute("SELECT COUNT(*) FROM posts" + (" WHERE " + " AND ".join(where) if where else ""),
                       params).fetchone()[0]
    sql += " ORDER BY is_featured DESC, created_at DESC LIMIT ? OFFSET ?"
    rows = db.execute(sql, params + [per_page, (page - 1) * per_page]).fetchall()
    ...
```

**必须**保持的行为：

1. **排序固定为 `is_featured DESC, created_at DESC`**。精选区与文章流都依赖它。
2. **`page` 夹紧**：`page = max(1, min(page, total_pages))`。上游在 `posts_page` 里做，`db_load_posts` 里不做——所以越界页返回空列表而非最后一页，取决于调用方。复刻时**建议**统一在视图层夹紧。
3. **`tags` 出库即 `json.loads`**，失败回退 `[]`。
4. **请求内复用 `g` 连接**；非请求上下文 `close()`。

### 5.3 分页

```python
PAGE_SIZE = 20

def _paginate(total, page, per_page):
    total_pages = max(1, math.ceil(total / per_page))
    page = max(1, min(page, total_pages))
    return {'page': page, 'total': total, 'total_pages': total_pages,
            'has_prev': page > 1, 'has_next': page < total_pages}
```

**⚠️ 上游 `tags` 页用 `per_page=99999` 一次拉全量**再在内存分桶。数据量大时（>5k 篇）会卡。复刻时**建议**改成 `GROUP BY` 聚合：

```sql
SELECT value AS tag, COUNT(*) FROM posts, json_each(posts.tags)
WHERE status='published' GROUP BY value ORDER BY COUNT(*) DESC, value;
```

### 5.4 错误处理

```python
@app.errorhandler(404)
def not_found(e):
    return render_template('404.html'), 404

@app.errorhandler(500)
def server_error(e):
    if app.debug:
        raise e
    return render_template('500.html'), 500
```

**⚠️ 错误页模板走主题查找链**：`404.html` 在各主题下都有独立版本（`default/404.html`、`tech/404.html`）。若自定义主题漏了该文件，`ThemeLoader` 会自动回退到 `default/404.html`，不会 500。

**⚠️ `server_error` 里 `raise e`**：debug 模式下把原始异常抛给 Werkzeug debugger。生产必须关闭 debug，否则等于开了一个远程代码执行入口。

### 5.5 实现陷阱

1. **`context_processor` 里不能做网络请求**。上游只读 `UPGRADE_CACHE`（内存/磁盘缓存），并且只在 `/admin` 路径下读，就是怕后台页面卡住。
2. **`inject_globals()` 里调 `db_get_all_tags()` 与 `db_load_links()`**，这是每页两次查询。数据量大时应加进程内缓存 + TTL。
3. **不要给 `settings` 表加 `updated_at` 触发器**，会与 `INSERT OR IGNORE` 默认值逻辑打架。
4. **`g._db_conn` 必须在 `teardown_appcontext` 里 pop 掉**，否则 Flask 上下文复用（如测试客户端）会拿到已关闭连接。

---

## §6 认证与访问控制

### 6.1 密码存储

```python
def hash_password(password):
    return ws.generate_password_hash(password, method='pbkdf2:sha256', salt_length=16)

def verify_password(stored_hash, password):
    if stored_hash.startswith(('pbkdf2:', 'scrypt:', 'bcrypt:')):
        return ws.check_password_hash(stored_hash, password)
    return hashlib.sha256((password + app.secret_key).encode()).hexdigest() == stored_hash
```

**必须**保留旧格式兼容：v1.3.56 之前是 `sha256(password + secret_key)`，无盐。登录成功且检测到旧格式时**懒迁移**：

```python
if not stored_hash.startswith(('pbkdf2:', 'scrypt:', 'bcrypt:')):
    db.execute("UPDATE users SET password_hash=? WHERE id=?",
               (hash_password(password), user['id']))
```

**⚠️ 旧格式的致命点**：`secret_key` 若被更换，所有旧哈希立即失效（无法登录）。上游把 secret 落盘就是为了避免这个。

### 6.2 登录防爆破

状态：进程内字典 `_LOGIN_ATTEMPTS = {ip: {'fails': int, 'lock_until': float}}`。

```python
_LOGIN_MAX_FAILS = 5
_LOGIN_LOCK_SECONDS = 15 * 60
_LOGIN_BASE_DELAY = 0.5
_LOGIN_CAPTCHA_FAILS = 3

def _login_blocked(ip):
    rec = _LOGIN_ATTEMPTS.get(ip)
    return bool(rec and rec.get('lock_until', 0) > time.time())

def _register_fail(ip):
    rec = _LOGIN_ATTEMPTS.setdefault(ip, {'fails': 0, 'lock_until': 0})
    rec['fails'] += 1
    if rec['fails'] >= _LOGIN_MAX_FAILS:
        rec['lock_until'] = time.time() + _LOGIN_LOCK_SECONDS
    delay = _LOGIN_BASE_DELAY * (2 ** min(rec['fails'] - 1, 5))
    time.sleep(min(delay, 16))

def _register_success(ip):
    _LOGIN_ATTEMPTS.pop(ip, None)
```

**必须**的四件事：

1. **指数退避封顶 16 秒**：`0.5 → 1 → 2 → 4 → 8 → 16`，第 6 次起恒 16s。
2. **`time.sleep` 是故意的**，拖慢爆破。⚠️ 它会占住一个 sync worker，攻击者可用 4 个 IP 打满 4 个 worker——这是单进程同步模型的固有代价。
3. **算术验证码**：第 3 次失败起要求 `a + b = ?`，题目与答案存 session。
4. **表上限清理**：`_prune_login_attempts()` 保留最近 2000 条，防内存泄漏（v1.3.56 修复）。

```python
def _gen_captcha():
    a, b = random.randint(1, 9), random.randint(1, 9)
    session['captcha_answer'] = a + b
    session['_captcha_q'] = '%d + %d' % (a, b)
    return session['_captcha_q']
```

**⚠️ 验证码只在「需要且 session 无题」时生成**，否则每次刷新页面都会换题，用户填的旧答案必然错。

### 6.3 登录流程

```text
GET /admin/login
  ├─ 已登录 → 302 /admin/dashboard
  ├─ session['_otp_user'] → 302 /admin/otp
  └─ 渲染登录页（需要验证码则生成题目）

POST /admin/login
  ├─ _login_blocked(ip) → 渲染「已锁定，剩余 N 分钟」
  ├─ 需要验证码 → 比对 session['captcha_answer']，错则 _register_fail
  ├─ 查 users（单管理员，直接 SELECT ... LIMIT 1）
  ├─ verify_password 失败 → _register_fail + 「还可尝试 N 次」
  ├─ 旧哈希 → 懒迁移
  ├─ _register_success(ip)
  ├─ 紧急禁用标记存在（data/.otp_disable）→ 跳过 OTP，直接登录
  ├─ _otp_enabled() → session['_otp_user'] = username，302 /admin/otp
  └─ 否则 session['admin_logged_in'] = True; session['admin_username'] = username
```

`@admin_required`：

```python
def admin_required(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        if not session.get('admin_logged_in'):
            if session.get('_otp_user'):
                return redirect(url_for('admin_otp'))   # 中间态必须回 OTP 页
            return redirect(url_for('admin_login'))
        return f(*args, **kwargs)
    return decorated
```

**⚠️ 中间态重定向是安全关键**：若 `_otp_user` 存在但不重定向，用户可直达任意后台页面，第二因子形同虚设。

### 6.4 TOTP 双因子

自实现 RFC 6238，零依赖：

```python
_OTP_STEP = 30
_OTP_DIGITS = 6
_OTP_WINDOW = 1
_OTP_RECOVERY_N = 10
_OTP_RECOVERY_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'   # 去掉 I/O/0/1 易混字符
_OTP_EMERGENCY_FILE = os.path.join(BASE_DIR, 'data', '.otp_disable')

def _totp_code(secret_b32, ts=None):
    key = base64.b32decode(_b32_pad(secret_b32.upper()))
    counter = int((ts or time.time()) // _OTP_STEP)
    msg = struct.pack('>Q', counter)
    digest = hmac.new(key, msg, hashlib.sha1).digest()
    offset = digest[-1] & 0x0F
    code = (struct.unpack('>I', digest[offset:offset + 4])[0] & 0x7FFFFFFF) % (10 ** _OTP_DIGITS)
    return str(code).zfill(_OTP_DIGITS)

def _totp_verify(secret_b32, code):
    code = str(code or '').strip()
    now = time.time()
    for i in range(-_OTP_WINDOW, _OTP_WINDOW + 1):
        if hmac.compare_digest(_totp_code(secret_b32, now + i * _OTP_STEP), code):
            return True
    return False
```

**必须**的细节：

1. **`_b32_pad`**：base32 长度必须是 8 的倍数，否则 `b32decode` 抛 `Incorrect padding`。
2. **`hmac.compare_digest`** 防时序攻击。
3. **`±1` 窗口**：容忍 30 秒时钟偏差，共 3 个有效码。
4. **紧急逃生阀**：文件存在即强制关闭 OTP。这是给「手机丢了 + 恢复码也丢了」的场景留的后门——⚠️ 意味着**能写服务器文件系统的人可以绕过 2FA**。若你的威胁模型包含「主机被入侵」，这个设计不成立。

`_otp_enabled()` 三重条件（**必须**全满足）：

```python
def _otp_enabled():
    return (str(app.config.get('otp_enabled', '0')).strip() in ('1','on','true','yes')
            and bool(_otp_secret())
            and not _otp_emergency_off())
```

**⚠️ v1.3.63 修的正是这里**：早期写 `if not app.config.get('otp_enabled')`，而 `'0'` 在 Python 是真值，导致 `not '0' == False`，OTP 永远关不掉。

### 6.5 恢复码

```python
def _gen_recovery_codes(n=_OTP_RECOVERY_N):
    codes = [''.join(secrets.choice(_OTP_RECOVERY_ALPHABET) for _ in range(10)) for _ in range(n)]
    # 只存 SHA-256 哈希，明文仅在生成时展示一次
    save_setting('otp_recovery_codes', json.dumps([hashlib.sha256(c.encode()).hexdigest() for c in codes]))
    return codes

def _consume_recovery(code):
    norm = _norm_recovery(code)          # 去空格/连字符、转大写
    h = hashlib.sha256(norm.encode()).hexdigest()
    codes = json.loads(app.config.get('otp_recovery_codes') or '[]')
    if h in codes:
        codes.remove(h)                  # 一次性消费
        save_setting('otp_recovery_codes', json.dumps(codes))
        return True
    return False
```

**⚠️ 恢复码不够 10 个时必须提示重新生成**：`_otp_recovery_remaining()` 用于后台展示剩余数量。

### 6.6 忘记密码

`/admin/forgot`：输入绑定邮箱（`notify_email` 或 `contact_email`），匹配则生成一次性重置 token（存 `settings`，带过期时间），邮件发送重置链接。**必须**做：

- token 用 `secrets.token_urlsafe(32)`；
- 存哈希而非明文；
- 过期时间 30 分钟；
- 使用后立即删除；
- 无论邮箱是否存在都返回同样的提示文案（防用户枚举）。

### 6.7 会话键

| key | 类型 | 生命周期 |
| --- | --- | --- |
| `admin_logged_in` | bool | 登录成功 → `session.clear()` |
| `admin_username` | str | 同上 |
| `_otp_user` | str | 密码通过但 OTP 未完成 |
| `captcha_answer` | int | 单次登录页 |
| `_captcha_q` | str | 同上 |
| `reset_token` | str | 忘记密码流程 |

### 6.8 实现陷阱

1. **`session.clear()` 是登出的唯一正确做法**。只 `pop('admin_logged_in')` 会留下 `_otp_user`，下次访问后台直接跳 OTP 页。
2. **`/admin/logout` 是 GET**（⚠️ 上游如此）。第三方页面放一个 `<img src="https://site/admin/logout">` 就能把管理员登出。复刻时**建议**改成 POST + 表单。
3. **TOTP 密钥存 `settings` 表明文**（`otp_secret`）。数据库泄露 = 2FA 失效。**建议**用 `BLOG_SECRET_KEY` 派生密钥加密存储。
4. **`_LOGIN_ATTEMPTS` 永不持久化**，重启即清零。这在单机场景可接受，但意味着攻击者可以「打满 → 触发重启 → 继续打」。
5. **验证码答案存 session**，而 session 是签名 Cookie。攻击者无法伪造，但可以通过「先 GET 拿题、再 POST」的固定节奏自动化。算术验证码只挡脚本小子。

---

## §7 内容管线

### 7.1 渲染函数

```python
def render_post_content(content):
    """Markdown → (html, toc_html)。toc 无 `<li>` 时返回空串。"""
    if not content:
        return '', ''
    content = re.sub(r'^---.*?---\s*', '', content, flags=re.DOTALL)   # ① 剥 front-matter
    content = normalize_auto_links(content)                             # ② <url> → [url](url)
    content = content.replace('[x]', '<i class="ck ck-done">☑</i> ') \
                     .replace('[ ]', '<i class="ck ck-todo">☐</i> ')    # ③ 任务列表
    md = markdown.Markdown(
        extensions=['fenced_code', 'tables', 'nl2br', 'sane_lists', 'toc',
                    'footnotes', 'attr_list', 'def_list', 'admonition', 'md_in_html'],
        extension_configs={'toc': {'slugify': _toc_slugify, 'toc_depth': '2-6'}},
        output_format='html')
    html = md.convert(content)
    toc = md.toc if '<li>' in md.toc else ''
    html = re.sub(r'<img\b[^>]*>', _img_repl, html)                    # ④ 图片后处理
    html = re.sub(r'<a\b[^>]*>', _a_repl, html)                        # ⑤ 链接后处理
    return html, toc
```

**顺序不能换**：剥 front-matter 必须在 Markdown 之前；`normalize_auto_links` 必须在 `fenced_code` 之前（否则代码块里的 `<https://...>` 也会被替换——⚠️ 上游确实有这个副作用）。

### 7.2 扩展清单与选择理由

| 扩展 | 作用 | 为什么需要 |
| --- | --- | --- |
| `fenced_code` | ```` ``` ```` 代码块 | 技术博客刚需 |
| `tables` | 表格 | 同上 |
| `nl2br` | 单换行渲染为 `<br>` | 中文写作习惯，段内换行不空行 |
| `sane_lists` | 严格列表规则 | 避免 `1.` 后接段落被误吞 |
| `toc` | 生成 `md.toc` 与标题 id | 右侧目录 |
| `footnotes` | 脚注 | 引用 |
| `attr_list` | `{: .cls }` 属性 | 定制图片/段落样式 |
| `def_list` | 定义列表 | 术语表 |
| `admonition` | `!!! note` 提示块 | 文档风格 |
| `md_in_html` | HTML 块内解析 Markdown | GitHub README 的 `<details>` 折叠块 |

**⚠️ 没有 `codehilite`**：代码高亮交给前端 highlight.js。服务端只输出 `<pre><code class="language-x">`。

### 7.3 TOC slugify

```python
def _toc_slugify(value, separator):
    value = value.lower().strip()
    value = re.sub(r'[^\w\u4e00-\u9fff]+', separator, value)
    return re.sub(r'-+', separator, value).strip(separator)
```

**必须**保留中文范围 `\u4e00-\u9fff`。默认 slugify 会把「配置说明」变成空串，导致多个标题 id 全为 `_1`、`_2`，锚点链接错乱。

**⚠️ 局限**：只覆盖基本汉字区，不含扩展 A/B 区、日文假名、韩文。若博客有多语言标题，**建议**扩展到 `\u3040-\u30ff\uac00-\ud7af`。

### 7.4 图片后处理

```python
_img_seen = [False]

def _img_repl(m):
    tag = m.group(0)
    if 'loading=' in tag:                      # 作者手写了 loading，尊重原意
        return tag
    src = re.search(r'src="([^"]+)"', tag)
    alt = re.search(r'alt="([^"]*)"', tag)
    alt_text = alt.group(1) if (alt and alt.group(1)) else (
        os.path.basename(src.group(1)) if src else '')
    tag = re.sub(r'\s+alt="[^"]*"', '', tag)    # 先删旧 alt，避免重复属性
    is_first = not _img_seen[0]
    _img_seen[0] = True
    if is_first:
        extra = ' decoding="async"'
        if src and src.group(1).startswith('/uploads/'):
            dims = _upload_image_dims(urllib.parse.unquote(src.group(1)))
            if dims:
                extra += f' width="{dims[0]}" height="{dims[1]}"'
    else:
        extra = ' loading="lazy" decoding="async"'
    return tag.replace('<img', f'<img{extra} alt="{alt_text}"', 1)
```

三个设计点：

1. **首图禁用 lazy 并注入真实宽高**。微信 / Twitter 的分享爬虫不执行 JS，且会跳过「无尺寸或懒加载」的图片。这是社交卡片能出图的关键。
2. **`_upload_image_dims` 按 mtime 缓存**：

   ```python
   _IMG_DIMS_CACHE = {}   # {相对路径: (mtime, w, h)}

   def _upload_image_dims(rel_url):
       rel = rel_url.split('/uploads/', 1)[-1]
       src = os.path.normpath(os.path.join(UPLOAD_DIR, rel))
       if not os.path.abspath(src).startswith(os.path.abspath(UPLOAD_DIR) + os.sep):
           return None
       mtime = os.path.getmtime(src)
       cached = _IMG_DIMS_CACHE.get(rel)
       if cached and cached[0] == mtime:
           return cached[1:]
       with Image.open(src) as im:
           dims = im.size
       _IMG_DIMS_CACHE[rel] = (mtime,) + dims
       return dims
   ```

3. **`unquote` 归一**：中文文件名在 Markdown 里是百分号编码，磁盘上是中文。不 `unquote` 就取不到尺寸。

**⚠️ `_img_seen` 是函数内局部变量**，每次渲染新建。若你把它改成全局，第二个文章的首图就不会被特殊处理。

### 7.5 链接后处理

```python
def _a_repl(m):
    tag = m.group(0)
    if re.search(r'href="#', tag):
        return tag                                   # 页内锚点保持当前窗口
    if re.search(r'href\s*=\s*["\']\s*javascript:', tag, re.I):
        return re.sub(r'href\s*=\s*["\'][^"\']*["\']', 'href="#"', tag, count=1)
    if 'target=' in tag:
        return tag
    return tag.replace('<a', '<a target="_blank" rel="noopener noreferrer"', 1)
```

**⚠️ `javascript:` 必须把 href 整体置为 `#`，不能只加 `rel`**。`rel="noopener"` 挡的是 `window.opener` 劫持，挡不住 `javascript:` 伪协议执行。

**⚠️ 没有做 HTML 消毒**。`markdown` 默认允许原始 HTML 透传，所以**管理员可以在文章里写任意 `<script>`**。这是「单管理员博客」的信任假设：管理员 = 站点所有者。若你的场景有多个作者，必须加 `bleach` 白名单。

### 7.6 保存文章

```python
def db_save_post(form_data, post_id=None):
    tags = json.dumps([t.strip() for t in form_data.get('tags','').split(',') if t.strip()],
                      ensure_ascii=False)
    slug = form_data.get('slug', '').strip()
    if not slug:
        slug = re.sub(r'[^a-zA-Z0-9\-]', '-',
                      form_data.get('title', 'untitled').lower())[:60]
    slug = re.sub(r'-+', '-', slug).strip('-') or 'untitled'

    content = normalize_auto_links(form_data.get('content', ''))
    read_time = max(1, len(content.split()) // 200) if content else 3

    excerpt = (form_data.get('excerpt') or '').strip()
    if not excerpt and content:
        plain = re.sub(r'<[^>]+>', '', content)
        plain = re.sub(r'[#*`\[\]()!>|~-]', '', plain)
        plain = re.sub(r'\s+', ' ', plain).strip()
        excerpt = plain[:200]

    created_at = (form_data.get('created_at') or '').strip().replace('T', ' ')
    if created_at and len(created_at) == 16:
        created_at += ':00'
    created_at = created_at or None

    if not post_id:                     # 新建：slug 唯一化
        base, i = slug, 2
        while db.execute("SELECT 1 FROM posts WHERE slug=?", (slug,)).fetchone():
            slug = f'{base}-{i}'; i += 1
```

**必须**对齐的五个细节：

1. **`slug` 只保留 ASCII**（`[^a-zA-Z0-9\-]` → `-`）。中文标题会得到 `--`，实际结果是 `untitled` 或纯数字。**⚠️ 这是与上传文件名（保留中文）相反的策略**，别混用。
2. **`read_time` 用 `content.split()` 计词**，对中文严重低估（中文无空格，整段算 1 个词）。**建议**改为 `len(re.findall(r'[\u4e00-\u9fff]', content)) / 400 + len(content.split()) / 200`。
3. **`created_at` 用 `COALESCE(?, created_at)`**：编辑时留空保持原值，不会被重置为当前时间。
4. **摘要在保存时固化**，不是渲染时计算。这意味着改了正文但没改摘要，摘要不会同步。
5. **`is_featured` 是 `'1'` 字符串比较**，不是布尔。

### 7.7 删除文章与文件清理

```python
def db_delete_post(post_id):
    row = db.execute("SELECT title, content, excerpt, tags FROM posts WHERE id=?", (post_id,)).fetchone()
    gone_urls = _extract_upload_urls(*tuple(row)) if row else set()
    db.execute("DELETE FROM posts WHERE id=?", (post_id,))     # 评论靠 CASCADE
    db.commit()
    removed = []
    if gone_urls:
        survivor_urls = set()
        for r in db.execute("SELECT title, content, excerpt, tags FROM posts").fetchall():
            survivor_urls |= _extract_upload_urls(*tuple(r))
        for url in sorted(gone_urls):
            if url not in survivor_urls and _delete_upload_file(url):
                removed.append(url)
    return removed
```

**必须**做「幸存引用比对」。同一张图被两篇文章引用时，删第一篇不能删图。

`_extract_upload_urls`：

```python
_UPLOAD_URL_RE = re.compile(r'/uploads/[/\w%.\-]+')

def _extract_upload_urls(*texts):
    urls = set()
    for text in texts:
        if not text: continue
        for u in _UPLOAD_URL_RE.findall(text):
            urls.add(urllib.parse.unquote(u))    # 关键：百分号编码 → 原始字符
    return urls
```

**⚠️ `unquote` 不可省**。磁盘文件名是中文，Markdown 里是 `%E4%B8%AD%E6%96%87.png`，不归一就永远匹配不上，导致文件删不掉。

### 7.8 RSS

```python
@app.route('/feed.xml')
def rss_feed():
    posts, _ = db_load_posts(per_page=20)
    rss = ET.Element('rss', version='2.0')
    ch = ET.SubElement(rss, 'channel')
    ET.SubElement(ch, 'title').text = app.config.get('blog_name', '')
    ET.SubElement(ch, 'link').text = url_for('index', _external=True)
    ET.SubElement(ch, 'description').text = app.config.get('blog_subtitle', '')
    for p in posts:
        item = ET.SubElement(ch, 'item')
        ET.SubElement(item, 'title').text = p['title']
        ET.SubElement(item, 'link').text = url_for('post_detail', post_id=p['id'], _external=True)
        ET.SubElement(item, 'guid').text = ...
        ET.SubElement(item, 'description').text = p['excerpt']
        pub = ET.SubElement(item, 'pubDate')
        pub.text = email.utils.format_datetime(
            datetime.strptime(p['created_at'], '%Y-%m-%d %H:%M:%S')
                    .replace(tzinfo=timezone(_td(hours=8))))
    xml = minidom.parseString(ET.tostring(rss, encoding='utf-8')).toprettyxml(indent='  ')
    return Response(xml, mimetype='application/rss+xml')
```

**必须**的细节：

1. **`pubDate` 必须带时区**。RSS 2.0 要求 RFC 822 格式，裸时间会被阅读器按 UTC 解析，导致时间偏移 8 小时。
2. **解析失败要降级**：`created_at` 可能不是标准格式（历史数据），`strptime` 失败时直接输出原值，不能让整个 feed 500。
3. **`minidom.toprettyxml` 会引入空行**，体积略大但可读性好。**建议**输出前 `re.sub(r'\n\s*\n', '\n', xml)`。

### 7.9 分享图

优先级：`cover` > 正文首图 > 默认 `static/images/og-image.png`。

若图片在 `/uploads/` 下，分享 URL 换成 `/share-thumb/` 同名路径：

```python
share_img = post['cover'] or _first_upload_url(post['content']) or '/static/images/og-image.png'
if share_img.startswith('/uploads/'):
    share_img = '/share-thumb/' + share_img[len('/uploads/'):]
```

**为什么不在分享时直接给原图**：手机直出图 3–8MB，微信卡片加载慢且可能超时。`/share-thumb/` 懒生成 800×600 居中裁切 JPEG（q85），首次访问写 `data/share_thumbs/`，`Cache-Control: public, max-age=86400`。

**⚠️ 缩略图缓存目录不在 `uploads/` 下**，是为了避开孤儿清理（`admin_orphans` 会扫 `uploads/`）。复刻时若改路径，必须同步改清理白名单。

### 7.10 实现陷阱

1. **`render_post_content` 每次请求都重新解析 Markdown**，没有缓存。文章页 QPS 高时应加「(post_id, updated_at) → html」的进程内 LRU。
2. **任务列表替换是全局字符串替换**，会把代码块里的 `[x]` 也换掉。**建议**用正则限定在列表行首：`^(\s*)[-*] \[([ x])\]`。
3. **`toc` 的 `toc_depth='2-6'`** 意味着 `h1` 不进目录。文章正文应统一从 `##` 开始。
4. **`md.toc` 在无标题时是空字符串**，但有时是 `'<div class="toc">\n</div>'`。上游用 `'<li>' not in toc` 判断，比判断空串可靠。
5. **`_extract_upload_urls` 的正则不匹配查询串**（`?v=1`），所以带版本参数的图片 URL 不会被清理。**建议**接受这一点，否则误删风险更高。

---

## §8 评论系统

### 8.1 数据流总览

```text
提交 ──▶ 限流(30s/IP) ──▶ 字段校验 ──▶ 身份判定 ──▶ 父级校验
                                                   │
                                    ┌──────────────┴──────────────┐
                                    │ 邮箱 == notify_email ?       │
                                    │ 是 → approved（博主免审）    │
                                    │ 否 → pending                 │
                                    └──────────────┬──────────────┘
                                                   │
                             ┌─────────────────────┼─────────────────────┐
                             ▼                     ▼                     ▼
                      写 DB + cookie         后台线程发邮件        后台线程查 IP 归属地
```

### 8.2 读取与组树

**单条 SQL 拉全量 + 内存组树**（避免 N+1）：

```python
def db_load_comments(post_id=None, project_id=None, include_private=False):
    col, val = ('post_id', post_id) if post_id else ('project_id', project_id)
    sql = f"SELECT * FROM comments WHERE {col}=?"
    params = [val]
    if not include_private:
        sql += " AND is_private=0"
    sql += " AND status!='rejected'"
    sql += " ORDER BY created_at ASC"
    rows = rows_to_list(db.execute(sql, params).fetchall())
    ...
```

组树：

```python
by_id = {c['id']: c for c in rows}
roots = []
for c in rows:
    c['children'] = []
for c in rows:
    pid = c.get('parent_id')
    if pid and pid in by_id:
        by_id[pid]['children'].append(c)
    else:
        roots.append(c)

def set_depth(nodes, depth=0):
    for n in nodes:
        n['depth'] = depth
        n['is_author'] = (n['author'] == app.config.get('author'))
        n['avatar'], _ = _avatar_urls(n.get('email_hash'), n.get('qq'))
        n.pop('email', None)              # 绝不外泄明文邮箱
        set_depth(n['children'], depth + 1)
set_depth(roots)
```

**⚠️ `c.pop('email')` 必须在返回给模板前执行**。模板里 `{{ comment.email }}` 一旦存在就会泄露；上游直接在数据层删掉，比「模板里不写」更可靠。

**⚠️ 孤儿评论**：`parent_id` 指向已删除的评论时，该评论会被提升为根节点（`pid not in by_id` 分支）。这是刻意的容错，不要改成丢弃。

### 8.3 访客回显（`my_comments`）

访客 Cookie `blog_commenter` 存 `{name, email, website}`（30 天），另有 `my_comments` 存 `{comment_id: 昵称}`。

回显「我刚发的待审核评论」时，**必须**三重校验：

```sql
SELECT * FROM comments
WHERE status != 'rejected'
  AND {col} = ?
  AND ( status='approved'
        OR (id IN (...) AND author = ?) )     -- id + 昵称 + 同载体
```

三个条件缺一不可：

1. **`id` 在 Cookie 的 `my_comments` 里**——防止遍历；
2. **`author` 与 Cookie 记录的昵称一致**——防止别人用同一 id 猜；
3. **`{col} = ?`（post_id 或 project_id）**——防止跨页串台。

**⚠️ 这是 v1.3.58 修的 bug**：早期只判 `id IN (...)`，导致 A 文章的评论回显到 B 文章页。SQL 里 `AND` 优先级高于 `OR`，所以 `OR` 分支必须自己带载体条件：

```sql
WHERE post_id=?
  AND status!='rejected'
  AND ( status='approved' OR (id IN (1,2,3) AND author='张三') )
```

`my_comments` 只保留最新 20 条，超出裁剪。

### 8.4 提交校验

```python
def _handle_new_comment(post=None, project=None):
    if not _comments_open(): abort(403)
    ip = _client_ip()
    if _comment_cooldown_blocked(ip): 
        flash('评论太频繁，请稍后再试', 'error')
        return redirect(...)

    is_admin = bool(session.get('admin_logged_in'))
    if is_admin:
        # 博主身份覆盖：昵称/邮箱/网址一律取后台配置，忽略表单
        author = app.config.get('author') or '博主'
        email  = app.config.get('notify_email') or ''
        website = ''
        email_hash = hashlib.md5(email.lower().encode()).hexdigest() if email else ''
    else:
        author = (request.form.get('author') or '').strip()[:30] or '匿名'
        email  = (request.form.get('email') or '').strip()
        website = (request.form.get('website') or '').strip()[:200]
        if email and not re.match(r'^[^@\s]+@[^@\s]+\.[^@\s]+$', email):
            flash('邮箱格式不正确', 'error'); return redirect(...)
        email_hash = hashlib.md5(email.lower().encode()).hexdigest() if email else ''
        qq = _QQ_RE.match(email.lower())
        qq = qq.group(1) if qq else ''

    # 昵称保留字：访客不得使用博主昵称，防冒充
    if not is_admin and author == (app.config.get('author') or ''):
        flash('该昵称已被保留', 'error'); return redirect(...)

    content = (request.form.get('content') or '').strip()
    if not content: flash('评论内容不能为空', 'error'); return redirect(...)
    if len(content) > 2000:
        content = content[:2000]

    if website and not re.match(r'^https?://', website, re.I):
        website = 'http://' + website

    parent_id = request.form.get('parent_id', type=int)
    if parent_id:
        parent = db_get_comment(parent_id)
        if not parent or parent.get('post_id') != (post or {}).get('id') \
                and parent.get('project_id') != (project or {}).get('id'):
            parent_id = None        # 父级必须同载体

    is_private = 1 if request.form.get('is_private') == '1' else 0
    status = 'approved' if (email and email == app.config.get('notify_email')) else 'pending'
    ...
```

**必须**的规则表：

| 规则 | 值 | 失败行为 |
| --- | --- | --- |
| 评论总开关 | `comments_enabled` | 403 |
| IP 冷却 | 30 秒 | flash 错误 + 重定向 |
| 昵称长度 | ≤ 30 字 | 截断 |
| 昵称保留 | 不得等于 `author` | flash 错误 |
| 内容长度 | ≤ 2000 字 | 截断（不报错） |
| 邮箱格式 | `^[^@\s]+@[^@\s]+\.[^@\s]+$` | flash 错误 |
| 网址格式 | 必须以 `http://` / `https://` 开头 | 自动补 `http://` |
| 父级载体 | 必须同 `post_id` / `project_id` | 降级为根评论 |
| 审核状态 | 邮箱 == `notify_email` → approved | 否则 pending |
| 私密 | `is_private=1` 仅管理员可见 | — |

**⚠️ 私密评论的语义**：不是「加密」，而是「列表查询时过滤掉」。管理员登录后能看到。数据库里仍是明文。

### 8.5 通知

```python
def _send_comment_notify(post_id, post_title, base_url, author, content,
                         parent_id, commenter_email, status='pending',
                         detail_path=None, label='文章'):
    """后台线程。新评论通知博主；若已 approved 且是回复，同时通知被回复者。"""
```

发送规则：

| 场景 | 收件人 | 时机 |
| --- | --- | --- |
| 新评论 | `notify_email` | 立即 |
| 回复且已 approved | 被回复者 `email` | 立即 |
| 回复但 pending | 被回复者 | **审核通过后**（`_notify_reply_recipient`） |
| SMTP 未配置 | — | 静默跳过 |
| 发送失败 | — | 静默吞掉，不阻塞请求 |

**⚠️ 待审核回复不能立即通知被回复者**：对方点进链接看不到评论，会以为站点坏了。这是 v1.3.x 的行为修正。

邮件是内嵌 CSS 的 HTML（`_NOTIFY_CSS`），头部渐变、CTA 按钮、引用块，兼容主流客户端。**不要**用外部 CSS，Gmail 会剥掉。

### 8.6 IP 归属地

```python
sys.path.insert(0, os.path.join(BASE_DIR, 'vendor'))
import ip2region.util as _i2r_util
import ip2region.searcher as _i2r_searcher

_IPDB = {}                        # {'4': searcher, '6': searcher}
_IPDB_LOCK = threading.Lock()     # 查询器共享文件句柄，非线程安全

def _ip_location(ip):
    if not ip or not _HAS_IP2REGION: return ''
    ip = ip.replace('::ffff:', '')            # IPv4-mapped IPv6
    if ip in ('127.0.0.1', '::1') or ip.startswith(('10.', '192.168.', '172.')):
        return ''                              # 回环/私网不展示
    with _IPDB_LOCK:
        searcher = _get_searcher('6' if ':' in ip else '4')
        return _fmt_loc(searcher.search(ip))
```

`_fmt_loc` 去掉行政区划后缀：`重庆市 → 重庆`、`四川省 → 四川`、`广西壮族自治区 → 广西`。

**必须**串行化查询。ip2region 的 searcher 内部持有文件偏移，多线程并发 seek 会读到错位数据。

**⚠️ 私网判断 `startswith('172.')` 过宽**：`172.16.0.0/12` 才是私网，`172.32.x.x` 是公网。**建议**用 `ipaddress.ip_address(ip).is_private`。

### 8.7 删除评论

```python
def db_delete_comment(comment_id):
    db = get_db()
    # BFS 收集整棵子树
    to_delete, queue = set(), [comment_id]
    while queue:
        cid = queue.pop()
        if cid in to_delete: continue
        to_delete.add(cid)
        for r in db.execute("SELECT id FROM comments WHERE parent_id=?", (cid,)).fetchall():
            queue.append(r['id'])
    db.execute("DELETE FROM comments WHERE id IN (%s)" % ','.join('?' * len(to_delete)),
               tuple(to_delete))
    db.commit(); db.close()
```

**⚠️ 不用递归 CTE**：`WITH RECURSIVE` 在 SQLite 3.8.3+ 才支持，且老库可能有循环引用（`parent_id` 自指）导致无限递归。BFS + `visited` 集合天然安全。

### 8.8 后台审核

`admin_comments` 用三表 LEFT JOIN（`posts` / `projects` / `comments` 自身取父级昵称）：

```sql
SELECT c.*, p.title AS post_title, pr.name AS project_title, pc.author AS parent_author
FROM comments c
LEFT JOIN posts p    ON c.post_id = p.id
LEFT JOIN projects pr ON c.project_id = pr.id
LEFT JOIN comments pc ON c.parent_id = pc.id
ORDER BY (c.status='pending') DESC, c.is_private DESC, c.created_at DESC
```

**排序意图**：待审核优先 → 私密优先 → 最新优先。

### 8.9 实现陷阱

1. **评论内容是纯文本**，模板里必须 `| e` 或自动转义 + `nl2br`。不要渲染 Markdown。
2. **`_COMMENT_COOLDOWN` 的字典要限长**（5000 条），否则长期运行内存缓慢增长。
3. **博主评论的 `email_hash` 用 `notify_email`**，这样头像与邮件通知一致。
4. **`is_author` 判定用昵称相等**，访客可改昵称绕过——所以提交时做了保留字拦截。但历史数据里可能已有冒充者，后台需人工清理。
5. **`db_save_comment` 必须显式写 `created_at=_now()`**，否则新评论是 UTC，与老评论差 8 小时，排序错乱。

---

## §9 主题系统

### 9.1 目录约定

```text
templates/
├── default/            # 内置主题，永远存在
│   ├── info.json       # 可选
│   ├── theme.css       # 可选
│   ├── preview.png     # 可选
│   └── *.html
├── tech/               # 第三方主题
│   ├── info.json
│   ├── theme.css
│   ├── theme.js
│   ├── preview.png
│   └── *.html
└── admin/              # 后台模板，不是主题
```

### 9.2 模板查找链

`ThemeLoader` 覆写 `get_source`，按「当前主题 → default → templates 根」顺序查找：

```python
class ThemeLoader(FileSystemLoader):
    def get_source(self, environment, template):
        paths = [os.path.join(TEMPLATE_DIR, _active_theme_key()),
                 os.path.join(TEMPLATE_DIR, DEFAULT_THEME_NAME),
                 TEMPLATE_DIR]
        last = None
        for p in paths:
            try:
                return FileSystemLoader(p).get_source(environment, template)
            except Exception as e:
                last = e
        raise last
```

**为什么自定义 `get_source` 而不是给 `searchpath` 传三个目录**：Jinja 的 `FileSystemLoader(searchpath=[a,b,c])` 也能按序查找，但它对 `admin/xxx.html` 这类带子目录的名字行为一致；上游显式实现是为了**保证优先级**并便于加日志。两种写法等价，复刻时任选，但**必须**保证 `default` 在 `templates` 根之前。

### 9.3 Flask 3.x 的 loader 注入

Flask 3.0 不再调用 `create_jinja_loader()`，改为读 `jinja_loader` property。必须：

```python
class ThemedFlask(Flask):
    @property
    def jinja_loader(self):
        return ThemeLoader(TEMPLATE_DIR)
```

**⚠️ 这是最容易踩的坑**：照抄 Flask 2.x 的 `def create_jinja_loader(self)` 在 Flask 3.0 下**完全不生效**，表现为「换主题没反应」或「自定义主题模板永远不命中」。

### 9.4 主题发现

```python
def list_themes():
    names = [DEFAULT_THEME_NAME] + sorted(
        n for n in os.listdir(TEMPLATE_DIR)
        if os.path.isdir(os.path.join(TEMPLATE_DIR, n))
        and not n.startswith('.') and n not in (DEFAULT_THEME_NAME, 'admin'))
    out = []
    for name in names:
        info = _read_theme_info(name)
        fb = ({'name': '系统默认', 'author': 'infowe',
               'description': '内置样式与模板', 'version': VERSION}
              if name == DEFAULT_THEME_NAME else
              {'name': name, 'author': '', 'description': '', 'version': ''})
        out.append({'key': name,
                    'name': info.get('name') or fb['name'],
                    'author': info.get('author') or fb['author'],
                    'description': info.get('description') or fb['description'],
                    'version': info.get('version') or fb['version'],
                    'has_preview': os.path.isfile(os.path.join(TEMPLATE_DIR, name, 'preview.png'))})
    return out
```

`info.json`：

```json
{
  "name": "Tech",
  "author": "infowe",
  "description": "深色科技风，等宽字体，适合代码类内容",
  "version": "1.0.0"
}
```

**⚠️ `info.json` 损坏必须返回 `{}` 而不是抛异常**，否则整个后台主题页 500。

### 9.5 静态资源版本号

```python
def _theme_asset_ver():
    files = [os.path.join(TEMPLATE_DIR, _active_theme_key(), f)
             for f in ('theme.css', 'theme.js')]
    mtimes = [int(os.path.getmtime(f)) for f in files if os.path.isfile(f)]
    return str(max(mtimes)) if mtimes else VERSION
```

模板里：

```html
<link rel="stylesheet" href="{{ url_for('theme_static', filename='theme.css') }}?v={{ theme_ver }}">
```

**用 mtime 而不是内容哈希**：改文件即变版本，无需构建；代价是「touch 一下也会让所有客户端重新下载」。这是刻意的取舍。

`_admin_asset_ver()` 同理，扫描 `static/css/admin.css` 与 `static/js/admin.js`。

### 9.6 `theme_static` 路由

```python
@app.route('/themes/<path:filename>')
def theme_static(filename):
    theme = _active_theme_key()
    full = os.path.normpath(os.path.join(TEMPLATE_DIR, theme, filename))
    if not os.path.abspath(full).startswith(os.path.abspath(TEMPLATE_DIR) + os.sep):
        abort(404)                                   # 目录穿越
    ext = os.path.splitext(full)[1].lower()
    if ext not in ('.css', '.js', '.png', '.jpg', '.jpeg', '.webp', '.svg', '.woff', '.woff2'):
        abort(404)
    if theme == DEFAULT_THEME_NAME and filename not in ('preview.png',):
        # default 主题只暴露预览图，防止直接读模板/CSS 源码
        abort(404)
    if filename.endswith('preview.png'):
        return _preview_thumb(full)                  # 480×300 缩略
    return send_from_directory(os.path.join(TEMPLATE_DIR, theme), filename)
```

**⚠️ 为什么 default 主题不暴露资源**：`default/theme.css` 不存在（内置样式在 `static/css/style.css`），模板文件若可读会被当成静态文本下载，泄露结构。第三方主题的 `theme.css` 必须可读，因为前台要加载。

### 9.7 预览图缩略

```python
def _preview_thumb(path):
    cache = path.replace('.png', '.thumb.png')
    if not (os.path.isfile(cache) and os.path.getmtime(cache) >= os.path.getmtime(path)):
        with Image.open(path) as im:
            im.thumbnail((480, 300), Image.LANCZOS)
            im.save(cache, 'PNG', optimize=True)
    return send_file(cache)
```

**⚠️ 原图损坏时必须回退原图**，不能让后台主题列表整页崩。

### 9.8 实现陷阱

1. **换主题后必须清 `app.jinja_env.cache`**，且要在 `before_request`（见 §5.1）。
2. **主题目录名不能含 `/` 或 `..`**。`_active_theme_key()` 应校验：只允许 `[A-Za-z0-9_-]+`，且目录必须存在。
3. **`theme.js` 是可选的**，模板里必须 `{% if theme_has_css %}` / 类似判断，否则 404。
4. **自定义主题不需要提供全部页面**，缺失的走 `default`。但 `base.html` 一旦提供，就必须自己实现 `{% block %}` 结构，否则子模板 `extends` 会失败。
5. **`TEMPLATES_AUTO_RELOAD=True` 在生产也开着**，代价是每次渲染 stat 模板文件。单机博客可接受。

---

## §10 前台页面

### 10.1 首页 `/`

```python
@app.route('/')
def index():
    tag = request.args.get('tag', '')
    search = request.args.get('q', '')
    home_count = int(app.config.get('home_posts_count', '6') or 6)

    if tag or search:
        posts, total = db_load_posts(tag=tag or None, search=search or None, page=1)
        return render_template('index.html', posts=posts, total=total,
                               filter_tag=tag, filter_search=search, ...)

    featured = db_get_featured_posts(limit=3)
    posts, total = db_load_home_posts(limit=home_count, exclude_featured=True)
    return render_template('index.html', featured=featured, posts=posts, total=total,
                           links=db_load_links('approved'), ...)
```

两个分支：

- **筛选态**（`?tag=` / `?q=`）：不显示精选区，直接出列表。
- **常态**：精选区（`is_featured=1`，最多 3 条）+ 文章流（排除已展示的精选，避免重复）。

**⚠️ `exclude_featured=True` 的语义是「排除所有精选」还是「排除已显示的精选」**：上游 `db_load_home_posts` 传 `exclude_featured=True` 时排除 **所有** `is_featured=1` 的文章。这意味着第 4 篇之后的精选文章在首页**完全不可见**，只能去 `/posts` 找。这是设计缺陷，复刻时**建议**改成 `WHERE id NOT IN (已显示的 3 个 id)`。

### 10.2 归档 `/posts`

两种模式：

1. **无筛选**：按「置顶 → 年份」分组。置顶组在前，然后每年一组，组内按 `created_at DESC`。
2. **有 `?tag=` / `?q=`**：普通分页列表。

```python
posts, total = db_load_posts(tag=tag, search=search, page=page)
total_pages = max(1, math.ceil(total / per_page))
page = max(1, min(page, total_pages))       # 必须在视图层夹紧
```

**⚠️ 夹紧后要重查还是复用**：上游先查总数再夹紧页码，然后重新查询。若复用夹紧前的 `posts`，用户访问 `?page=999` 会看到第 1 页的数据但页码显示 999。

### 10.3 文章详情 `/post/<id>`

```python
@app.route('/post/<int:post_id>')
def post_detail(post_id):
    post = db_get_post_by_id(post_id)
    if not post or post['status'] != 'published':
        abort(404)
    html, toc = render_post_content(post['content'])
    related = db_get_related_posts(post, limit=3)
    comments = db_load_comments(post_id=post_id)
    category = db_get_category(post['category_id']) if post.get('category_id') else None
    share_img = ...
    return render_template('post.html', post=post, content_html=html, toc=toc,
                           related=related, comments=comments, category=category,
                           share_img=share_img, ...)
```

**分享图选择链**：

```python
def _first_upload_url(html_or_md):
    m = re.search(r'/uploads/[/\w%.\-]+', html_or_md or '')
    return m.group(0) if m else ''

share_img = post['cover'] or _first_upload_url(post['content']) or '/static/images/og-image.png'
```

**⚠️ 草稿不可直达**：`status != 'published'` 一律 404，管理员也不能通过前台预览。后台预览走 `/admin/posts/<id>/preview`。

### 10.4 阅读量

前端在文章页停留后：

```javascript
var url = '/post/' + postId + '/view';
if (navigator.sendBeacon) navigator.sendBeacon(url);
```

服务端：

```python
_VIEW_COOLDOWN = {}                       # {(ip, post_id): ts}
_VIEW_COOLDOWN_WINDOW = 60

@app.route('/post/<int:post_id>/view', methods=['POST'])
def post_view(post_id):
    ip = _client_ip()
    key = (ip, post_id)
    now = time.time()
    if now - _VIEW_COOLDOWN.get(key, 0) < _VIEW_COOLDOWN_WINDOW:
        return ('', 204)
    _VIEW_COOLDOWN[key] = now
    _prune_cooldown()
    db = get_db()
    db.execute("UPDATE posts SET views = views + 1 WHERE id=?", (post_id,))
    db.commit()
    return ('', 204)
```

**必须**返回 204 无内容。`sendBeacon` 不关心响应，但 200 带 body 会浪费带宽。

**⚠️ 冷却字典要限长**（`_VIEW_MAX_ENTRIES`），否则长期运行内存膨胀。

**⚠️ `sendBeacon` 会被广告拦截器拦截**，所以阅读量偏低是正常的。若要精确，用 `fetch(..., {keepalive:true})` 做降级。

### 10.5 标签页 `/tags`

```python
@app.route('/tags')
def tags():
    posts, _ = db_load_posts(per_page=99999)
    buckets = {}
    for p in posts:
        for t in p['tags']:
            buckets.setdefault(t, []).append(p)
    tag_list = sorted(buckets.items(), key=lambda kv: (-len(kv[1]), kv[0]))
    return render_template('tags.html', tags=tag_list, ...)
```

排序：**按文章数降序，再按名字升序**。这比按字母排更实用（热门标签在前）。

### 10.6 关于页 `/about`

数据来源：

- `skills`（JSON）→ 技能条，`level` 0–100；
- `timeline` 表 → 时间线；
- `stats` → `post_total`、`category_total`；
- `about_intro`、`author_bio`、`avatar`、`social_github`、`contact_email`。

**⚠️ `skills` JSON 解析失败必须回退 `[]`**，否则关于页 500。

### 10.7 状态页 `/status`

```python
@app.route('/status')
def status_page():
    services = get_services_status()          # 24h 可用率
    expiry = get_expiry_info()                # 云主机/域名到期
    return render_template('status.html', services=services, expiry=expiry, ...)

@app.route('/api/status')
def api_status():
    return jsonify({'services': get_services_status(), 'expiry': get_expiry_info()})
```

`get_services_status()` 对每个 `monitor_services` 条目取最近 24h 的 `service_checks`：

```python
total = len(checks)
ok = sum(1 for c in checks if c['ok'])
uptime = round(ok * 100 / total, 2) if total else None
```

前端 `status.js` 轮询 `/api/status`（默认 60 秒），更新状态点与延迟。

### 10.8 项目页 `/projects`

- 列表：按 `sort_order ASC, created_at DESC`，卡片展示 `languages` 色条、stars、topics。
- 详情：读 `project_cache_snapshot()`（**只读缓存，不发网络请求**），渲染 README HTML、评论树。

**⚠️ 前台零 GitHub 请求**是硬规则。README 只在后台点「同步」时拉取并落盘。前台若缓存缺失，显示「暂无 README，请在后台同步」。

### 10.9 友链 `/links`

- 列表：`status='approved'`，按 `sort_order ASC, created_at DESC`。
- 申请 `/links/apply`：`name` / `url` / `description` / `avatar`，提交后 `status='pending'`，后台审核。

**⚠️ URL 必须补全协议**：用户常填 `example.com`，前端 `<a href="example.com">` 会变成相对路径。提交时若不以 `http://`/`https://` 开头，自动补 `http://`。

### 10.10 搜索 `/search`

```python
@app.route('/search')
def search():
    q = request.args.get('q', '').strip()
    return redirect(url_for('index', q=q) if q else url_for('index'))
```

**只是重定向**，实际搜索在首页分支里做。这样搜索结果的 URL 可分享、可被 CDN 缓存。

### 10.11 404 / 500

见 §5.4。**必须**每个主题都提供 `404.html` 与 `500.html`，否则回退到 `default` 时样式会与当前主题不一致（不崩，但观感割裂）。

### 10.12 实现陷阱

1. **首页与归档页共用 `index.html` / `posts.html`**，靠 `filter_tag` / `filter_search` 变量区分。复刻时若拆成两个模板，注意宏与分页组件的复用。
2. **精选区的「精选」与「置顶」是同一个字段** `is_featured`，没有独立置顶。语义混淆但实现简单。
3. **`posts` 页的年份分组在模板里做**，数据层只返回平铺列表。年份从 `created_at[:4]` 取。
4. **所有 `url_for` 的端点名必须与上游一致**，否则自定义主题里的硬编码链接会 404。这是复刻时最容易忽略的兼容性约束。

---

## §11 后台管理

### 11.1 路由全表

| 方法 | 路径 | 端点 | 行为要点 |
| --- | --- | --- | --- |
| GET | `/admin` | `admin_index` | 已登录 → dashboard；`_otp_user` → OTP；否则 login |
| GET/POST | `/admin/login` | `admin_login` | 见 §6.3 |
| GET | `/admin/logout` | `admin_logout` | `session.clear()` → login（⚠️ GET） |
| GET/POST | `/admin/otp` | `admin_otp` | 6 位码或恢复码；失败计入同一限流 |
| GET/POST | `/admin/otp/recover` | `admin_otp_recover` | 恢复码入口 |
| GET/POST | `/admin/forgot` | `admin_forgot` | 邮件重置 |
| GET | `/admin/otp/setup` | `admin_otp_setup` | JSON：`{secret, uri}`，不落库 |
| POST | `/admin/otp/clear-emergency` | `admin_otp_clear_emergency` | 删 `.otp_disable` |
| GET | `/admin/dashboard` | `admin_dashboard` | 统计卡 + 最近更新的 5 篇 |
| GET | `/admin/categories` | `admin_categories` | 列表含 `post_count` |
| GET/POST | `/admin/categories/new` | `admin_category_new` | slug 留空自动生成 |
| GET/POST | `/admin/categories/<id>/edit` | `admin_category_edit` | |
| POST | `/admin/categories/<id>/delete` | `admin_category_delete` | 先解绑文章 |
| POST | `/admin/categories/bulk` | `admin_categories_bulk` | 仅支持 `action=delete` |
| GET | `/admin/posts` | `admin_posts` | `?status=all|published|draft`、`?q=`、`?page=` |
| POST | `/admin/posts/bulk` | `admin_posts_bulk` | 批量删除 / 改状态 |
| GET/POST | `/admin/posts/new` | `admin_post_new` | Vditor 编辑器 |
| GET/POST | `/admin/posts/<id>/edit` | `admin_post_edit` | |
| POST | `/admin/posts/<id>/delete` | `admin_post_delete` | 返回删掉的文件数 |
| GET | `/admin/posts/<id>/preview` | `admin_post_preview` | 用前台模板渲染未发布稿 |
| POST | `/admin/posts/preview-content` | `admin_post_preview_content` | JSON：正文实时预览 HTML |
| GET | `/admin/projects` | `admin_projects` | 含同步状态 |
| GET/POST | `/admin/projects/new` | `admin_project_new` | 填 GitHub URL 自动拉元数据 |
| GET/POST | `/admin/projects/<id>/edit` | `admin_project_edit` | |
| POST | `/admin/projects/<id>/delete` | `admin_project_delete` | 连带删评论 |
| POST | `/admin/projects/bulk` | `admin_projects_bulk` | |
| POST | `/admin/projects/<id>/sync` | `admin_project_sync` | 起后台线程，立即返回 JSON |
| POST | `/admin/projects/sync-all` | `admin_projects_sync_all` | 同上，全部项目 |
| GET | `/admin/projects/sync-status` | `admin_projects_sync_status` | 轮询；`?consume=1` 消费完成提示 |
| GET | `/admin/links` | `admin_links` | 待审核置顶 |
| POST | `/admin/links/<id>/approve` | `admin_link_approve` | |
| POST | `/admin/links/<id>/reject` | `admin_link_reject` | |
| GET/POST | `/admin/links/new` | `admin_link_new` | 默认 approved |
| GET/POST | `/admin/links/<id>/edit` | `admin_link_edit` | |
| POST | `/admin/links/<id>/delete` | `admin_link_delete` | |
| POST | `/admin/links/bulk` | `admin_links_bulk` | approve/reject/delete |
| GET | `/admin/timeline` | `admin_timeline` | |
| GET/POST | `/admin/timeline/new` | `admin_timeline_new` | |
| GET/POST | `/admin/timeline/<id>/edit` | `admin_timeline_edit` | |
| POST | `/admin/timeline/<id>/delete` | `admin_timeline_delete` | |
| POST | `/admin/timeline/bulk` | `admin_timeline_bulk` | |
| GET | `/admin/comments` | `admin_comments` | 三表 JOIN，待审核优先 |
| POST | `/admin/comments/<id>/approve` | `admin_comment_approve` | 通过后补发被回复者通知 |
| POST | `/admin/comments/<id>/delete` | `admin_comment_delete` | 删整棵子树 |
| POST | `/admin/comments/bulk` | `admin_comments_bulk` | approve/reject/delete |
| POST | `/admin/upload/image` | `admin_upload_image` | 字段名 `image`（编辑器钩子） |
| POST | `/admin/upload/media` | `admin_upload_media` | 字段 `file` 或 `media` |
| POST | `/admin/upload/file` | `admin_upload_file` | 附件 |
| GET/POST | `/admin/orphans` | `admin_orphans` | GET 扫描；POST 逐项删除（AJAX） |
| GET/POST | `/admin/status` | `admin_status` | 监控列表 + 云端配置 |
| POST | `/admin/status/probe` | `admin_status_probe` | 手动探活一轮 |
| POST | `/admin/status/test-cloud` | `admin_status_test_cloud` | 测云 API 凭据 |
| GET/POST | `/admin/themes` | `admin_themes` | POST 切换 `active_theme` |
| GET/POST | `/admin/settings` | `admin_settings` | 白名单保存 |
| POST | `/admin/settings/test-email` | `admin_settings_test_email` | 用表单临时配置试发 |
| GET | `/admin/export` | `admin_export` | 备份列表 + 各表计数 |
| POST | `/admin/export/db-backup` | `admin_export_db_backup` | `shutil.copy2` |
| GET | `/admin/export/download/<name>` | `admin_export_download` | `secure_filename` 校验 |
| POST | `/admin/export/delete/<name>` | `admin_export_delete` | |
| GET | `/admin/export/json` | `admin_export_json` | 全站 JSON，排除含 `password` 的 key |
| GET | `/admin/export/markdown` | `admin_export_markdown` | Markdown + 图片 zip |
| GET/POST | `/admin/upgrade` | `admin_upgrade` | GET 秒开；POST 强制检测 + 执行 |
| GET | `/admin/upgrade/check` | `admin_upgrade_check` | JSON |

### 11.2 列表页的统一结构

所有后台列表页遵循同一套模式：

```python
@app.route('/admin/posts')
@admin_required
def admin_posts():
    status_filter = request.args.get('status', 'all')
    search = request.args.get('q', '')
    page = request.args.get('page', 1, type=int)
    status = None if status_filter == 'all' else status_filter
    posts, total = db_load_posts(status=status, search=search or None, page=page)
    total_pages = max(1, math.ceil(total / PAGE_SIZE))
    page = max(1, min(page, total_pages))
    return render_template('admin/posts.html', posts=posts, total=total,
                           page=page, total_pages=total_pages,
                           status_filter=status_filter, q=search)
```

**⚠️ 后台 `db_load_posts(status=None)` 表示「全部状态」**，而前台默认 `status='published'`。同一个函数靠参数区分，复刻时别把默认值写死。

### 11.3 批量操作

统一约定：`POST` 一个 `action` + 若干 `ids` / `<entity>_ids`。

```python
@app.route('/admin/posts/bulk', methods=['POST'])
@admin_required
def admin_posts_bulk():
    action = request.form.get('action')
    ids = request.form.getlist('post_ids')
    if not ids:
        flash('未选择任何文章', 'error'); return redirect(url_for('admin_posts'))
    if action == 'delete':
        for pid in ids: db_delete_post(int(pid))
        flash(f'已删除 {len(ids)} 篇文章', 'success')
    elif action == 'publish':
        db_bulk_set_status([int(i) for i in ids], 'published')
        flash(f'已发布 {len(ids)} 篇文章', 'success')
    elif action == 'draft':
        ...
    else:
        flash('无效的批量操作', 'error')
    return redirect(url_for('admin_posts'))
```

**⚠️ `ids` 必须 `int()` 转换**，不能直接拼进 SQL。上游一律用 `int(i)` 或参数化。

**前端交互**：`admin.js` 在列表页检测 `data-bulk="1"` 的表格，自动注入「批量模式」按钮；进入后每行出现复选框，`Esc` 退出。

### 11.4 编辑器与 slug

`admin/post_edit.html` 用 Vditor（`static/vendor/vditor`）。两个关键交互：

```javascript
// 标题 → slug 自动生成；一旦手动改过 slug 就锁定
var slugInput = document.getElementById('slug');
var manual = false;
slugInput.addEventListener('input', function () { manual = true; });
titleInput.addEventListener('input', function () {
  if (manual) return;
  slugInput.value = titleInput.value
      .toLowerCase()
      .replace(/[^a-z0-9\-]+/g, '-')
      .replace(/-+/g, '-')
      .replace(/^-|-$/g, '');
});

// Ctrl+S / Cmd+S 保存
document.addEventListener('keydown', function (e) {
  if ((e.ctrlKey || e.metaKey) && e.key === 's') {
    e.preventDefault();
    document.getElementById('post-form').submit();
  }
});
```

**⚠️ 前端 slug 规则必须与后端一致**，否则用户看到 `hello-world`、实际存 `untitled`。后端是权威，前端只是提示。

### 11.5 设置页保存

```python
@app.route('/admin/settings', methods=['GET', 'POST'])
@admin_required
def admin_settings():
    if request.method == 'POST':
        # 1) 白名单逐项保存（文本类）
        for key in SETTINGS_WHITELIST:
            if key in request.form:
                val = request.form.get(key, '')
                if key == 'stats_code':
                    val = _sanitize_stats_code(val)
                save_setting(key, val)

        # 2) 复选框：未勾选时表单里没有该字段 → 必须单独置 '0'
        for key in ('comments_enabled', 'comment_notify',
                    'nav_posts', 'nav_tags', 'nav_projects',
                    'nav_links', 'nav_status', 'nav_about',
                    'watermark_enabled'):
            save_setting(key, '1' if request.form.get(key) else '0')

        # 3) 账号名修改
        new_name = (request.form.get('admin_username') or '').strip()
        if new_name and new_name != session.get('admin_username'):
            if not re.match(r'^[a-zA-Z0-9_\u4e00-\u9fff-]{2,30}$', new_name):
                flash('账号名只能包含中英文、数字、下划线、连字符，2–30 位', 'error')
                return redirect(url_for('admin_settings'))
            db.execute("UPDATE users SET username=? WHERE id=1", (new_name,))
            session['admin_username'] = new_name

        # 4) 改密：必须验证旧密码
        old_pwd = request.form.get('old_password') or ''
        new_pwd = request.form.get('new_password') or ''
        if new_pwd:
            user = db.execute("SELECT * FROM users LIMIT 1").fetchone()
            if not verify_password(user['password_hash'], old_pwd):
                flash('旧密码不正确', 'error'); return redirect(...)
            db.execute("UPDATE users SET password_hash=? WHERE id=?",
                       (hash_password(new_pwd), user['id']))
            _clear_initial_pwd_file()

        # 5) 水印设置变更 → 后台线程重刷历史图
        if watermark_changed:
            _start_wm_refresh(text, position, size)
```

四条**必须**：

1. **复选框单独处理**。HTML 表单不提交未勾选的 checkbox，循环白名单会把「取消勾选」误判为「没改」。
2. **`stats_code` 必须消毒**后入库。
3. **改密必须验旧密码**（v1.3.56 修复）。否则 session 被劫持后可直接改密锁死站点。
4. **`save_setting` 后要同步 `app.config`**，否则当前请求后续逻辑读到旧值。

```python
def save_setting(key, value):
    db = get_db()
    db.execute("INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)", (key, value))
    db.commit(); db.close()
    app.config[key] = value
```

### 11.6 仪表盘

```python
def db_get_stats():
    return {
        'post_total': ...,
        'published': ...,
        'draft': ...,
        'comment_total': ...,
        'pending_comments': ...,
        'project_total': ...,
        'link_total': ...,
        'pending_links': ...,
        'views_total': ...,
    }
```

`recent` 取 `updated_at` 降序前 5。**⚠️ 不要用 `created_at`**——后台关心的是「最近改了什么」。

### 11.7 导出

| 端点 | 产物 | 要点 |
| --- | --- | --- |
| `db-backup` | `backups/blog-YYYYmmdd-HHMMSS.db` | `shutil.copy2(DB_PATH, dest)`，⚠️ 见 §16.5 |
| `json` | `backups/export-*.json` | 全部表；key 含 `password` 的字段排除 |
| `markdown` | `backups/markdown-*.zip` | 每篇一个 `.md`（含 front-matter）+ 引用图片 |

JSON 导出排除逻辑：

```python
def _strip_secrets(obj):
    if isinstance(obj, dict):
        return {k: _strip_secrets(v) for k, v in obj.items() if 'password' not in k.lower()}
    if isinstance(obj, list):
        return [_strip_secrets(x) for x in obj]
    return obj
```

**⚠️ `'password' not in k.lower()` 是黑名单**，`secret` / `token` / `smtp_pass` 不在其中。§16.7 有更严的白名单方案。

### 11.8 实现陷阱

1. **所有后台 POST 成功后都要 `redirect`**，不能直接 `render_template`，否则刷新会重复提交（无 CSRF 的情况下更危险）。
2. **`flash` 消息 4 秒自动消失**（`admin.js`），但重要的错误不要只靠 flash——用户可能已经切走。
3. **批量删除没有事务包裹**，中途失败会留下部分删除。**建议**包一层 `BEGIN/COMMIT`。
4. **`/admin/settings` 的 `SETTINGS_WHITELIST` 必须显式列全**，不要用「表单里有什么就存什么」——否则攻击者（或手滑）能写入任意 `app.config` 键。

---

## §12 媒体与上传

### 12.1 上传入口

| 路由 | 字段 | 用途 |
| --- | --- | --- |
| `/admin/upload/image` | `image` | Vditor 图片钩子，返回 `{url}` 或 `{error}` |
| `/admin/upload/media` | `file` 或 `media` | 视频/音频 |
| `/admin/upload/file` | `file` | 附件 |

```python
@app.route('/admin/upload/image', methods=['POST'])
@admin_required
def admin_upload_image():
    f = request.files.get('image')
    if not f:
        return jsonify(error='未收到文件'), 400
    url, err = _save_upload(f, kind='image')
    if err:
        return jsonify(error=err), 400
    return jsonify(url=url, path=url)
```

### 12.2 `_save_upload` 全流程

```text
接收文件
  ├─ 扩展名在白名单？否 → 拒绝
  ├─ 读取到内存，> 20MB？是 → 拒绝
  ├─ _safe_stem(原名) → 安全文件名
  ├─ 目标目录 uploads/%Y/%m/
  ├─ 重名？→ name_1.ext, name_2.ext …
  ├─ 图片？
  │    ├─ HEIC/HEIF → 转 JPEG
  │    ├─ 最长边 > 1920 → 等比缩放
  │    ├─ JPEG 重存 q82 progressive
  │    ├─ 原图备份到 uploads/.originals/<同路径>
  │    └─ 水印开启 → 叠字
  └─ 返回 /uploads/2026/09/xxx.jpg
```

关键配置：

```python
ALLOWED_IMAGE_EXT = {'.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp', '.heic', '.heif'}
MAX_SINGLE_UPLOAD = 20 * 1024 * 1024
MAX_LONG_SIDE = 1920
JPEG_QUALITY = 82
```

**⚠️ 上传大小有两道闸**：Flask 的 `MAX_CONTENT_LENGTH=32MB`（请求体）与 `_save_upload` 的 20MB（单文件）。前者防超大请求，后者允许一次传多个文件。

### 12.3 `_safe_stem`

```python
_WIN_RESERVED = {'CON','PRN','AUX','NUL', *(f'COM{i}' for i in range(1,10)),
                 *(f'LPT{i}' for i in range(1,10))}

def _safe_stem(name):
    """保留中文的安全文件名主干。"""
    stem = os.path.splitext(os.path.basename(name or ''))[0]
    stem = re.sub(r'[\\/:*?"<>|\x00-\x1f]+', '-', stem)   # 非法字符
    stem = re.sub(r'\.{2,}', '.', stem)                    # 折叠连续点，防 ..
    stem = stem.strip(' .')
    if not stem:
        stem = 'file'
    if stem.upper() in _WIN_RESERVED:
        stem = '_' + stem
    return stem[:80]
```

**⚠️ 不要用 `werkzeug.secure_filename`**：它会把中文全部丢掉，`中文文档.docx` 变成 `docx.docx`，多文件上传时互相覆盖。

**⚠️ `re.sub(r'\.{2,}', '.', stem)` 是防目录穿越的关键**：`a..b` 在拼接后可能被解析为上层目录。

### 12.4 图片压缩

```python
def _optimize_image(data, ext):
    with Image.open(io.BytesIO(data)) as im:
        im = ImageOps.exif_transpose(im)          # 修正手机方向
        w, h = im.size
        if max(w, h) > MAX_LONG_SIDE:
            im.thumbnail((MAX_LONG_SIDE, MAX_LONG_SIDE), Image.LANCZOS)
        out = io.BytesIO()
        if ext == '.png':
            if im.mode in ('RGBA', 'LA', 'P'):
                im.save(out, 'PNG', optimize=True)      # 保留透明通道
            else:
                im.convert('RGB').save(out, 'JPEG', quality=JPEG_QUALITY,
                                       optimize=True, progressive=True)
        elif ext == '.gif':
            return data                                 # 动图不处理
        else:
            im.convert('RGB').save(out, 'JPEG', quality=JPEG_QUALITY,
                                   optimize=True, progressive=True)
        return out.getvalue()
```

**必须**做 `exif_transpose`。手机照片的 EXIF 里有旋转标记，不转正会在网页上歪着显示，而浏览器对 `image-orientation` 的支持不一致。

**⚠️ GIF 跳过压缩**：Pillow 处理动图会丢帧。上游直接返回原数据。

**⚠️ PNG 带透明通道时保留 PNG**，否则透明区域变黑底。

### 12.5 HEIC 转换

```python
def _optimize_heic(data):
    try:
        import pillow_heif
        heif = pillow_heif.open_heif(io.BytesIO(data))
        im = Image.frombytes(heif.mode, heif.size, heif.data)
        out = io.BytesIO()
        im.convert('RGB').save(out, 'JPEG', quality=JPEG_QUALITY,
                               optimize=True, progressive=True)
        return out.getvalue(), '.jpg'
    except Exception:
        return data, '.heic'          # 转不了就原样存，浏览器绝大多数不支持
```

**⚠️ `pillow_heif.register_heif_opener()` 失败时仍必须能走 `open_heif` 直解路径**。上游为此写了两条路（注册 + 直解），复刻时别只留一条。

### 12.6 水印

文本：`watermark_text` 为空时用 `「站点名 · 域名」`。

位置：

| 值 | 位置 |
| --- | --- |
| `br` | 右下（默认） |
| `bl` | 左下 |
| `tr` | 右上 |
| `tl` | 左上 |
| `bc` | 底部居中 |

字号三档：

```python
_WM_SIZE_LEVELS = {
    's': (0.02, 14, 28),   # (相对短边比例, 最小 px, 最大 px)
    'm': (0.03, 18, 52),
    'l': (0.04, 24, 76),
}
```

绘制：

```python
def _apply_watermark(img, text, position='br', size='m'):
    ratio, lo, hi = _WM_SIZE_LEVELS.get(size, _WM_SIZE_LEVELS['m'])
    font_px = max(lo, min(hi, int(min(img.size) * ratio)))
    font = ImageFont.truetype(_find_watermark_font(), font_px)
    bbox = ImageDraw.Draw(img).textbbox((0, 0), text, font=font)
    tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
    margin = max(8, font_px // 3)
    x, y = {
        'br': (img.width - tw - margin, img.height - th - margin),
        'bl': (margin, img.height - th - margin),
        'tr': (img.width - tw - margin, margin),
        'tl': (margin, margin),
        'bc': ((img.width - tw) // 2, img.height - th - margin),
    }[position]
    layer = Image.new('RGBA', img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    d.text((x + 1, y + 1), text, font=font, fill=(0, 0, 0, 110))   # 阴影
    d.text((x, y), text, font=font, fill=(255, 255, 255, 190))     # 白字
    base = img.convert('RGBA')
    return Image.alpha_composite(base, layer).convert('RGB')
```

**字体发现三级策略**：

```python
_WM_FONT_CANDIDATES = [
    os.path.join(BASE_DIR, 'fonts', 'wqy-microhei.ttc'),   # 仓库自带，优先级最高
    '/usr/share/fonts/truetype/wqy/wqy-microhei.ttc',
    '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',
    'C:/Windows/Fonts/msyh.ttc',
    ...
]
_WM_FONT_SCAN_DIRS = ['/usr/share/fonts', '/usr/local/share/fonts', '/System/Library/Fonts']
_WM_CJK_HINTS = ('wqy', 'noto', 'cjk', 'hei', 'song', 'yahei', 'pingfang', 'sourcehan', 'microhei')

def _find_watermark_font():
    for p in _WM_FONT_CANDIDATES:
        if os.path.isfile(p):
            return p
    for root_dir in _WM_FONT_SCAN_DIRS:
        for root, _, files in os.walk(root_dir):
            for fn in files:
                if fn.lower().endswith(('.ttf', '.ttc', '.otf')) and \
                        any(h in fn.lower() for h in _WM_CJK_HINTS):
                    return os.path.join(root, fn)
    return None      # 最终回退 PIL 默认位图字体（中文会变方块）
```

**⚠️ 扫描时只接受文件名命中 CJK 关键字者**。随便拿一个 `DejaVuSans.ttf` 画中文，结果是满屏 `□□□`。

### 12.7 `.originals` 无痕原图

每次处理前，先把原始字节写到 `uploads/.originals/<相对路径>`：

```text
uploads/2026/09/photo.jpg          ← 压缩 + 水印后的公开文件
uploads/.originals/2026/09/photo.jpg  ← 原图，公网不可达
```

用途：

1. 换水印文案后从原图重做，避免「水印叠水印」；
2. 用户想要原图时，管理员可从服务器取。

**`/uploads/<path>` 必须拒绝 `.originals`**：

```python
if filename.startswith('.') or '/.' in filename:
    abort(404)
```

**⚠️ `/share-thumb/<path>` 也要同样拦截**，否则缩略图路由成了绕过口。

### 12.8 孤儿文件清理

```python
@app.route('/admin/orphans', methods=['GET', 'POST'])
@admin_required
def admin_orphans():
    if request.method == 'GET':
        referenced = _load_referenced_urls()      # 全部文章的 URL 集合
        orphans = []
        for root, dirs, files in os.walk(UPLOAD_DIR):
            dirs[:] = [d for d in dirs if not d.startswith('.')
                       and d not in ('avatar', 'projects')]
            for fn in files:
                rel = os.path.relpath(os.path.join(root, fn), UPLOAD_DIR).replace('\\', '/')
                url = '/uploads/' + rel
                if url not in referenced:
                    orphans.append({'url': url, 'size': os.path.getsize(...)})
        return render_template('admin/orphans.html', orphans=orphans)
    # POST：逐项删除，AJAX 返回结果
    url = request.form.get('url', '')
    ok = _delete_upload_file(url)
    return jsonify(ok=ok)
```

**必须**跳过三类：

- `avatar/` —— 头像不在文章正文里引用；
- `projects/` —— README 图片由项目缓存引用，不在文章里；
- 隐藏目录 —— `.originals` 是原图备份。

**⚠️ 清理是「按 URL 字符串比对」**，所以：

- 文章里写的是相对路径 `../uploads/x.jpg` 时匹配不上；
- 大小写差异匹配不上；
- 百分号编码已由 `_extract_upload_urls` 归一，但孤儿扫描端用的是 `rel` 原路径，两边要一致。

### 12.9 `_delete_upload_file` 的防护

```python
def _delete_upload_file(url):
    if not url.startswith('/uploads/'):
        return False
    rel = urllib.parse.unquote(url[len('/uploads/'):])
    if rel.startswith('.') or '/.' in rel:
        return False
    parts = rel.split('/')
    if parts and parts[0] in ('avatar', 'projects'):
        return False                            # 受保护目录
    full = os.path.normpath(os.path.join(UPLOAD_DIR, rel))
    if not os.path.abspath(full).startswith(os.path.abspath(UPLOAD_DIR) + os.sep):
        return False                            # 目录穿越
    try:
        os.remove(full)
        _prune_empty_dirs(os.path.dirname(full))
        return True
    except OSError:
        return False
```

**四条防护缺一不可**：协议前缀、隐藏目录、受保护目录、路径归一。

### 12.10 实现陷阱

1. **`request.files` 在 `MAX_CONTENT_LENGTH` 超限时抛 413**，Flask 会直接返回 HTML 错误页。编辑器（Vditor）期望 JSON，所以要注册 413 handler 返回 JSON。
2. **`file.save()` 前必须把文件读进内存判断大小**，否则 20MB 限制失效（Werkzeug 会先落临时文件）。
3. **`%Y/%m` 分目录必须用当前时间**，不是文章创建时间。同一篇文章补图会落在不同月份目录，这是预期行为。
4. **重名递增要检查磁盘存在性**，不是数据库。同名文件可能来自不同文章。
5. **水印重刷是后台线程 + `PIL` 全量遍历**，大站（>10k 图）会跑很久。`_WM_REF_DONE` 事件保证不并发，但**不保证进程重启后继续**。
6. **`_watermark_text` 依赖 `request.host`**。后台线程里没有请求上下文，调用会抛 `RuntimeError`。上游在启动线程前把文本算好再传进去，复刻时别在线程内取。

---

## §13 外部集成

### 13.1 GitHub 仓库元数据

```python
def fetch_github_repo(url, token=None):
    slug = parse_github_repo(url)          # https://github.com/a/b(.git) → 'a/b'
    if not slug:
        last_gh_error = '不是有效的 GitHub 仓库地址'
        return None
    data = json.loads(_http_get_text_auto(
        f'https://api.github.com/repos/{slug}', _github_headers()))
    ...
    # 再拉 /languages 取全部语言占比
    languages = sorted([(name, round(v * 100 / total, 1)) ...], key=lambda x: -x[1])
    return {'name', 'description', 'url', 'stars', 'language',
            'languages', 'topics', 'default_branch'}
```

`parse_github_repo` 必须兼容：

- `https://github.com/owner/repo`
- `https://github.com/owner/repo.git`
- `git@github.com:owner/repo.git`
- 末尾带 `/` 或 `#readme`

**错误文案必须区分**：

| 状态 | 文案 |
| --- | --- |
| 403 | GitHub API 配额已用尽，请配置 Token 或稍后再试 |
| 404 | 仓库不存在或为私有仓库 |
| 401 | Token 无效 |

**⚠️ 401 自动匿名重试**：

```python
def _http_get_text_auto(url, headers, timeout=8):
    try:
        return _http_get_text(url, headers, timeout)
    except urllib.error.HTTPError as e:
        if e.code == 401 and headers.get('Authorization'):
            h2 = dict(headers); h2.pop('Authorization', None)
            return _http_get_text(url, h2, timeout)
        raise
```

这让「配置了过期 Token」不至于让公开仓库也拉不到。

### 13.2 README 拉取

优先级：

1. `raw.githubusercontent.com/{slug}/{branch}/{README.md|readme.md|Readme.md|README.markdown}`
2. 分支依次尝试 `default_branch` → `main` → `master`
3. 全失败 → `api.github.com/repos/{slug}/readme`（base64 解码，能覆盖自定义路径）

**为什么优先 raw**：`raw.githubusercontent.com` **不计入 API 的 60 次/小时配额**。详情页频繁刷新不会耗尽限额。

**⚠️ raw 网络不通时要 `break` 出分支循环**，直接走 API 兜底，不要 3 个分支 × 4 个文件名 = 12 次超时（每次 8 秒 = 96 秒）。

### 13.3 README 渲染

```python
def render_readme_html(md, slug, branch):
    if not md:
        return None
    md = _BARE_DETAILS_RE.sub(r'<details\1 markdown="1">', md)   # 裸 <details> 注入
    html = markdown.markdown(md, extensions=[
        'fenced_code', 'tables', 'nl2br', 'sane_lists', 'md_in_html'])
    html = _absolutize_readme_urls(html, slug, branch or 'main')
    return _sanitize_html(html)
```

`_absolutize_readme_urls`：

```python
def _fix(m):
    attr, url = m.group(1), m.group(2)
    if re.match(r'^(?:[a-z][a-z0-9+.-]*:|//|#)', url, re.I):
        return m.group(0)                       # 已是绝对地址/协议相对/锚点
    target = base_raw if attr == 'src' else base_blob
    return f'{attr}="{target}{url.lstrip("/")}"'
```

- `src` → `raw.githubusercontent.com/...`（图片要原始字节）
- `href` → `github.com/.../blob/...`（链接要 GitHub 页面）

**⚠️ `<details>` 修复是必需的**：GitHub 风格 README 常写：

```html
<details>
<summary>更新日志</summary>

## v2.3.46
- **修复**：...

</details>
```

Python-Markdown 默认把块级 HTML 整体透传，块内 Markdown 不转换，展开后是裸源码。注入 `markdown="1"` + `md_in_html` 后正常渲染。

**⚠️ `_sanitize_html` 是正则消毒器，不是安全边界**。它能挡 `<script>`、`onerror=` 等常见向量，但绕过方式很多。README 内容来自 GitHub，信任度中等；若同步的是不可信仓库，必须换成 `bleach`。

### 13.4 README 图片本地化

```text
同步时
  ├─ 正则找出 <img src="https://raw.githubusercontent.com/{slug}/...">
  ├─ ThreadPoolExecutor(max_workers=4) 并发下载
  │    ├─ raw 直连（15s）
  │    ├─ 失败 → api.github.com/repos/{slug}/contents/{path}?ref={branch}
  │    └─ 单图 8MB 上限
  ├─ 文件名 = md5(完整 URL) + 扩展名（魔数兜底识别）
  ├─ 写 uploads/projects/{slug}/readme/
  ├─ 替换 src 为 /uploads/projects/{slug}/readme/xxx.png
  └─ 清理本次不再引用的旧文件
```

**⚠️ 线程池里不能调 `url_for`**（无 app context）。上游让子线程只返回文件名，URL 拼接在主线程做。

**⚠️ `_prune_readme_images` 只删「本次新 HTML 未引用」的文件**。若下载失败的图保留了 GitHub 原 URL，下次同步成功后会重新下载新文件，旧的会被清理。这是幂等的。

### 13.5 项目缓存

三层：

| 层 | 位置 | 生命周期 |
| --- | --- | --- |
| 内存 | `_PROJECT_GH_CACHE = {slug: {'ts','gh','readme','branch','error'}}` | 进程 |
| 磁盘 | `data/project_gh_cache.json` | 持久 |
| 快照 | `_PERSIST_CACHE_SNAP = [(mtime,size), key, parsed]` | 进程（避免每请求读盘） |

```python
def project_cache_snapshot():
    """磁盘为权威（多 worker 一致），带 mtime+size 快照避免重复解析。"""
    try:
        st = os.stat(_PROJECT_CACHE_FILE)
        key = (st.st_mtime_ns, st.st_size)
        if _PERSIST_CACHE_SNAP[0] != key:
            data = json.load(open(_PROJECT_CACHE_FILE, encoding='utf-8'))
            _PERSIST_CACHE_SNAP[0] = key
            _PERSIST_CACHE_SNAP[2] = data
        return _PERSIST_CACHE_SNAP[2]
    except (OSError, ValueError):
        return _PROJECT_GH_CACHE
```

**⚠️ 必须「磁盘为权威」**：gunicorn 4 worker 下，A worker 同步的项目，B worker 的内存缓存里没有。只读内存会导致详情页随机空白。

### 13.6 后台同步

```python
def _sync_projects_background(projects, single_id=None):
    with _PROJECT_SYNC_LOCK:
        if project_sync_state()['running']:
            return
        _PROJECT_SYNC_STATE.update(running=True, finished=False, total=0, done=0,
                                   ok=0, failed=0, current='', summary='',
                                   saved_at=time.time())
        _save_sync_state()
    for p in targets:
        ...
        _PROJECT_SYNC_STATE['done'] += 1
        _save_sync_state()          # 每步落盘，供其他 worker 轮询
    _PROJECT_SYNC_STATE['running'] = False
    _PROJECT_SYNC_STATE['finished'] = True
```

**必须**落盘 `data/project_sync_state.json`，且用 `tmp + os.replace` 原子写。

`_load_sync_state` 有一个细节：**完成状态超过 10 分钟自动清零**，避免重启后页面一直挂着「同步完成」。

### 13.7 SMTP

```python
def _smtp_send(to_addr, subject, html, overrides=None):
    cfg = overrides if overrides is not None else app.config
    host = (cfg.get('smtp_host') or '').strip()
    if not host or not to_addr:
        raise ValueError('SMTP 未配置')
    port = int(cfg.get('smtp_port') or 465)
    user = (cfg.get('smtp_user') or '').strip()
    pwd  = cfg.get('smtp_pass') or ''
    sender = (cfg.get('smtp_sender_name') or '').strip() or app.config.get('blog_name') or 'Blog'
    msg = MIMEText(html, 'html', 'utf-8')
    msg['Subject'] = Header(subject, 'utf-8')
    msg['From'] = formataddr((sender, user or to_addr))
    msg['To'] = to_addr
    if port == 465:
        s = smtplib.SMTP_SSL(host, port, timeout=15)
    else:
        s = smtplib.SMTP(host, port, timeout=15)
        s.ehlo(); s.starttls(); s.ehlo()
    if user:
        s.login(user, pwd)
    s.sendmail(user or to_addr, [to_addr], msg.as_string())
    s.quit()
```

**必须**按端口选协议：465 是隐式 SSL，587/25 是 STARTTLS。搞错会卡到超时。

**⚠️ 发信人地址用 `user`**：很多 SMTP 服务商拒绝 `From` 与登录账号不一致的邮件（QQ 邮箱、163 等）。

`overrides` 用于「测试邮件」：用表单里的临时配置试发，不落库、不改全局。

### 13.8 服务监控

```python
MONITOR_INTERVAL = 300

def probe_url(url):
    """返回 {'ok','latency_ms','cert_days','detail'}。"""
    t0 = time.time()
    try:
        req = urllib.request.Request(url, headers={'User-Agent': 'infowe-Monitor'})
        with urllib.request.urlopen(req, timeout=10) as resp:
            code = resp.status
        latency = int((time.time() - t0) * 1000)
        cert_days = _cert_days_left(url)      # 仅 https
        return {'ok': 200 <= code < 400, 'latency_ms': latency,
                'cert_days': cert_days, 'detail': f'HTTP {code}'}
    except Exception as e:
        return {'ok': 0, 'latency_ms': int((time.time() - t0) * 1000),
                'cert_days': -1, 'detail': str(e)[:200]}
```

**证书到期**：手写 DER 解析（`_tlv_next`），从证书里取 `notAfter`，不依赖 `cryptography`。

```python
def _cert_days_left(url):
    p = urllib.parse.urlparse(url)
    if p.scheme != 'https':
        return -1
    host = p.hostname
    port = p.port or 443                      # 必须用 URL 实际端口
    ctx = ssl.create_default_context()
    with socket.create_connection((host, port), timeout=10) as sock:
        with ctx.wrap_socket(sock, server_hostname=host) as ssock:
            der = ssock.getpeercert(binary_form=True)
    not_after = _parse_cert_not_after(der)
    return max(-1, (not_after - datetime.now(timezone.utc)).days)
```

**⚠️ 端口必须取 URL 实际值**。写死 443 时，监控 `https://example.com:8443` 会连错端口。

**⚠️ `server_hostname=host` 不可省**：SNI 缺失会让多域名服务器返回默认证书，到期时间可能是别人的。

**存储策略**：

```python
# 每个服务独立小事务，避免一个服务失败回滚全部
for svc in services:
    result = probe_url(svc['url'])
    db.execute("INSERT INTO service_checks (...) VALUES (...)", (...))
    db.execute("""DELETE FROM service_checks WHERE service_id=? AND id NOT IN (
                    SELECT id FROM service_checks WHERE service_id=?
                    ORDER BY checked_at DESC LIMIT 2000)""", (sid, sid))
    db.commit()
```

**⚠️ 每服务保留 2000 条**，5 分钟一条约 7 天。24h 可用率只查最近 288 条，但保留更久便于排查。

**SSRF 防护**：

```python
def _clean_monitor_url(url):
    p = urllib.parse.urlparse(url)
    if p.scheme not in ('http', 'https'):
        return None
    host = p.hostname
    try:
        ip = ipaddress.ip_address(host)
        if ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_reserved:
            return None
    except ValueError:
        if host in ('localhost',) or host.endswith('.local'):
            return None
    return url
```

**⚠️ 只校验字面量域名不够**：`http://127.0.0.1.nip.io` 会解析到回环。**建议**在 `probe_url` 里 `socket.getaddrinfo` 后再校验一次 IP。

**线程启动条件**：

```python
def _start_monitor_thread():
    if os.environ.get('WERKZEUG_RUN_MAIN') == 'true' or not app.debug:
        threading.Thread(target=_monitor_loop, daemon=True).start()
```

**⚠️ 不加这个判断，`flask run` 的 reloader 会启两个线程**，每个周期写两份数据。

### 13.9 云到期查询

**阿里云**（RPC 风格，HMAC-SHA1）：

```python
canonical = '&'.join(f'{k}={_rfc3986(params[k])}' for k in sorted(params))
string_to_sign = 'GET&%2F&' + _rfc3986(canonical)
signature = base64.b64encode(
    hmac.new((sk + '&').encode(), string_to_sign.encode(), hashlib.sha1).digest()
).decode()
```

- 轻量应用服务器：`swas.{region}.aliyuncs.com`，`Action=ListInstances`，`Version=2020-06-01`
- ECS：`ecs.{region}.aliyuncs.com`，`Action=DescribeInstances`，`Version=2014-05-26`

**⚠️ 两种产品的返回结构不同**：ECS 是 `data.Instances.Instance[]`，SWAS 是 `data.Instances[]`。

**⚠️ 按 `InstanceIds` 过滤查不到时要全量重查一次**（用户可能填错 ID），但不能无限重试。

**腾讯云**（TC3-HMAC-SHA256）：

```python
secret_date = hmac.new(('TC3' + sk).encode(), date.encode(), hashlib.sha256).digest()
```

**⚠️ `'TC3' + sk` 这个前缀是必须的**，官方 SDK 内部做了，手写签名时最容易漏。漏了会一直报 `AuthFailure.SignatureFailure`。

**失败回退**：云 API 不可用时读 `expiry_aliyun` / `expiry_tencent` 手填日期。

### 13.10 头像代理

```python
@app.route('/avatar/<key>/<int:size>.png')
def avatar_proxy(key, size):
    # key: 'e' + md5(邮箱) 或 'q' + QQ 号
    cache = os.path.join(STATIC_CACHE, 'avatars', f'{key}_{size}.png')
    if os.path.isfile(cache) and time.time() - os.path.getmtime(cache) < _AVATAR_MAX_AGE:
        return send_file(cache, mimetype='image/png')
    for src in _avatar_sources(key, size):      # Cravatar → WeAvatar → qlogo
        data = _fetch_image_bytes(src, timeout=8)
        if data:
            os.makedirs(os.path.dirname(cache), exist_ok=True)
            open(cache, 'wb').write(data)
            return send_file(io.BytesIO(data), mimetype='image/png')
    abort(404)                                  # 前端 <img onerror> 换默认头像
```

**为什么走代理**：

1. qlogo 对非 40/100/640 的 `s` 参数返回 400；
2. 部分出口 IP 被风控 403；
3. 个别请求 TCP 挂起，页面一直转圈。

代理后浏览器只连本站，失败由前端本地 `default-avatar.svg` 兜底。

**⚠️ `_qq_avatar_size` 必须吸附到 40/100/640**：

```python
def _qq_avatar_size(size):
    return 40 if size <= 40 else (100 if size <= 100 else 640)
```

**⚠️ 缓存 15 天**，过期重取。用户换头像后最多 15 天生效。若要即时，后台加「清头像缓存」按钮。

### 13.11 实现陷阱

1. **所有外部请求都要设超时**（GitHub 8s、README 图 15s、SMTP 15s、监控 10s、升级下载 60s）。没有超时的 `urlopen` 会永久挂住 worker。
2. **`_open_url` 要禁用系统代理**（`urllib.request.ProxyHandler({})`），否则服务器上的 `HTTP_PROXY` 会让内网请求走错出口。
3. **证书校验失败的降级要显式**：只对已知的 `CERTIFICATE_VERIFY_FAILED` 降级，不要 `except Exception: 不验证`。
4. **GitHub Token 存在 `settings` 表里是明文**。数据库泄露 = Token 泄露。**建议**用环境变量。
5. **`_sanitize_html` 与 `_sanitize_stats_code` 都不是安全边界**，只用于「减少明显的坏输入」。

---

## §14 导出、备份与在线升级

这一章是「运维面」的实现，也是整个系统风险最高的部分：在线升级本质上是把远端代码直接覆盖到运行目录，**没有任何签名校验**。复刻时必须原样理解它做了什么、以及哪里不该照抄。

### 14.1 备份根目录

```python
BACKUP_DIR = os.path.join(BASE_DIR, 'backups')
```

- 位于项目根（不是 `data/`），因为升级时会跳过 `backups`（见 14.7 的 `UPGRADE_SKIP`）。
- 目录不存在时由 `admin_export()` 用 `os.makedirs(BACKUP_DIR, exist_ok=True)` 惰性创建。
- 备份文件名格式：`blog_backup_YYYYmmdd_HHMMSS.db`；升级前备份是 `backups/upgrade_<ts>_<tag>/`。

### 14.2 导出页 `/admin/export`

`admin_export()`（[app.py#L6302-L6328](file:///workspace/infowe_blog/app.py#L6302-L6328)）：

1. 列 `BACKUP_DIR` 下的普通文件，**按文件名倒序**（时间戳命名，等价于时间倒序）。
2. 每个文件生成 `{filename, size, mtime}`；`size` 是人读串：`< 1MB` 用 `KB`（一位小数），否则 `MB`（一位小数）。
3. 统计七张表的行数：`posts / projects / links / comments / timeline / categories / settings`。
4. 渲染 `admin/export.html`，传 `backups`、`stats`、`blog_db`（数据库文件名，用于界面提示）。

**⚠️ 统计用的是 `for t in [...]` + f-string 拼表名**。表名是硬编码常量，安全；但复刻时不要把它改成接受用户输入的参数。

### 14.3 数据库备份 `/admin/export/db-backup`（POST）

```python
ts = datetime.now().strftime('%Y%m%d_%H%M%S')
backup_name = f'blog_backup_{ts}.db'
shutil.copy2(DB_PATH, os.path.join(BACKUP_DIR, backup_name))
```

**⚠️ 这是本系统最危险的一处「看起来正确」的实现**。数据库启用了 WAL 模式（见 §4.1），已提交但尚未 checkpoint 的数据在 `blog.db-wal` 里。直接 `copy2` 主库文件得到的是**某个旧快照**，可能丢失最近若干事务；如果同时有写入，还可能拷到 torn page。

**复刻时建议改成一致性备份**，任选其一：

```python
# 方案 A：SQLite 在线备份 API
src = sqlite3.connect(DB_PATH)
dst = sqlite3.connect(backup_path)
with dst:
    src.backup(dst)
src.close(); dst.close()

# 方案 B：VACUUM INTO（SQLite ≥ 3.27）
db.execute("VACUUM INTO ?", (backup_path,))
```

方案 B 更简单，且产出的是紧凑、无碎片的单文件，缺点是会短暂占锁并消耗 IO。

### 14.4 下载与删除

```python
@app.route('/admin/export/download/<filename>')
@admin_required
def admin_export_download(filename):
    safe_name = secure_filename(filename)
    fp = os.path.join(BACKUP_DIR, safe_name)
    if not os.path.isfile(fp):
        abort(404)
    return send_file(fp, as_attachment=True, download_name=safe_name)
```

删除（POST）：

```python
safe_name = secure_filename(filename)
fp = os.path.join(BACKUP_DIR, safe_name)
if os.path.isfile(fp):
    os.remove(fp)
    flash(f'已删除：{safe_name}', 'success')
else:
    flash('文件不存在', 'error')
```

**关键点**：

- `secure_filename()` 会把中文与 `..` 剥掉，`../../etc/passwd` → `etc_passwd`，路径穿越被阻断。
- 下载用 `send_file(..., as_attachment=True)`，浏览器不会内联渲染 `.db`。
- 删除是 POST，不会被预取/爬虫误触发（对比 `/admin/logout` 是 GET，见 §16）。

**⚠️ `secure_filename` 不是万能的**：它对空结果返回 `''`，此时 `fp` 等于 `BACKUP_DIR` 本身，`isfile` 为假走 404，行为正确。但如果复刻时改成「目录不存在就创建」，就会出问题。

### 14.5 全站 JSON 导出 `/admin/export/json`

```python
data = {}
data['posts']      = [dict(p) for p in db.execute('SELECT * FROM posts ORDER BY id')]
data['projects']   = [dict(p) for p in db.execute('SELECT * FROM projects ORDER BY id')]
data['links']      = [dict(l) for l in db.execute('SELECT * FROM links ORDER BY id')]
data['comments']   = [...LEFT JOIN posts 取 post_title...]
data['timeline']   = [...]
data['categories'] = [...]
data['settings']   = [... WHERE key NOT LIKE '%password%' ...]
data['exported_at'] = now
```

- 评论导出带 `p.title as post_title`，方便脱离数据库后辨认归属。
- 输出 `json.dumps(..., ensure_ascii=False, indent=2)`，中文不转义、两空格缩进。
- 用 `io.BytesIO` 打包后 `send_file(buffer, mimetype='application/json', as_attachment=True)`，文件名 `blog_export_<ts>.json`。

**⚠️ `key NOT LIKE '%password%'` 是黑名单**，只挡 `admin_password` 这类键。`smtp_pass`、`github_token`、`aliyun_sk`、`tencent_sk`、`otp_secret` 都会**原样导出**。**建议**改成白名单：显式列出可导出的 `settings` 键，或用 `_strip_secrets()` 按后缀（`_pass`、`_secret`、`_token`、`_sk`、`_key`）过滤。

### 14.6 Markdown 打包导出 `/admin/export/markdown`

只导 `status != 'draft'` 的文章，按 `created_at DESC`。分类名通过 `{id: name}` 字典查。

每篇生成一个 `<slug>.md`，内容 = YAML front matter + 正文原文：

```yaml
---
title: 文章标题
slug: hello-world
date: 2026-10-23
status: published
tags:
  - Python
  - Flask
category: 后端
read_time: 3
cover: /uploads/2026/10/xxx.jpg      # 有才输出
excerpt: 摘要                         # 有才输出
---
```

**实现细节**：

- `tags` 存的是 JSON 字符串，先 `json.loads`；解析失败要回退为空列表（上游写法是 `isinstance(p.get('tags'), str)` 判断后 `json.loads`，没有 try，脏数据会 500，复刻时应补）。
- 列表型字段（`tags`）逐项写成 `  - item`；标量直接 `k: v`。
- 文件名清洗：`re.sub(r'[<>:"/\\|?*]', '-', p['slug'])`，只处理 Windows 非法字符，**保留中文**。
- 不打包图片，`cover` 与正文里的 `/uploads/...` 都是绝对站内路径。**复刻时若要做可迁移导出，应把图片一并打进去并改写引用**。

### 14.7 升级常量

```python
UPGRADE_REPO = 'Contribuv/infowe_blog'
UPGRADE_RELEASE_URL = f'https://github.com/{UPGRADE_REPO}/releases/latest'
UPGRADE_GITEE_REPO = (os.environ.get('UPGRADE_GITEE_REPO', 'infowe/infowe_blog') or '').strip('/')
UPGRADE_MAX_BYTES = 200 * 1024 * 1024
UPGRADE_LOCK_TTL = 600
UPGRADE_CACHE_FILE = BASE_DIR/data/upgrade_cache.json
UPGRADE_MIRRORS = [...]         # 环境变量 UPGRADE_MIRRORS，默认 https://ghproxy.net/
UPGRADE_DOWNLOAD_TIMEOUT = 60   # 环境变量可覆盖
```

`UPGRADE_SKIP` —— 升级时**绝不覆盖**的路径集合：

```python
UPGRADE_SKIP = {
    'data', 'static/uploads', 'uploads', 'backups', 'posts',
    '.git', '__pycache__', '.venv', 'venv',
    '.env', '.flaskenv', 'upgrade.lock', '*.db', '*.session',
}
```

**⚠️ 这个集合是升级功能的安全底线**。漏掉任何一项，升级都会覆盖用户数据：

| 漏掉的项 | 后果 |
|---|---|
| `data` | `blog.db`、`.secret_key`、上传缓存全被仓库里的空目录/占位文件覆盖 |
| `uploads` | 用户全部图片丢失 |
| `.env` | 用户配置的 `BLOG_SECRET_KEY` 被示例值覆盖 → 所有 session 失效，且可能退回弱密钥 |
| `*.db` | 若有人把数据库放在根目录，会被覆盖 |
| `upgrade.lock` | 锁被覆盖会导致并发升级 |

注意 `UPGRADE_SKIP` 里同时列了 `uploads` 与 `static/uploads`，因为历史版本上传目录在 `static/` 下（见 §3.1 的 `OLD_UPLOAD_DIR`），老用户升级过来时两个目录都可能存在。

### 14.8 版本检测 `check_latest_version(force=False)`

```python
if not force and UPGRADE_CACHE.get('t', 0) and now - UPGRADE_CACHE['t'] < 600:
    return cached
```

- **成功与失败都缓存 10 分钟**。国内服务器访问 GitHub 常超时，不缓存会把每个后台页面都拖慢 6 秒。
- 源 1：`https://api.github.com/repos/{repo}/releases/latest`，`Accept: application/vnd.github+json`，`timeout=6`。
- 源 2：`https://gitee.com/api/v5/repos/{repo}/releases/latest`，`timeout=6`（无 SSL context）。
- 解析：`tag = (data.get('tag_name') or '').strip().lstrip('v')`，再用 `parse_version` 提取三元组。
- **tag 归一化**：`'.'.join(map(str, ver))`。Gitee 建发行版时容易把标题填进标签（`v1.3.51：安全加固`），下载 URL 只认规范 tag，所以必须重写。若不归一化，下载地址会变成 `.../v1.3.51：安全加固.zip` → 404。
- `body` 截 2000 字符；`published_at` 截 10 字符（只要日期）。
- 返回 `{tag, version, html_url, body, published_at, source}`，`source` 为 `'github'` 或 `'gitee'`。

**缓存落盘**：

```python
def _load_upgrade_cache():
    ...
    info = data.get('info')
    if isinstance(info, dict) and isinstance(info.get('version'), list):
        info['version'] = tuple(info['version'])
```

**⚠️ 这个 `tuple()` 还原不能省**。`json.dump` 把 tuple 序列化成 list，读回来若不还原，`info['version'] > cur_ver` 就是 `list > tuple` → `TypeError`，后台每个页面（`inject_globals` 里算了 `upgrade_available`）直接 500。

写入用 tmp + `os.replace` 原子替换，失败静默（`except OSError: pass`）。

### 14.9 下载 `_upgrade_download(url, dest, max_bytes=None, alt_urls=None)`

```python
attempts = [url] + [m + url for m in UPGRADE_MIRRORS] + list(alt_urls or [])
```

三级降级：

1. 直连 `https://github.com/{repo}/archive/refs/tags/v{tag}.zip`（实际 302 到 `codeload.github.com`）。
2. 每个镜像前缀拼接原 URL（`https://ghproxy.net/https://github.com/...`）。
3. `alt_urls`：Gitee 归档包 `https://gitee.com/{repo}/archive/v{tag}.zip`。

流式写盘，边写边查大小：

```python
while True:
    chunk = resp.read(1 << 16)   # 64KB
    if not chunk: break
    f.write(chunk)
    if os.path.getsize(target) > max_bytes:
        raise RuntimeError('下载内容超过大小上限，已取消')
```

**每次失败都要 `os.remove(dest)`**，否则下一轮 `open(target,'wb')` 会从残留文件继续写，最终得到一个半旧半新的坏包（其实 `'wb'` 会截断，但残留文件会影响 `getsize` 判断）。

全部失败时 `raise last_err`，由 `do_upgrade` 外层捕获转成 flash。

### 14.10 覆盖代码 `_upgrade_apply(tmp_root, tag)`

```python
def skip(rel):
    rel = rel.replace('\\', '/')
    for name in UPGRADE_SKIP:
        if name in ('*.db', '*.session'):
            if rel.endswith(name[1:]):
                return True
        elif rel == name or rel.startswith(name + '/'):
            return True
    return False
```

遍历解压目录：先剪枝 `dirnames`（跳过整棵子树），再逐文件 `shutil.copy2` 到 `BASE_DIR`，计数返回。

**关键点**：

- `rel == name or rel.startswith(name + '/')` 是精确前缀匹配。用 `rel.startswith(name)` 会把 `datax/`、`uploads2/` 也误跳过。
- 通配项 `*.db` 用 `name[1:]`（即 `.db`）配合 `endswith`，只匹配后缀。
- `copy2` 保留 mtime，这样静态资源的 mtime 版本号（§9.5）在升级后会变化，浏览器能拿到新文件。
- 返回 `replaced == 0` 视为失败（说明压缩包结构不对）。

### 14.11 主流程 `do_upgrade(tag)`

**加锁**：

```python
lock_path = os.path.join(BASE_DIR, 'upgrade.lock')
if os.path.exists(lock_path) and time.time() - os.path.getmtime(lock_path) > UPGRADE_LOCK_TTL:
    os.remove(lock_path)           # 过期锁自动清理
fd = os.open(lock_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)   # 原子创建
```

- `O_CREAT | O_EXCL` 是原子的，多 worker 并发只有一个能成功，其余抛 `FileExistsError` → 返回「升级任务已在进行中」。
- `UPGRADE_LOCK_TTL = 600` 秒：升级卡死/进程被杀时，10 分钟后可重试，不会永久锁死。

**六步**：

1. **备份**：`backups/upgrade_<ts>_<tag>/` 下放 `blog.db`（`copy2`）与 `uploads/`（`copytree(dirs_exist_ok=True)`）。同样存在 14.3 的 WAL 一致性问题。
2. **下载**：`_upgrade_download(...)`。
3. **安全解压**：

```python
target = os.path.normpath(os.path.join(tmp, zi.filename))
if not target.startswith(tmp + os.sep):
    raise RuntimeError('压缩包内含非法路径，已中止')
if zi.file_size > UPGRADE_MAX_BYTES:
    raise RuntimeError('压缩包内单个文件过大，已中止')
```

   拒绝 `../` 路径穿越（正常 `normpath` 后必须仍在 `tmp` 下），拒绝单文件超 200MB（防 zip bomb）。
4. **定位根目录 + 版本校验**：压缩包顶层通常有一个 `infowe_blog-1.3.64/` 目录，若 `os.listdir` 里恰好只有一个目录就进去；否则认为根就是 `tmp`。必须存在 `app.py`。然后：

```python
m = re.search(r"VERSION\s*=\s*['\"]([^'\"]+)['\"]", src_code)
new_ver = parse_version(m.group(1)) if m else None
if not new_ver or new_ver <= cur_ver:
    raise RuntimeError('下载的版本不高于当前版本，已中止')
```

5. **覆盖**：`_upgrade_apply(root, tag)`。
6. **收尾**：`finally` 里删临时目录、删锁文件。

返回 `(True, '升级成功：代码已从 v{VERSION} 更新为 v{tag}（替换 N 个文件）。数据已自动备份到 ...，请重启服务生效。')`。

**⚠️ 这是本系统最大的安全缺口**：整个链路只校验「新 `app.py` 里的 VERSION 字符串比当前大」，**没有 GPG 签名、没有 SHA256 校验、没有 TLS pinning**。任何一个环节（GitHub 账号、镜像站、Gitee 镜像仓库、DNS）被投毒，攻击者提交一个 `VERSION='99.0.0'` 的包，就能让站点执行任意代码。生产环境**建议禁用该功能**，改用「SSH 登录 → git pull → systemctl restart」的人工流程。

**⚠️ 升级后不会自动重载进程**，提示文案写的是「请重启服务生效」。gunicorn 不重启就一直跑旧代码（`.py` 已替换但模块已加载）。若复刻时想自动化，需要 `os.execv` 或发信号给 master，难度和风险都更高。

### 14.12 升级路由

**`/admin/upgrade`（GET/POST）**

- GET：页面立即渲染（`info=None, upgradable=False`），版本检测交给前端异步打 `/admin/upgrade/check`。**这是刻意的**：GitHub 在国内可能卡 6 秒，同步检测会让后台整页白屏。
- POST：`check_latest_version(force=True)` → 若 `info['version'] <= cur_ver` 则 flash「当前已是最新版本」→ 否则 `do_upgrade(info['tag'])`，异常统一捕获成「升级失败：<原因>」。

**`/admin/upgrade/check`（GET，JSON）**

```json
{
  "ok": true,
  "current_version": "1.3.63",
  "latest_version": "1.3.64",
  "tag": "1.3.64",
  "upgradable": true,
  "published_at": "2026-10-20",
  "body": "原始 Markdown 变更说明",
  "body_html": "<p>渲染后的 HTML</p>",
  "release_url": "https://github.com/.../releases/tag/v1.3.64",
  "source": "github"
}
```

`?force=1` 跳过 10 分钟缓存。`body_html` 由 `_md_to_safe_html(body)` 生成。

### 14.13 三个消毒函数

```python
def _sanitize_html(html):
    html = re.sub(r'<(script|iframe|object|embed|svg)\b[^>]*>.*?</\1>', '', html, flags=re.S | re.I)
    html = re.sub(r'<(script|iframe|object|embed|svg)\b[^>]*/?>', '', html, flags=re.S | re.I)
    html = re.sub(r'\son\w+\s*=\s*(?:"[^"]*"|\'[^\']*\'|[^\s>]+)', '', html, flags=re.I)
    html = re.sub(r'javascript\s*:', '', html, flags=re.I)
    html = re.sub(r'data\s*:\s*text/html', '', html, flags=re.I)
    html = re.sub(r'<form\b[^>]*>.*?</form>', '', html, flags=re.S | re.I)
    return html

def _sanitize_stats_code(html):
    # 只保留 <script>，剥掉其他标签与事件
    html = re.sub(r'\son\w+\s*=\s*...', '', html, flags=re.I)
    html = re.sub(r'javascript\s*:', '', html, flags=re.I)
    html = re.sub(r'<(?!(script\b|/script>)).*?>', '', html, flags=re.I)
    return re.sub(r'\n\s*\n+', '\n', html).strip()

def _md_to_safe_html(text):
    return _sanitize_html(markdown.markdown(text, extensions=['fenced_code', 'nl2br']))
```

**⚠️ 正则消毒器不是安全边界**。`<scr<script>ipt>`、`<img src=x onerror=...>` 的变体、SVG 命名空间技巧都能绕过。这里它们只用于「降低明显坏输入的危害」。真正需要安全时应改用 `bleach` 或 `nh3`（Rust 实现，白名单式）。

`_sanitize_stats_code` 的用途特殊：它保留 `<script>` 是因为统计代码本身就长这样（百度统计/GA 都是 `<script>...</script>`），但**剥掉了所有非 script 标签**。结果：`<script src="..."></script>` 会被保留（`<script` 与 `/script>` 都在白名单），`<div>` 被剥掉。这等价于「只允许 JS，不允许 HTML」。

**⚠️ `stats_code` 在模板里是 `| safe` 注入的**，所以它等价于「管理员可写任意 JS」。配合 §16 的「单管理员信任模型」可以接受，但在多用户/多角色系统里绝对不行。

### 14.14 实现陷阱

1. **WAL 下 `shutil.copy2(blog.db)` 不是一致性备份**，见 14.3。这是最需要改进的一处。
2. **JSON 导出的密码过滤是黑名单**，`smtp_pass` / `github_token` / `*_sk` / `otp_secret` 会裸奔。
3. **升级只校验 VERSION 递增**，等于给远端代码开了 RCE 通道。**建议生产禁用**。
4. **`UPGRADE_SKIP` 必须包含 `data`、`uploads`、`.env`、`*.db`**，漏一个就丢数据。
5. **`_load_upgrade_cache` 必须把 version list 还原成 tuple**，否则后台 500。
6. **`check_latest_version` 失败也要写缓存**，否则国内网络下后台会反复卡 6 秒。
7. **Gitee 的 tag 可能含中文标题**，必须用 `parse_version` 归一化后再拼下载 URL。
8. **`_upgrade_download` 每次失败要清残留文件**，否则大小判定的基线是错的。
9. **解压必须做 `normpath` + 前缀校验**，`zipfile` 不会自动防 `../`。
10. **`zi.file_size` 是解压后大小**，用它判 200MB 能挡住 zip bomb；`compress_size` 挡不住。
11. **锁必须用 `O_EXCL` 原子创建**，先 `exists()` 再 `open()` 有竞态。
12. **锁要有 TTL**，否则进程被杀后永远无法再升级。
13. **升级后必须人工重启**，代码替换不等于进程重载。
14. **`admin_export_download` 的 `secure_filename` 可能返回空串**，此时会命中目录，`isfile` 为假走 404，行为正确但不要改成 `makedirs`。
15. **导出 Markdown 不打包图片**，迁移到别的系统后图片全断。要可迁移就得连 `uploads/` 一起打并改写路径。
16. **`tags` 的 `json.loads` 没有 try**，脏数据会让整个导出 500。
17. **`_sanitize_stats_code` 保留 `<script>` 是设计而非疏漏**，别「顺手修掉」，否则统计代码失效。
18. **`_sanitize_html` 只用于升级日志渲染**，不要用它处理用户提交内容并当成安全过滤。

---

## §15 前端交互

前端是**零框架、原生 JS**，四类文件：全局脚本（`main.js` / `toast.js` / `disable-zoom.js`）、页面级脚本（`comments.js` / `share.js` / `status.js`）、后台脚本（`admin.js`）、以及模板里的内联脚本（防闪烁主题、文章页增强、阅读量上报）。总计约 1425 行。

设计基调：**渐进增强**。所有交互都在「HTML 可用」的基础上叠加，脚本挂了页面仍能读、能提交。

### 15.1 防闪烁主题脚本（内联在 `<head>`）

必须**同步执行、且在 `<link rel=stylesheet>` 之前**，否则会看到一瞬间白底再变黑：

```html
<script>
  (function () {
    try {
      var saved = localStorage.getItem('infowe-theme');
      var mode = 'auto';
      if (saved === 'light' || saved === 'dark' || saved === 'auto') mode = saved;
      document.documentElement.setAttribute('data-theme-mode', mode);
      var dark = window.matchMedia('(prefers-color-scheme: dark)').matches;
      document.documentElement.setAttribute('data-theme', mode === 'auto' ? (dark ? 'dark' : 'light') : mode);
    } catch (e) {}
  })();
</script>
```

**四个要点**：

1. `data-theme-mode` 存「用户意图」（`auto/light/dark`），`data-theme` 存「实际生效值」（`light/dark`）。CSS 只认 `data-theme`，UI 提示认 `data-theme-mode`。
2. 非法值一律回落 `auto`（白名单判断，不是 `saved || 'auto'`）。
3. `try/catch` 必须包住：Safari 隐私模式、部分 WebView 下 `localStorage` 会抛异常。
4. 后台模板（`admin/base.html`、`admin/login.html`、`admin/otp.html`、`admin/forgot.html`、`admin/otp_recover.html`）各自内联同一段，并额外设置 `html.style.colorScheme` 与 `<meta name="theme-color">`。**没有共用 partial**，是复制粘贴的——复刻时可以抽成 `_theme_init.html` 统一 include。

### 15.2 主题三态循环 `main.js`

```js
const THEME_ORDER = ['auto', 'light', 'dark'];   // 后台 admin.js 同序
```

点击顺序：`auto → light → dark → auto`。

```js
function syncTheme() {
  const mode = rootEl.getAttribute('data-theme-mode') || 'auto';
  rootEl.setAttribute('data-theme', mode === 'auto' ? (SYS_DARK.matches ? 'dark' : 'light') : mode);
  ...
}
const onSysTheme = () => {
  if ((rootEl.getAttribute('data-theme-mode') || 'auto') === 'auto') syncTheme();
};
SYS_DARK.addEventListener('change', onSysTheme);
```

**关键点**：

- 系统主题变化只在 `auto` 态跟随。用户手动选了 `dark` 后，系统切到浅色也不应改变。
- 用 `addEventListener('change')` 优先、`addListener` 兜底（兼容老 Safari）。
- 每次切换后调 `animateSkills()`（技能条动画重播），因为 `data-theme` 变化会让部分 CSS 动画重置。
- 按钮的 `aria-label` / `title` 会同步更新成「当前：深色，点击切换主题」，无障碍友好。

**⚠️ 主题切换只改 `data-theme`，不重载页面**，所以依赖主题的 CSS 变量必须全部走 `html[data-theme]` 选择器，不能在 JS 里硬编码颜色。

### 15.3 合并滚动处理器（rAF 节流）

```js
var scrollTicking = false;
window.addEventListener('scroll', function () {
  if (!scrollTicking) {
    requestAnimationFrame(function () {
      var scrollTop = window.scrollY;
      // 1) 阅读进度条
      if (progressBar) {
        var docHeight = document.documentElement.scrollHeight - window.innerHeight;
        progressBar.style.width = Math.min(docHeight > 0 ? (scrollTop / docHeight) * 100 : 0, 100) + '%';
      }
      // 2) 导航栏阴影
      if (navbar) navbar.classList.toggle('scrolled', scrollTop > 50);
      // 3) 回到顶部按钮
      if (backToTop) backToTop.classList.toggle('visible', scrollTop > 500);
      scrollTicking = false;
    });
    scrollTicking = true;
  }
}, { passive: true });
```

三个滚动效果**合并成一个 handler + 一个 rAF**，而不是三个独立监听。`passive: true` 告诉浏览器不会 `preventDefault`，滚动线程不必等 JS。

**⚠️ `scrollTicking` 必须在 rAF 回调里复位**，不能在监听器末尾复位——否则同一帧内多次 scroll 会排多个 rAF。

阈值：导航阴影 `> 50px`，回顶按钮 `> 500px`。

### 15.4 IntersectionObserver 清单

系统用了 5 个独立 observer，全部 `unobserve` 一次即弃：

| 用途 | 元素 | 参数 |
|---|---|---|
| AOS 进场动画 | `[data-aos]` | `threshold: 0.15, rootMargin: '0px 0px -40px 0px'` |
| 数字滚动 | `.stat-number[data-target]` | `threshold: 0.3` |
| 技能条 | `.skills-card` | `threshold: 0.3` |
| 时间线年份高亮 | `#year-<year>` | `rootMargin: '-<navH+12>px 0px -70% 0px'` |
| 评论头像兜底 | `.cmt-avatar-img` | `rootMargin: '300px'` |

**AOS**：

```js
entry.target.classList.add('aos-animate');
var delay = entry.target.getAttribute('data-aos-delay');
if (delay) entry.target.style.animationDelay = delay + 'ms';
observer.unobserve(entry.target);
```

CSS 里 `[data-aos]` 默认 `opacity:0; transform: translateY(20px)`，`.aos-animate` 触发过渡。**⚠️ 若 JS 未加载，元素会永远不可见**。复刻时应加兜底：`<noscript><style>[data-aos]{opacity:1!important;transform:none!important}</style></noscript>`。

**数字滚动**用 `easeOutCubic`：

```js
var eased = 1 - Math.pow(1 - progress, 3);
el.textContent = Math.floor(eased * target);
```

时长 1500ms，结束帧强制写 `target`（避免浮点误差停在 99）。

**时间线年份高亮**：`rootMargin` 负值把「触发带」压到视口上部，滚动时只高亮当前跨过的年份区块。初始高亮第一个年份。

### 15.5 粒子背景

```js
const REDUCED_MOTION = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
if (canvas && !REDUCED_MOTION) { ... }
```

- **尊重 `prefers-reduced-motion`**：系统开了「减少动效」就整个跳过，省 CPU 且无障碍友好。
- 35 个字符粒子（`01{}[]()<>/\|*#@$%&;:,.pydef class import return async await lambda`），速度 0.15–0.55，透明度 0.04–0.29。
- Canvas 尺寸 = **视口**（不是 `scrollHeight`），`resize` 防抖 200ms，只改尺寸不重建粒子。
- 距离 < 80px 的粒子连细线（先做矩形快速排除，避免每对都 `sqrt`）。
- 鼠标光晕用 0.06 的缓动系数独立插值，`transform: translate(...)` 走合成层。
- `visibilitychange` 时 `cancelAnimationFrame`，回来再 `animate()`。
- 每 500ms 读一次 `data-theme` 切换配色（暗色青/紫，亮色深青/深紫）。

**⚠️ 粒子数组预分配**（`particles[i] = new Particle()` 复用对象），`reset()` 而不是 `new`，减少 GC 抖动。

### 15.6 3D 卡片倾斜

```js
if (!('ontouchstart' in window)) {
  document.querySelectorAll('.post-card').forEach(function (card) {
    card.addEventListener('mousemove', function (e) {
      var rect = card.getBoundingClientRect();
      var rotateX = ((e.clientY - rect.top - rect.height / 2) / (rect.height / 2)) * -5;
      var rotateY = ((e.clientX - rect.left - rect.width / 2) / (rect.width / 2)) * 5;
      card.style.transform = 'perspective(800px) rotateX(...) rotateY(...) translateY(-4px)';
    });
    card.addEventListener('mouseleave', function () { /* 复位 */ });
  });
}
```

- **触屏设备整体跳过**：`ontouchstart` 存在就绑都不绑，避免移动端滚动时的抖动与性能损耗。
- 最大倾角 ±5°，`perspective(800px)`，附加 `translateY(-4px)` 制造悬浮感。
- 直接写 `style.transform`（不走 CSS 变量），因为每帧值都不同。

### 15.7 代码复制按钮（两套实现，不重复）

**文章页内联脚本**（`post.html`）：把每个 `<pre>` 包进 `.code-wrap`，复制按钮 `position:absolute` 固定在右上角，**不随代码横向滚动**。按钮用 `navigator.clipboard.writeText`，成功文案「已复制」2 秒后复原。

**全局 `main.js`**：给其他页面的 `.post-content pre, .post-body pre` 加 `.code-copy-btn`，并做三重跳过：

```js
if (pre.parentElement && pre.parentElement.classList.contains('code-wrap')) return;
if (pre.querySelector('.code-copy-btn')) return;
```

**⚠️ 这两个实现必须互相避让**，否则文章页每个代码块会出现两个复制按钮。判据就是「父级是否已是 `.code-wrap`」。

`main.js` 版本还有 `execCommand('copy')` 兜底（非 HTTPS 环境下 `navigator.clipboard` 是 undefined）。

### 15.8 文章页内联增强（`post.html`）

按顺序执行：

1. **媒体包裹**：`video, iframe` 外面套 `.media-wrap`（统一宽高比、圆角、响应式）。
2. **代码块包裹 + 复制按钮**（见 15.7）。
3. **表格包裹**：`table` 外套 `.table-wrap`（横向滚动）。
4. **溢出检测**：

```js
host.classList.toggle('is-scroll-x', pre.scrollWidth > pre.clientWidth + 1);
host.classList.toggle('at-end', el.scrollLeft + el.clientWidth >= el.scrollWidth - 2);
```

   `+1` / `-2` 是亚像素容差。`is-scroll-x` 让 CSS 显示「可横向滑动」遮罩与 `»` 箭头，滑到最右时 `at-end` 让遮罩淡出。
5. **图片 Lightbox**：`content` 内所有 `<img>` 点击打开全屏查看器，支持 `←/→` 切换、`Esc` 关闭、点击遮罩关闭、计数 `3 / 8`。循环取模 `(i + len) % len`。
6. **阅读量上报**（见下）。

**阅读量上报**（`post.html` 底部独立 `<script>`）：

```js
var minMs = 5000, key = 'post_viewed_' + postId;
if (sessionStorage.getItem(key)) return;
var acc = 0;
var timer = setInterval(function () {
  if (document.hidden) return;         // 后台不计时
  acc += 1000;
  if (acc >= minMs) {
    clearInterval(timer);
    sessionStorage.setItem(key, '1');  // 先标记再上报
    fetch('/post/' + postId + '/view', { method: 'POST', keepalive: true });
  }
}, 1000);
```

设计意图：

- **必须停留满 5 秒且页面可见**才计一次，秒开秒关、切后台都不算。
- `sessionStorage` 去重：同一会话内刷新不重复计数，关标签页重开算新会话。
- **先写标记再上报**：即使网络失败也不会重复尝试。
- `keepalive: true`：页面正在关闭时请求仍能完成。
- 兜底 `navigator.sendBeacon(url)`（原注释写的是 fetch 抛错时用 beacon，但 `fetch` 不 await 不会抛网络错，实际 beacon 分支几乎不会走到）。

**⚠️ `post-detail` 的 `data-post-id` 是唯一数据源**，模板里必须有 `data-post-id="{{ post.id }}"`，否则 `Number(... || 0)` 得到 0，向 `/post/0/view` 上报，服务端 404。

### 15.9 `comments.js`（255 行）

**结构约定**：一个 `.cmt-thread` = 一条根评论 + `.cmt-replies` 内平铺的全部回复（**两层，不做无限嵌套**）。

**常量**：

```js
var SHOW_COUNT = 2;    // 折叠时露出 2 条
var COLLAPSE_AT = 3;   // 超过 3 条才折叠
var MAX_LEN = 2000;
var AV_TIMEOUT = 3000;
```

**头像兜底**（在表单检查之前执行，保证没有评论表单的页面也能修头像）：

```js
img.addEventListener('error', function () {
  if (img.src === def) return;
  if (fallback && !img.dataset.fb) { img.dataset.fb = '1'; img.src = fallback; }
  else if (def) { img.src = def; }
});
```

三级回退：主源 → `data-fallback`（备用源）→ `data-default`（本地默认）。另外还有**挂起兜底**：图片进入视口后 3 秒仍未 `complete`（被墙/CDN 卡住），直接切本地默认，避免评论区长白块。

**表单定位**：

```js
function scrollFormIntoView() {
  var rect = form.getBoundingClientRect();
  var vh = window.innerHeight || document.documentElement.clientHeight;
  if (rect.bottom > vh) form.scrollIntoView({ behavior: 'smooth', block: 'end' });
  else if (rect.top < 0) form.scrollIntoView({ behavior: 'smooth', block: 'start' });
}
form.style.scrollMarginTop = '50px';
form.style.scrollMarginBottom = '50px';
```

**只有被视口截断时才滚**。表单本来就完整可见时不做任何滚动，避免「点一下页面莫名跳动」。

**回复**：点 `.cmt-reply` 后

1. 读 `data-reply-to`（父评论 id）写入隐藏域 `#comment-parent-id`；
2. `#comment-replying-name` 显示被回复者昵称；
3. `form.classList.add('is-inline')`；
4. **把整个 form 节点 `appendChild` 到该楼层组 `.cmt-replies` 的末尾**（不是插到已有回复前面）；
5. 若 `<details class="cmt-box">` 是收起的，自动 `open = true`；
6. 滚动定位 + 260ms 后 `textarea.focus({ preventScroll: true })`（延迟是为了等平滑滚动结束，`preventScroll` 防二次跳动）。

取消回复 `resetReply()`：清空 parent id、隐藏提示、移除 `is-inline`、把 form **`insertBefore(form, anchor)`** 搬回原位。

**折叠**：

```js
if (items.length <= COLLAPSE_AT) return;
items.forEach(function (it, i) { it.hidden = !open && i >= SHOW_COUNT; });
```

按钮文案随状态变化：`展开其余 N 条回复` / `收起回复`，`aria-expanded` 同步。收起后 `thread.scrollIntoView({ block: 'start' })`，防止页面突然变矮导致视觉跳位。

**字数统计**：`n + ' / 2000'`，超限加 `.is-over`。**注意这里只提示不阻止输入**，真正的长度限制在提交时和 服务端 §8.4。

**提交防重复**：

```js
if (form.dataset.submitting === '1') { toast('正在提交，请稍候…'); return false; }
if (!textarea || !textarea.value.trim()) { toast('请先填写评论内容'); return false; }
if (textarea.value.length > MAX_LEN) { toast('评论内容不能超过 2000 字'); return false; }
form.dataset.submitting = '1';
submitBtn.disabled = true; submitBtn.textContent = '提交中…';
setTimeout(function () { /* 10 秒后恢复 */ }, 10000);
```

**10 秒兜底恢复**：网络异常时按钮不会永久卡死。代价是如果服务端 10 秒后才响应，用户可能重复提交——服务端还有 30 秒同 IP 冷却（§8.4）兜底。

**待审核提示**：`#cmt-notice` 的关闭状态存 `sessionStorage['cmt_notice_closed']`，同一会话内不再显示。

### 15.10 `admin.js`（185 行）

**主题**：与前台共用 `infowe-theme` 键与 `['auto','light','dark']` 顺序。后台额外做三件事：

```js
html.style.colorScheme = dark ? 'dark' : 'light';       // 原生控件（滚动条/表单）配色
meta.theme-color.content = dark ? '#0f1117' : '#f5f6fa'; // 移动端地址栏配色
```

后台有**两个主题按钮**（顶栏图标 `#admin-theme-toggle` + 侧栏 `#sidebar-theme-toggle`），共用同一套 `applyMode`。侧栏按钮还有文字标签 `.theme-label` 需要同步。

**移动端抽屉（< 992px）**：

```js
sidebar.classList.add('open');
overlay.classList.add('show');
document.body.style.overflow = 'hidden';     // 锁背景滚动
burger.setAttribute('aria-expanded', 'true');
```

关闭路径四条：点击遮罩、点关闭按钮、点任一 `.admin-nav-item` 链接（主题按钮不算）、按 `Esc`。

**Flash 4 秒自消**：

```js
var timer = setTimeout(function () {
  el.style.transition = 'opacity .3s, transform .3s';
  el.style.opacity = '0';
  el.style.transform = 'translateY(-8px)';
  setTimeout(function () { el.remove(); }, 300);
}, 4000);
```

手动点 `.flash-close` 会 `clearTimeout` 并立即移除。

**Slug 自动生成**：

```js
if (!slugInput.dataset.manual) {
  slugInput.value = titleInput.value
    .toLowerCase()
    .replace(/[^\w\s\u4e00-\u9fff-]/g, '')   // 保留中文
    .replace(/\s+/g, '-')
    .slice(0, 60);
}
slugInput.addEventListener('input', function () { slugInput.dataset.manual = '1'; });
```

- 输入中文标题时 slug 也是中文（保留 `\u4e00-\u9fff`），因为路由 `/post/<slug>` 支持 UTF-8。
- **用户一旦手动改过 slug，自动生成就永久关闭**（`dataset.manual = '1'`）。这是正确的：否则改名时会把用户的精心命名冲掉。
- 上限 60 字符，与 §7.6 服务端规则一致。

**批量模式**：

```js
if (!document.querySelector('input.row-check')) return;   // 没有勾选框就不注入按钮
document.body.classList.add('bulk-on');
btn.textContent = on ? '退出批量' : '批量操作';
```

按钮**动态插入**到 `.page-header .page-actions` 末尾（无该容器则创建），因为 6 个列表页（文章/评论/分类/项目/友链/时间线）共用同一套逻辑，模板里不必各写一遍。`Esc` 退出，`aria-pressed` 同步。

**⚠️ 等待 `DOMContentLoaded` 的问题**：`admin.js` 在 `<body>` 底部引入，DOM 已解析完，所以直接执行没问题。如果复刻时把它挪到 `<head>`，必须包一层 `DOMContentLoaded`。

**Ctrl+S / Cmd+S 保存**：

```js
if ((e.ctrlKey || e.metaKey) && e.key === 's') {
  var form = document.getElementById('post-form');
  if (form) { e.preventDefault(); form.submit(); }
}
```

只对 `#post-form`（文章编辑器）生效。`form.submit()` 绕过 `submit` 事件，所以不会触发前端校验——这也是为什么服务端校验必须完整。

### 15.11 `share.js`（237 行）

**纯站内实现，不依赖 Web Share API**（PC 与移动端行为一致，且不需要 HTTPS 之外的权限）。

**打开方式**：`[data-share-open]` 任意元素点击即打开，`data-title` 可选（缺省 `document.title`）。

**四个渠道**：

| 渠道 | 实现 |
|---|---|
| 复制链接 | `navigator.clipboard.writeText(title + '\n' + url)`，非安全上下文走 `textarea + execCommand` |
| 微信 | 本地 `qrcode-generator` 生成 SVG 二维码，扫码后在微信内转发 |
| 微博 | `https://service.weibo.com/share/share.php?url=...&title=...`（新窗口） |
| QQ 空间 | `https://sns.qzone.qq.com/cgi-bin/qzshare/cgi_qzshare_onekey?url=...&title=...` |

**面板结构**：半透明遮罩 + `role="dialog"` `aria-modal="true"` 面板，两个视图（渠道列表 / 二维码）用 `hidden` 切换，**不销毁 DOM**。

**无障碍**：

```js
lastFocused = document.activeElement;
...
var closeBtn = panel.querySelector('[data-share-close]');
if (closeBtn) closeBtn.focus();
...
if (lastFocused && lastFocused.focus) lastFocused.focus();   // 关闭后还原焦点
```

`Esc` 关闭，遮罩点击关闭，`document.body.style.overflow = 'hidden'` 锁背景滚动。

**⚠️ 二维码库是外部依赖**（`qrcode-generator`），要本地引；`typeof window.qrcode !== 'function'` 时显示「二维码组件未加载，请使用复制链接分享」，不报错。

**⚠️ `open()` 每次都要复位状态**：清空二维码容器、`qrRendered = false`、视图切回列表、复制按钮文案复位。否则第二次打开会看到上次的「已复制」或残留二维码。

### 15.12 `status.js`（104 行）

状态页每 **60 秒** 拉一次 `/api/status`：

```js
var INTERVAL = 60000;
setTimeout(poll, 1000);        // 首屏延迟 1 秒
setInterval(poll, INTERVAL);
fetch('/api/status', { cache: 'no-store' })
```

首屏 SSR 已经渲染了数据，1 秒后的首次拉取是为了「刚打开页面就能看到最新探测结果」，之后进入固定轮询。

**增量更新**：按 `data-svc-name` 找行，只改 `st-ok / st-warn / st-down / st-none` class 与三个字段（`latency` / `cert` / `uptime`），**不重建 DOM**。云到期同理，按 `data-expiry-key` 找行。

**相对时间**：`刚刚` / `N 分钟前` / `N 小时前` / `YYYY-MM-DD HH:mm`。

**⚠️ 失败静默**：`.catch(function () {})`，等下一个周期，不弹错误。状态页本身是「展示可用性」的，自己弹错很讽刺。

### 15.13 `toast.js`（95 行）

```js
window.toast(msg, 'success'|'error'|'info', duration)
```

- 默认时长：`success 3600` / `error 6000` / `info 4200` 毫秒。
- **同屏最多 3 条**，超出顶掉最旧的。
- `el.querySelector('.toast-msg').textContent = msg` —— **用 `textContent` 而不是 `innerHTML`**，防注入。
- 两帧 rAF 后才加 `.is-in`，保证 CSS 过渡真正触发（同一帧加 class 不会动画）。
- 鼠标悬停暂停计时，离开后 1600ms 再消失。
- 关闭按钮监听 `click` 与 `keydown`（`Enter` / 空格），键盘可用。
- **后端 flash → Toast**：模板把消息渲染成 `<div data-toast="消息" data-toast-type="success" hidden>`，`toast.js` 在 `DOMContentLoaded` 后统一扫描消费，间隔 120ms 依次弹出。

**⚠️ `data-toast` 里的消息要做 HTML 转义**（Jinja 默认会转），因为 JS 用 `textContent` 读取，转义后显示的是原文。

### 15.14 `disable-zoom.js`（19 行）

```js
document.addEventListener('gesturestart', function (e) { e.preventDefault(); });
var lastTap = 0;
document.addEventListener('touchend', function (e) {
  var now = Date.now();
  if (now - lastTap < 400) e.preventDefault();
  lastTap = now;
}, { passive: false });
```

**iOS 10+ 起 Safari 忽略 `<meta viewport user-scalable=no>`**，必须拦 `gesturestart`（双指捏合）与快速双击（`touchend` 间隔 < 400ms）。

**⚠️ 这是可访问性反模式**：禁用缩放会让低视力用户无法放大阅读。**复刻时建议去掉**，或只在特定「类应用」页面启用。

### 15.15 实现陷阱

1. **防闪烁脚本必须在 `<head>` 里同步执行且早于 CSS**，放到 `</body>` 前会闪一下。
2. **`data-theme-mode` 与 `data-theme` 是两个属性**，别混用：CSS 用后者，JS 逻辑用前者。
3. **系统主题变化只在 `auto` 态跟随**，手动模式必须锁定。
4. **`scrollTicking` 必须在 rAF 回调内复位**。
5. **`[data-aos]` 依赖 JS 才有可见性**，必须加 `<noscript>` 兜底。
6. **3D 倾斜必须跳过触屏**（`ontouchstart`），否则移动端滚动会抖。
7. **两套复制按钮要互相避让**，判据是父级是否 `.code-wrap`。
8. **阅读量上报用 `sessionStorage` 去重 + 5 秒可见停留**，且 `keepalive: true`。
9. **`data-post-id` 缺失会向 `/post/0/view` 上报**。
10. **评论回复表单是「搬移节点」而不是「克隆」**，因为原表单里有用户已输入的内容与服务端错误回显。
11. **`scrollFormIntoView` 只在被截断时滚动**，无条件滚会让人以为页面抽风。
12. **折叠阈值是 `> 3` 条才折叠、露出 2 条**，边界是「4 条起折叠」。
13. **提交按钮 10 秒兜底恢复**，否则网络异常后永久禁用。
14. **`dataset.manual` 一旦置位永不复位**（同一次编辑内），这是对的：保护用户手填的 slug。
15. **批量模式按钮是 JS 动态插入的**，模板里没有；`Esc` 退出。
16. **`share.js` 每次打开都要复位状态**，否则残留上次的二维码/文案。
17. **二维码库缺失要优雅降级**，不能白屏。
18. **`toast` 必须用 `textContent`**，用 `innerHTML` 就是 XSS。
19. **状态页轮询失败要静默**，不要弹错。
20. **禁用缩放是反可访问性设计**，非必要不要抄。

---

## §16 安全要求与已知缺口

这一章把散落在各章的「⚠️」汇总成一张明确的清单，并区分**三类**：

- **A 类：必须保留**（这是系统能安全运行的前提）
- **B 类：复刻时必须修**（原实现有真实缺陷）
- **C 类：可以接受**（在「单管理员 + 个人博客」的信任模型下合理）

### 16.1 信任模型

系统的安全假设只有一句话：

> **唯一管理员 = 完全可信；所有匿名访客 = 完全不可信。**

这条假设解释了大量「看起来不安全」的设计：

- 管理员可以写任意 HTML/Markdown（包括 `<script>`）→ 因为 Markdown 默认透传原始 HTML。
- `stats_code` 可以注入任意 JS → 因为只有管理员能改。
- 没有 CSRF token → 因为登录态只有一个用户，攻击者无法从「另一个用户」那里借权限。

**但如果复刻时改成多作者/多角色，这条假设立刻失效**，A 类的大部分设计都会变成漏洞。这一点必须在架构决策时明确。

### 16.2 A 类：必须保留的安全措施

| 措施 | 位置 | 为什么必须 |
|---|---|---|
| 密码 `pbkdf2:sha256` + 16 字节随机盐 | §6.1 | 防离线爆破；`sha256(pwd+key)` 无盐可彩虹表 |
| 登录失败计数 + 锁定 + 退避 | §6.2 | 防在线爆破，5 次锁 15 分钟 |
| 算术验证码（第 3 次失败起） | §6.2 | 挡住自动化脚本 |
| TOTP 第二因子 + 恢复码一次性消费 | §6.4/§6.5 | 密码泄露后的第二道防线 |
| `admin_required` 的 `_otp_user` 中间态重定向 | §6.3 | 否则可跳过 OTP 直接进后台 |
| 会话密钥从环境变量/随机文件取 | §3.2 | 固定密钥 = 任何人可伪造 session |
| `session.clear()` 登出 | §6.7 | 只 pop 会残留 `_otp_user` |
| 上传扩展名白名单（排除 `.svg`） | §12.1 | SVG 可内嵌脚本 = 存储型 XSS |
| 上传目录隐藏文件拦截 | §12.9 | `.originals` 等目录不能直接访问 |
| `MAX_CONTENT_LENGTH = 32MB` | §3.7 | 防大文件打满内存 |
| `_save_upload` 先读内存判大小 | §12.2 | 否则 20MB 限制形同虚设 |
| 评论默认 `pending` | §8.4 | 防垃圾评论直接上线 |
| 评论同 IP 30 秒冷却 | §8.4 | 防刷屏 |
| `my_comments` 三重校验 | §8.3 | 否则可伪造 id 偷看他人私密评论 |
| 博主昵称保留字拦截 | §8.4 | 防冒充博主 |
| 私密评论仅管理员可见 | §8.4 | 用户明确预期 |
| `SameSite=Lax` | §3.7 | 挡掉大部分跨站 POST |
| 安全响应头（CSP/XFO/nosniff/Referrer） | §3.8 | 基础防护 |
| `ProxyFix` 只信一层 | §3.4 | 否则 IP 可伪造，限流失效 |
| `_clean_monitor_url` 禁内网 | §13.8 | 防 SSRF |
| `_delete_upload_file` 四条防护 | §12.9 | 防误删系统文件 |
| 升级解压拒绝路径穿越 | §14.11 | 防写任意文件 |
| `_load_upgrade_cache` tuple 还原 | §14.8 | 防后台 500 |
| `uploaded_file` / `share_thumb` 隐藏目录拦截 | §12.9 | 防目录遍历 |
| `admin_required` 覆盖所有 `/admin/*` | §11.1 | 遗漏一个就是后台裸奔 |

### 16.3 B 类：复刻时必须修的缺陷

#### B1. 无 CSRF token

**现状**：全部表单与状态变更端点只靠 `SameSite=Lax`。`GET /admin/logout` 甚至可以被任意 `<img src>` 触发。

**风险**：

- 跨站 `POST`（如 `<form action="https://blog/admin/posts/1/delete" method=POST>`）在 `Lax` 下确实被挡（Lax 只放行顶层导航的 GET）。
- 但 **`GET /admin/logout` 会被放行**（顶层导航），攻击者可强制登出（低危，但是骚扰）。
- 若浏览器降级/配置异常，或未来把 `SameSite` 改成 `None`（为了嵌入场景），立刻变成高危。

**修法**：加 CSRF token。最轻量的做法：

```python
import secrets

@app.before_request
def _csrf_token():
    if '_csrf' not in session:
        session['_csrf'] = secrets.token_urlsafe(32)
    g.csrf_token = session['_csrf']

@app.before_request
def _csrf_check():
    if request.method in ('POST', 'PUT', 'PATCH', 'DELETE'):
        tok = request.form.get('_csrf') or request.headers.get('X-CSRF-Token')
        if not tok or not hmac.compare_digest(tok, session.get('_csrf', '')):
            abort(400)
```

模板里所有 `<form method=post>` 加 `<input type=hidden name=_csrf value="{{ csrf_token }}">`，fetch 请求带 `X-CSRF-Token`。**注意**：登录页也要带（登录 CSRF 可导致「登录固定攻击」）。

#### B2. 在线升级 = 无签名 RCE 通道

**现状**：只校验新 `app.py` 的 `VERSION` 字符串更大（§14.11）。

**风险**：GitHub 账号被盗、镜像站投毒、Gitee 镜像被替换、DNS 劫持 → 任意代码执行，且以 `www-data` 权限读写数据库与上传目录。

**修法**（任选，建议全做）：

1. **发布方**：每个 release 附 `SHA256SUMS` 与 GPG 签名（`SHA256SUMS.asc`）。
2. **接收方**：下载后先校验签名，再比对 `app.py` 的 SHA256 与白名单。
3. **最简**：生产环境直接用环境变量 `DISABLE_ONLINE_UPGRADE=1` 关掉该路由，改人工 `git pull`。

**⚠️ 只校验 VERSION 还不如不校验**——它给人一种「有校验」的错觉。

#### B3. WAL 下直接 copy 数据库

**现状**：`shutil.copy2(DB_PATH, backup_path)`（§14.3、§14.11 第 1 步）。

**风险**：备份丢失最近事务；并发写入时可能拷到 torn page，恢复后数据库损坏。

**修法**：`VACUUM INTO` 或 `Connection.backup()`（§14.3 已给代码）。

#### B4. CSP 因内联脚本只能开 `unsafe-inline`

**现状**：`script-src 'self' 'unsafe-inline'`（§3.8）。因为 `<head>` 的防闪烁脚本、文章页增强脚本、`stats_code` 都是内联的。

**风险**：CSP 对 XSS 的实际防护接近于零——只要注入点能写入 `<script>`，就会被执行。

**修法**：

- 防闪烁脚本改为**外部文件** `static/js/theme-init.js`（同步 `<script src>`，不加 defer）。这样就能去掉 `unsafe-inline`。
- 文章页增强脚本抽成外部文件。
- `stats_code` 用 `nonce`：每次请求生成 `nonce`，CSP 写 `script-src 'self' 'nonce-<x>'`，`stats_code` 注入时加 `nonce` 属性。
- 逐步收到 `script-src 'self' 'nonce-...'`，`style-src` 同理（内联样式多，较难）。

#### B5. 多 worker 下进程内状态不一致

**现状**：以下状态都在 Python 进程内，4 个 worker 各有一份：

| 状态 | 变量 | 实际效果 |
|---|---|---|
| 登录失败计数 | `_LOGIN_ATTEMPTS` | 阈值 ×4（20 次才锁） |
| 阅读量冷却 | `_VIEW_COOLDOWN` | 60 秒 ×4 变 15 秒 |
| 评论冷却 | `_COMMENT_COOLDOWN` | 30 秒 ×4 变 7.5 秒 |
| 服务监控 | `_MONITOR_LOCK` + 线程 | 4 个 worker 各起一个线程，每 5 分钟写 4 份 |
| 水印刷新状态 | `_WM_REFRESH_STATE` | 后台看到的是「某个 worker」的状态 |
| 项目同步状态 | `_PROJECT_SYNC_STATE` | 已用「磁盘为权威」缓解（§13.6） |
| 版本检测缓存 | `UPGRADE_CACHE` | 已用磁盘缓存缓解（§14.8） |

**修法**（按成本排序）：

1. 用 `gunicorn -w 1`（单 worker）。个人博客流量完全撑得住，一次性解决 5 个问题。
2. 把热点状态搬到 SQLite：新建 `rate_limits(key, until)` 表，用 `INSERT OR REPLACE`。
3. 用 Redis（引入新依赖，个人博客不必要）。

**⚠️ 监控线程尤其明显**：4 worker 下 `service_checks` 每 5 分钟写 4 条记录，24 小时可用率的样本量被放大 4 倍，但「每服务保留 2000 条」的窗口相应缩短 4 倍（约 4 天而非 17 天）。

#### B6. `data/.otp_disable` 是文件系统级后门

**现状**：创建空文件即可强制关闭 2FA（§6.4）。

**风险**：拿到「能写文件系统」的能力（如上传目录配置错误、任意文件写漏洞）就等于关闭 2FA。

**修法**：把紧急开关改成「环境变量 + 重启」或「恢复码」路径，不要用运行时可创建的文件。

#### B7. `_strip_secrets` / JSON 导出用黑名单

**现状**：`WHERE key NOT LIKE '%password%'`（§14.5）；`_strip_secrets` 用 `'password' not in k.lower()`。

**风险**：`smtp_pass`、`github_token`、`aliyun_sk`、`tencent_sk`、`otp_secret`、`recovery_codes` 都会导出。

**修法**：白名单 + 后缀黑名单双保险：

```python
SECRET_SUFFIX = ('_pass', '_password', '_secret', '_token', '_sk', '_key', 'secret')
def is_secret(k):
    lk = k.lower()
    return lk.endswith(SECRET_SUFFIX) or 'otp' in lk or 'recovery' in lk
```

#### B8. `_clean_monitor_url` 只校验字面量域名

**现状**：解析 `hostname` 后判断是否 `localhost`/`.local`/字面 IP（§13.8）。

**风险**：`127.0.0.1.nip.io`、`169.254.169.254.nip.io` 等会在 DNS 层解析到内网/云元数据地址 → SSRF 读云凭证。

**修法**：`socket.getaddrinfo(host, None)` 拿到全部 IP，逐个用 `ipaddress` 判断 `is_private/is_loopback/is_link_local/is_reserved`，任一命中即拒绝。**并在实际发请求时用解析后的 IP 连接**（防 DNS 重绑定）。

#### B9. `_LOGIN_ATTEMPTS` 重启清零

**现状**：纯内存字典（§6.2）。

**风险**：攻击者可以「打 4 次 → 触发重启 → 再打 4 次」。正常运维不会频繁重启，但配合 B5 的多 worker 已放宽到 20 次。

**修法**：落 SQLite（`login_attempts(ip, fails, lock_until)`），并在启动时加载。

#### B10. TOTP 密钥与恢复码明文存 `settings`

**现状**：`settings['otp_secret']` 是 base32 明文；恢复码存 SHA-256 哈希（这部分是对的）。

**风险**：数据库泄露 = 2FA 完全失效（攻击者可直接算码）。

**修法**：用 `BLOG_SECRET_KEY` 派生密钥做 AES-GCM 加密后再入库。注意密钥轮换要能解密旧值（存 key id）。

#### B11. `_sanitize_html` 不是安全边界

**现状**：正则剥离（§14.13）。

**风险**：绕过方式多（嵌套标签、属性编码、SVG/MathML 命名空间）。

**修法**：用 `nh3`（Rust ammonia 绑定）或 `bleach` 做白名单消毒。**注意**：正文渲染不走这个函数（管理员可信），只有 README 渲染与升级日志走。

#### B12. `/admin/logout` 是 GET

**修法**：改成 POST + CSRF token。GET 只做「确认页」或直接 405。

#### B13. 搜索无速率限制

**现状**：`/search?q=` 每次 `LIKE '%...%'` 全表扫描（§10.10）。

**风险**：长关键词 + 高频请求可打满 SQLite（无索引、`LIKE` 前后通配）。

**修法**：关键词长度上限（如 64）、结果上限、同 IP 简单限流；数据量上来后上 FTS5。

#### B14. 评论内容 HTML 转义依赖模板

**现状**：`{{ comment.content }}` 由 Jinja 自动转义，换行靠 CSS `white-space: pre-wrap`。

**风险**：如果有人把模板改成 `| safe`，立刻 XSS。**建议**在 `db_save_comment` 里就把 `<` `>` 转义存库，双重保险（代价是导出时看到实体）。

#### B15. 上传目录可执行风险

**现状**：`uploads/` 在项目根，Nginx 用 `alias` 直接服务。

**风险**：若 Nginx 配置错误（如把 `location /uploads` 写成 `location /`），`.php`/`.py` 可能被其他 handler 执行。扩展名白名单已排除大部分，但 `.html` 若被允许则同源 XSS。

**修法**：Nginx 对 `/uploads` 加 `add_header X-Content-Type-Options nosniff`，并 `location ~* \.(php|py|sh|pl|cgi)$ { deny all; }`。

### 16.4 C 类：在信任模型下可接受

| 设计 | 为什么可接受 |
|---|---|
| Markdown 透传原始 HTML | 只有管理员能写；管理员本就拥有全部权限 |
| `stats_code` 任意 JS | 同上 |
| 无审计日志 | 单用户系统，日志只能审计自己 |
| 无多因素强制 | 默认关闭，可选开启 |
| 备份不加密 | 备份在服务器本地，与其他数据同级 |
| SMTP 密码明文存 `settings` | 与数据库同级；泄露即全站泄露 |
| GitHub Token 明文 | 同上 |
| 评论者 IP 存库 | 用于归属地与反垃圾；**建议**加保留期限（如 90 天）并在隐私政策说明 |

### 16.5 安全自检清单（上线前逐项打勾）

```text
[ ] BLOG_SECRET_KEY 已设置为 64 位随机十六进制，且不在代码库里
[ ] data/ 目录权限 700，data/.secret_key 权限 600
[ ] 初始管理员密码文件已被删除（首次改密后自动删）
[ ] 后台密码 >= 12 位且非字典词
[ ] 已开启 TOTP，并离线保存 10 个恢复码
[ ] Nginx 只暴露 80/443，5000 端口不对外
[ ] Nginx 已设 client_max_body_size，且 >= Flask 的 MAX_CONTENT_LENGTH
[ ] X-Forwarded-For 只有一个可信代理层（ProxyFix x_for=1）
[ ] HTTPS 已启用，HSTS 生效
[ ] uploads/ 目录禁止执行脚本
[ ] 在线升级已关闭，或已加入签名校验
[ ] 数据库备份改用 VACUUM INTO
[ ] 日志里不出现密码/Token/OTP 密钥
[ ] 已确认 gunicorn workers=1 或已把限流状态迁出进程
```

### 16.6 实现陷阱

1. **`SameSite=Lax` 不等于 CSRF 防护**，POST 是被挡了，但 GET 副作用没挡。
2. **CSRF token 必须 `hmac.compare_digest` 比较**，`==` 有时序侧信道。
3. **登录表单也要 CSRF token**，否则会被「登录固定攻击」。
4. **`unsafe-inline` 一旦打开，CSP 就只剩 `frame-ancestors` 有用**。
5. **nonce 必须每次请求重新生成**，复用 nonce 等于没有。
6. **`ProxyFix` 的 `x_for=1` 意味着只信最后一跳**，多层 CDN 要按实际跳数配。
7. **`ipaddress.is_private` 不包含 `100.64.0.0/10`（CGNAT）**，要额外判断。
8. **SSRF 防护必须「解析后连接同一个 IP」**，否则 DNS 重绑定可绕过。
9. **`secrets.compare_digest` 要用 `hmac.compare_digest`**（等价，但后者更通用）。
10. **备份文件本身含全部密码哈希**，`backups/` 必须 700 且不进 Git。
11. **`.gitignore` 必须排除 `data/`、`uploads/`、`backups/`、`*.db`、`.env`**。
12. **`app.run(debug=True)` 在生产等于 RCE**（Werkzeug 调试器有交互式控制台），`FLASK_DEBUG` 默认必须是 0。
13. **gunicorn 的 `--reload` 生产必须关**，否则文件变更即重启，且多进程行为异常。
14. **`server_error` 里 `raise e` 只在 debug 下合理**，生产要返回静态 500 页。
15. **隐私政策里要写清 IP 与邮箱的用途与保留期**，否则不合规。

---

## §17 验收用例与一致性对照

这一章给出「复刻完成后怎么证明行为一致」的可执行清单。

### 17.1 验收原则

- **行为等价优先于代码等价**：不要求逐行照抄，但相同的输入必须产生相同的可见结果与相同的副作用。
- **每个用例都写「前置条件 → 操作 → 预期」**，预期必须可观测（HTTP 状态、页面文本、数据库行、文件是否存在）。
- **优先覆盖「边界与失败路径」**，因为正常路径最容易写对。

### 17.2 路由完整性对照

原实现共 **83 条 `@app.route`**（含同路径不同 methods 的算一条）。复刻后必须逐条对齐：

```bash
# 提取原实现路由（在参考仓库里执行）
grep -n "@app.route(" /workspace/infowe_blog/app.py

# 提取复刻实现路由（在你的项目里执行）
grep -n "@app.route(" app.py

# 建议产出两张表做 diff：路径 + methods + endpoint 名
```

**对齐要求**：

- 路径必须完全一致（含末尾斜杠习惯）。
- `methods` 必须一致（尤其：删除是 POST、登出是 GET、`/post/<id>/view` 是 POST）。
- `endpoint` 函数名建议一致，因为模板里大量 `url_for('xxx')`。

**最容易漏的几条**：

| 路由 | 说明 |
|---|---|
| `/post/<int:post_id>/view` | POST，返回 204 |
| `/api/status` | JSON 轮询接口 |
| `/share-thumb/<path:filename>` | 分享缩略图 |
| `/avatar/<key>/<int:size>.png` | 头像代理，key 以 `e`/`q` 开头 |
| `/theme-static/<path:filename>` | 主题静态资源，只放行白名单 |
| `/uploads/<path:filename>` | 上传文件，拦截隐藏目录 |
| `/admin/projects/sync-status` | 同步进度轮询 |
| `/admin/upgrade/check` | 版本检测 JSON |
| `/admin/export/{json,markdown,db-backup,download/<f>,delete/<f>}` | 五个导出端点 |
| `/rss.xml` | RSS 2.0 |
| `/robots.txt`、`/sitemap.xml` | 若实现了 SEO 端点 |

### 17.3 数据模型对照

**10 张表**：`users / posts / categories / comments / projects / links / timeline / settings / service_checks / memories`。

逐表验收：

```bash
sqlite3 blog.db ".schema"
sqlite3 blog.db "PRAGMA table_info(posts);"
sqlite3 blog.db "SELECT name, type, \"notnull\", dflt_value FROM pragma_table_info('comments');"
```

**必须一致的项**：

| 表 | 关键约束/默认值 |
|---|---|
| `posts` | `status` 默认 `published`；`views` 默认 0；`is_featured` 默认 0；`tags` 存 JSON 字符串 |
| `comments` | `status` 默认 `pending`；`is_private` 默认 0；`parent_id` 可空；`post_id` **可空**（项目评论靠 `project_id`） |
| `projects` | 有 `github_repo` / `custom_name` / `languages`；**没有** `updated_at` |
| `links` | `status` 默认 `approved`；`avatar` 可空；有 `sort_order` |
| `settings` | 主键 `key`；值全为 TEXT（含布尔 `'0'`/`'1'`） |
| `service_checks` | 有 `idx_service_checks` 索引 |
| `users` | 有触发器 `users_single_admin_guard` |

**触发器验收**：

```sql
-- 应报错：博客仅支持单个管理员账号
INSERT INTO users (username, password) VALUES ('x', 'y');
```

### 17.4 状态码对照

| 场景 | 期望 |
|---|---|
| 首页、归档、标签、关于、友链、状态、项目列表 | 200 |
| `/post/<不存在>` | 404（站内 404 页） |
| `/post/<草稿>` | 404（不可直达） |
| `/projects/<不存在>` | 404 |
| 未登录访问 `/admin/*` | 302 → `/admin/login?next=...` |
| 已登录但未过 OTP 访问 `/admin/*` | 302 → `/admin/otp` |
| 登录失败 | 200 + flash「用户名或密码错误」（**不是 401**，SSR 场景） |
| `POST /post/<id>/view` 成功 | 204（无 body） |
| `POST /post/<id>/view` 冷却期内 | 204（同样 204，前端不关心） |
| `/api/status` | 200 `application/json` |
| `/rss.xml` | 200 `application/rss+xml` |
| `/uploads/.originals/x.jpg` | 404 |
| `/theme-static/default/base.html` | 404（模板源码不可下载） |
| `/admin/export/download/../../etc/passwd` | 404（`secure_filename` 后不存在） |
| 触发未捕获异常 | 500（站内 500 页，**生产不显示堆栈**） |
| 请求体 > 32MB | 413 |

### 17.5 冒烟测试脚本

```bash
#!/usr/bin/env bash
# smoke.sh —— 复刻后的最小验收
set -u
BASE="${BASE:-http://127.0.0.1:5000}"
fail=0

check() {  # check <描述> <期望码> <实际码>
  if [ "$3" != "$2" ]; then
    echo "FAIL: $1 (期望 $2，实际 $3)"; fail=$((fail+1))
  else
    echo "ok:   $1"
  fi
}

code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

check "首页"            200 "$(code "$BASE/")"
check "归档"            200 "$(code "$BASE/archive")"
check "标签页"          200 "$(code "$BASE/tags")"
check "关于"            200 "$(code "$BASE/about")"
check "状态页"          200 "$(code "$BASE/status")"
check "项目列表"        200 "$(code "$BASE/projects")"
check "友链"            200 "$(code "$BASE/links")"
check "RSS"             200 "$(code "$BASE/rss.xml")"
check "404 页"          404 "$(code "$BASE/post/99999999")"
check "后台未登录跳转"  302 "$(code "$BASE/admin")"
check "隐藏上传文件"    404 "$(code "$BASE/uploads/.originals/a.jpg")"
check "API status"      200 "$(code "$BASE/api/status")"
check "阅读量 POST"     204 "$(code -X POST "$BASE/post/1/view")"

# 结构断言
curl -s "$BASE/" | grep -q 'data-theme-mode' || { echo "FAIL: 缺少主题初始化脚本"; fail=$((fail+1)); }
curl -s "$BASE/rss.xml" | grep -q '<rss' || { echo "FAIL: RSS 结构不对"; fail=$((fail+1)); }

echo "----"
[ "$fail" -eq 0 ] && echo "全部通过" || echo "失败 $fail 项"
exit "$fail"
```

### 17.6 功能回归清单

按「用户可感知的功能」分组，每条都可手工执行。

**内容管线**

1. 写一篇含「标题 1-6 级、表格、有序/无序列表、任务列表、脚注、引用块、代码块、图片、外链」的文章，保存后逐项检查渲染。
2. 中文标题生成 TOC 后，锚点 id 非空且可跳转（`#中文标题`）。
3. 首图无 `loading="lazy"`（供微信抓图），第 2 张起有。
4. 首图带 `width` / `height`（防布局抖动）。
5. 外链自动加 `target="_blank" rel="noopener noreferrer"`。
6. `[javascript:alert(1)](x)` 渲染后 `href="#"`。
7. 三个反引号围栏内的 `<https://a.com>` **被错误替换**为链接（这是原实现的已知副作用，若复刻时修掉了要记录为「有意偏差」）。
8. 保存时 `read_time` >= 1；摘要 200 字内且无 Markdown 符号。
9. 编辑文章时不填 `created_at`，原时间保持不变。

**评论**

10. 匿名提交 → 提示「待审核」→ 后台审核通过 → 前台可见。
11. 用 `notify_email` 邮箱提交 → 直接 `approved`。
12. 勾选「私密」→ 前台其他访客不可见，博主登录可见。
13. 同一 IP 30 秒内二次提交 → 被拒。
14. 昵称填博主昵称 → 被拒（或自动改为访客）。
15. 回复一条评论 → 表单搬到该楼层组末尾，`parent_id` 正确。
16. 刷新后自己刚发的评论仍在（`my_comments` 三重校验通过）。
17. 换浏览器/清 cookie → 看不到自己待审核的评论。
18. 回复数 4 条 → 默认折叠，露出 2 条。
19. 删除根评论 → 其全部子孙一并删除（BFS）。
20. 项目页评论 → 不 500（`post_id` 为 NULL）。

**认证**

21. 密码错误 5 次 → 锁定 15 分钟。
22. 第 3 次失败起出现算术验证码；刷新页面不换题（同一 session）。
23. 开启 TOTP → 扫码 → 输入 6 位码 → 进入后台。
24. 用上一周期的码（-30s）也能通过（±1 窗口）。
25. 用已用过的恢复码 → 失败；用新的 → 成功且该码失效。
26. 忘记密码 → 提交任意邮箱都返回相同文案（不泄露是否存在）。
27. 改密码必须输入旧密码；错误时拒绝。
28. 登出后再访问 `/admin` → 跳登录页。
29. 创建 `data/.otp_disable` → OTP 被跳过（这是设计，不是 bug）。

**媒体**

30. 上传 `.jpg` → 生成 `uploads/YYYY/MM/<name>.jpg` 与 `.originals/...` 原图。
31. 上传 20MB 以上图片 → 拒绝。
32. 上传 `.svg` → 拒绝。
33. 上传 `.heic` → 转 JPEG 成功。
34. 上传同名文件两次 → 第二张自动改名（不覆盖）。
35. 设置水印后「重刷全部」→ 已有图全部加水印，`.originals` 保留无水印版。
36. 删除文章 → 文中独占图片被删，被其他文章引用的图片保留。
37. 孤儿文件清理 → `avatar/`、`projects/`、隐藏目录不被扫到。

**项目页**

38. 填 `https://github.com/owner/repo` → 同步成功，显示 stars / 语言占比。
39. README 图片 → 下载到 `uploads/projects/<slug>/readme/`，页面引用站内路径。
40. GitHub Token 无效（401）→ 自动匿名重试，仍失败则显示错误。
41. 同步进行中刷新后台 → 进度条继续（磁盘状态）。
42. 同步完成 10 分钟后重进 → 状态清零，不再显示「同步完成」。

**升级与导出**

43. 导出 JSON → 不含 `admin_password`；**检查是否含 `smtp_pass`（已知缺陷）**。
44. 导出 Markdown zip → front matter 合法，用任意 Markdown 工具能解析。
45. 数据库备份 → 用 `sqlite3 backup.db "PRAGMA integrity_check"` 返回 `ok`。
46. 升级锁存在时再次升级 → 提示「已在进行中」。
47. 手动放置过期锁（mtime 改到 20 分钟前）→ 可正常升级。

**前端**

48. 三种主题循环切换，刷新后保持。
49. 系统切深色时，`auto` 态跟随，`dark` 态不变。
50. 首屏无白闪（Network 面板确认脚本在 CSS 前执行）。
51. 阅读进度条随滚动更新，到 100% 停住。
52. 停留 5 秒后 Network 出现 `POST /post/<id>/view`；刷新不再发。
53. 切到后台标签页 5 秒 → 不上报。
54. 代码块复制按钮只出现一个。
55. 宽表格可横向滑动，滑到最右时遮罩消失。
56. Lightbox：`←`/`→`/`Esc` 均生效。
57. 分享面板：复制成功、微博/QQ 空间新窗口打开、微信二维码可扫。
58. 后台 `Ctrl+S` 保存；标题输入自动生成 slug；手改 slug 后不再自动覆盖。
59. 批量模式按钮出现，`Esc` 退出。
60. flash 消息 4 秒自动消失，可手动关闭。

### 17.7 性能基线

单机 1 核 1G、SQLite、gunicorn 1 worker 下：

| 指标 | 目标 |
|---|---|
| 首页（100 篇文章分页） | < 150ms |
| 文章详情（含评论树 50 条） | < 200ms |
| 后台列表（1000 篇文章） | < 300ms |
| 上传 5MB 图片（含压缩） | < 3s |
| 同步 1 个 GitHub 项目（含 README 图片） | < 10s |
| 首页 HTML 体积 | < 80KB（不含图片） |

**⚠️ 若首页超过 500ms**，先查 `inject_globals()` 的两次额外查询（`db_get_all_tags` + `db_load_links`）是否被 N+1 放大。

### 17.8 一致性偏差登记表

复刻过程中**有意偏离**原实现的地方，必须登记（否则后续维护者会以为是 bug）：

| 编号 | 偏差 | 原因 | 影响 |
|---|---|---|---|
| D1 | 备份改用 `VACUUM INTO` | WAL 下 copy 不一致 | 备份文件更小、可恢复 |
| D2 | 增加 CSRF token | 原实现无 | 所有表单需带隐藏域 |
| D3 | 关闭在线升级 | 无签名 RCE | 升级改人工 |
| D4 | 登录/评论限流落库 | 多 worker 下失效 | 需要额外表 |
| D5 | `_sanitize_html` 换 `nh3` | 正则不是边界 | README 渲染更严格 |
| D6 | 去掉 `disable-zoom.js` | 反可访问性 | 移动端可缩放 |
| D7 | 修掉 `normalize_auto_links` 在代码块内生效 | 原实现副作用 | 代码块内容更正确 |
| D8 | `read_time` 改为中英文分别计 | 原实现低估中文 | 阅读时长更准 |
| D9 | `exclude_featured` 只排除首页展示位 | 原实现导致精选不可见 | 精选文章仍可访问 |
| D10 | 目录结构拆包（`app/` 包） | 单文件 6814 行不可维护 | 需保证 `url_for` endpoint 不变 |

### 17.9 实现陷阱

1. **验收必须用「全新数据库」与「从旧库升级」两条路径各跑一遍**，迁移代码最容易漏。
2. **`grep "@app.route("` 只能抓装饰器写法**，若复刻用了 `add_url_rule` 会漏统计。
3. **`PRAGMA table_info` 看不到触发器**，要用 `.schema` 或 `sqlite_master`。
4. **`curl` 默认不跟随 302**，测跳转要加 `-L` 或显式看 `Location`。
5. **`POST /post/<id>/view` 期望 204**，若复刻返回 200 + JSON 也算偏差，要登记。
6. **测锁定要清 `_LOGIN_ATTEMPTS`**（重启或换 IP），否则后续用例全被锁。
7. **测评论冷却要清 `_COMMENT_COOLDOWN`**，同上。
8. **`sessionStorage` 去重会让「刷新不重复计数」的用例在无痕窗口里失效**，测试时注意。
9. **图片压缩结果受 Pillow 版本影响**，断言只查「尺寸不超过 1920」，不要比对字节。
10. **HEIC 测试需要真实 HEIC 文件**，用改扩展名的 JPEG 测不出问题。

---

## §18 运维手册、实施路线与改进建议

### 18.1 日常运维

**启动 / 停止 / 重启**

```bash
sudo systemctl start blog
sudo systemctl stop blog
sudo systemctl restart blog        # 改代码/改环境变量后必须执行
sudo systemctl status blog
journalctl -u blog -f             # 实时日志
journalctl -u blog --since "1 hour ago"
```

**备份（建议每日 cron）**

```bash
# /etc/cron.d/infowe-backup
0 3 * * * www-data cd /var/www/infowe.site && \
  sqlite3 data/blog.db "VACUUM INTO 'backups/daily_$(date +\%Y\%m\%d).db'" && \
  find backups -name 'daily_*.db' -mtime +30 -delete
```

**⚠️ cron 里的 `%` 必须转义成 `\%`**，否则 cron 会当成换行。

**恢复**

```bash
sudo systemctl stop blog
cp backups/daily_20261023.db data/blog.db
rm -f data/blog.db-wal data/blog.db-shm     # 关键：清掉残留 WAL
sudo chown www-data:www-data data/blog.db
sudo systemctl start blog
```

**⚠️ 恢复时不清 `-wal` / `-shm`**，SQLite 会把旧 WAL 回放到新库上，直接损坏。

**日志位置**

- gunicorn：`accesslog/errorlog = "-"` → 进 systemd journal。
- 应用 `print()`（HEIC 版本信息、升级镜像提示）也进 journal。
- **没有文件日志、没有日志轮转**，靠 journald 的默认策略。

**服务器迁移**

1. 停服。
2. 打包 `data/`（含 `blog.db`、`.secret_key`、缓存）、`uploads/`、`backups/`、`.env`（若用）。
3. 新机装依赖 → 解压 → `systemctl start`。
4. **`BLOG_SECRET_KEY` 必须与原机一致**，否则所有已登录会话失效（不算故障，但用户会被登出）。
5. 校验 `uploads/` 权限（`www-data` 可读）。

### 18.2 故障排查表

| 症状 | 可能原因 | 排查 |
|---|---|---|
| 502 Bad Gateway | gunicorn 没起 / 端口不对 | `systemctl status blog`；`curl 127.0.0.1:5000` |
| 后台登录后立刻被登出 | `BLOG_SECRET_KEY` 每次重启都变（未设置且 `data/.secret_key` 不可写） | 检查 `data/.secret_key` 是否存在且 600 |
| 所有评论 IP 都是 `127.0.0.1` | Nginx 没传 `X-Forwarded-For`，或 ProxyFix 配错 | `curl -H 'X-Forwarded-For: 1.2.3.4'` 看归属地 |
| 图片上传 413 | Nginx `client_max_body_size` 小于文件 | 同步调大两个值 |
| 图片上传成功但页面 404 | `uploads/` 权限或 Nginx alias 路径错 | 直接 `curl /uploads/...` |
| 文章页 500 | 内容里有异常 Markdown / 图片尺寸读取失败 | 看 journal 的 traceback；临时把 `TEMPLATES_AUTO_RELOAD` 关掉排除模板问题 |
| 后台 500 | `upgrade_cache.json` 里 version 是 list 未还原 | 删 `data/upgrade_cache.json` |
| 评论提交 500 | 老库 `comments.post_id NOT NULL` | 重新执行 `_migrate_comments`（重建表） |
| 项目页评论 500 | 同上 | 同上 |
| 状态页数据不更新 | 监控线程没起 / `MONITOR_INTERVAL` 太大 | 看是否有 `service_checks` 新行；确认非 reloader 环境 |
| 同步项目一直「进行中」 | 上次同步线程被杀，磁盘状态未清 | 删 `data/project_sync_state.json` 或等 10 分钟自动清零 |
| 升级一直「已在进行中」 | `upgrade.lock` 残留 | 删 `upgrade.lock`（或等 600 秒） |
| 换了头像但显示旧图 | 头像代理缓存 15 天 | 删 `static/cache/avatars/` 对应文件 |
| 数据库 locked | 长事务 / 备份占锁 | 已设 `busy_timeout=15000`；检查是否有外部 `sqlite3` 交互式会话 |

**重置管理员密码**（忘记且无法登录）：

```bash
cd /var/www/infowe.site
python3 - <<'PY'
import sqlite3, werkzeug.security as ws
db = sqlite3.connect('data/blog.db')
pw = ws.generate_password_hash('NewStrongPassword!2026', method='pbkdf2:sha256', salt_length=16)
db.execute('UPDATE users SET password=? WHERE id=(SELECT MIN(id) FROM users)', (pw,))
db.commit(); db.close()
print('ok')
PY
sudo systemctl restart blog
```

**⚠️ 同时要清理 OTP**（若连 TOTP 也丢了）：

```bash
touch data/.otp_disable        # 紧急关闭 2FA
# 或
sqlite3 data/blog.db "DELETE FROM settings WHERE key IN ('otp_secret','otp_enabled','otp_recovery');"
```

登录后立刻重新绑定并删掉 `.otp_disable`。

### 18.3 复刻实施路线

按「每一步都可运行、都可验收」切分，共 7 个阶段。

#### 阶段 0：骨架（可跑空站）

- 建目录、`requirements.txt`、`app.py` 入口、`get_db()`、`init_db()` 建 10 表。
- `before_request` 加载 settings、`context_processor` 注入全局变量、`after_request` 加安全头。
- 主题加载器（`ThemedFlask` + `ThemeLoader`）与 `templates/default/` 最小 `base.html`。
- 验收：`/` 返回 200 的一行 HTML；`init_db` 后 `blog.db` 有 10 表。

#### 阶段 1：认证与后台壳

- 密码哈希、登录、登出、`admin_required`、初始管理员随机密码。
- `templates/admin/base.html` + 侧栏 + flash + `admin.js` 主题与抽屉。
- 验收：能登录进空仪表盘；未登录访问跳转。

#### 阶段 2：文章 CRUD 与渲染

- `db_save_post` / `db_load_posts` / `db_get_post` / `db_delete_post`。
- `render_post_content`（10 扩展、TOC、图片/链接后处理）。
- 后台编辑器（slug 自动生成、Ctrl+S）、前台详情页、首页、归档、标签。
- 验收：§17.6 的「内容管线」1–9 全通过。

#### 阶段 3：评论

- `comments` 表 + 组树 + `my_comments` 三重校验 + 提交校验 + 冷却。
- `_comments.html` 宏、`comments.js` 回复/折叠/字数/防重复。
- 后台审核列表、批量通过/删除、BFS 删除。
- 验收：§17.6 的「评论」10–20 全通过。

#### 阶段 4：媒体与上传

- `_save_upload`、`_safe_stem`、扩展名白名单、大小限制。
- Pillow 压缩、HEIC、水印、`.originals`、孤儿清理。
- `/uploads/<path>`、`/share-thumb/<path>`、`_upload_image_dims`。
- 验收：§17.6 的「媒体」30–37 全通过。

#### 阶段 5：外部集成

- GitHub 元数据 + README 拉取 + 图片本地化 + 缓存 + 后台同步。
- SMTP 通知、IP 归属地、服务监控、云到期、头像代理。
- 验收：§17.6 的「项目页」38–42 全通过。

#### 阶段 6：导出、升级与加固

- 四个导出端点、Markdown zip。
- 版本检测、下载、解压、覆盖（**建议直接砍掉，或只保留「检查更新」**）。
- 补 CSRF、把限流落库、备份改 `VACUUM INTO`。
- 验收：§17.6 的「升级与导出」43–47 + §16.5 全打勾。

#### 阶段 7：体验与打磨

- 前端脚本（主题、滚动、AOS、粒子、3D、分享、Toast、状态轮询）。
- 响应式与无障碍（`skip-link`、`aria-*`、焦点管理、`prefers-reduced-motion`）。
- 验收：§17.6 的「前端」48–60 全通过 + §17.7 性能基线。

**每个阶段的结束都要能部署**：不允许「三个阶段一起才能跑」，否则调试成本指数上升。

### 18.4 改进建议（按收益排序）

#### 高收益、低成本

1. **改用 `gunicorn -w 1`**：一次性解决限流、监控、同步状态的进程内不一致问题（B5）。个人博客完全够用。
2. **备份改 `VACUUM INTO`**：5 行代码，消灭最危险的数据风险（B3）。
3. **关闭在线升级**：删一个路由，消灭最大攻击面（B2）。
4. **加 `<noscript>` 兜底**：避免 JS 失败时首页全空（§15.15 第 5 条）。
5. **`sitemap.xml` / `robots.txt`**：SEO 基础，各 20 行。
6. **补 4 个索引**：`posts(status, created_at)`、`comments(post_id, status)`、`comments(project_id, status)`、`posts(slug)`（§4.7）。
7. **`_strip_secrets` 改白名单**：防导出泄露（B7）。

#### 中收益、中成本

8. **拆包**：`app.py` 拆成 `app/__init__.py` + `models/` + `views/` + `services/`，用 Blueprint。**必须保留 endpoint 名**，否则模板里 `url_for` 全炸。
9. **CSRF token**（B1）。
10. **限流落 SQLite**（B9）。
11. **FTS5 全文搜索**：替换 `LIKE '%q%'`，中文需配 `unicode61` tokenizer 或外部分词。
12. **图片响应式**：`srcset` + WebP/AVIF 转码（Pillow 支持 WebP，AVIF 需 `pillow-avif-plugin`）。
13. **对象存储**：图片上 OSS/COS，减轻本机磁盘与带宽压力。
14. **`nh3` 替换正则消毒**（B11）。
15. **日志结构化**：JSON 行日志 + 请求 ID，便于排查。

#### 低收益或高风险（不建议个人博客做）

16. 多作者/多角色：会推翻「单管理员信任模型」，需要重做权限体系。
17. 评论无限嵌套：树深了渲染与查询都复杂，两层足够。
18. 实时预览编辑器：前端成本高，Markdown 本身可读性好。
19. 自建全文搜索引擎（ES/Meili）：SQLite FTS5 足够。

### 18.5 代码规模基线

复刻完成后的合理规模（供评估工作量）：

| 模块 | 行数（参考原实现） |
|---|---|
| 后端单体 | 6814 |
| 模板（52 个） | 约 6000 |
| 前端 JS（7 个） | 1425 |
| CSS（8 个） | 约 3800 |
| 合计 | 约 18000 |

**⚠️ 单文件 6814 行是原实现的明确技术债**（作者本人已宣布转向 PHP + MySQL 重构）。复刻时**不建议**追求「行数一致」，应追求「行为一致 + 结构可维护」。

### 18.6 实现陷阱

1. **cron 里的 `%` 必须转义**，否则命令被截断。
2. **恢复数据库必须删 `-wal` / `-shm`**，否则旧 WAL 回放到新库上会损坏。
3. **`BLOG_SECRET_KEY` 变更会让所有会话失效**，迁移时要保持一致。
4. **`data/.secret_key` 不可写时每次重启都会换密钥**，表现为「登录后立刻掉线」。
5. **`systemctl restart` 不是 reload**，gunicorn 的 `--reload` 生产应关闭。
6. **`journalctl` 默认会轮转**，需要长期日志要配 `SystemMaxUse`。
7. **重置密码只改 `users` 表不够**，OTP 还在的话仍然进不去。
8. **改包结构必须保住 endpoint 名**，`url_for` 是按 endpoint 查的，不是按路径。
9. **拆包后 `BASE_DIR` 的推导会变**（`__file__` 层级不同），所有路径常量要重新校准。
10. **不要为了「架构好看」引入 ORM**：现有 `db_*` 函数已足够，SQLAlchemy 会带来会话管理与性能不确定性。
11. **不要引入前端框架**：SSR + 原生 JS 是这套系统的核心优势（首屏快、无 hydration）。
12. **升级路线必须每阶段可部署**，否则调试时无法定位是哪一层坏了。

---

## 附录 A 速查表

### A.1 常量总表

| 常量 | 值 | 位置 |
|---|---|---|
| `VERSION` | `1.3.63` | app.py 顶部 |
| `DEFAULT_THEME_NAME` | `'default'` | 主题系统 |
| `MAX_CONTENT_LENGTH` | `32 * 1024 * 1024` | 应用配置 |
| `PERMANENT_SESSION_LIFETIME` | `3600` | 应用配置（实际未生效） |
| `_LOGIN_MAX_FAILS` | `5` | 认证 |
| `_LOGIN_LOCK_SECONDS` | `15 * 60` | 认证 |
| `_LOGIN_BASE_DELAY` | `0.5` | 认证 |
| `_LOGIN_CAPTCHA_FAILS` | `3` | 认证 |
| `_VIEW_COOLDOWN_WINDOW` | `60` | 阅读量 |
| `_VIEW_MAX_ENTRIES` | 约 20000 | 阅读量 |
| 评论冷却 | `30` 秒 | 评论 |
| 评论内容上限 | `2000` 字 | 评论 |
| `_COMMENT_COOLDOWN` 上限 | `5000` 条 | 评论 |
| `MONITOR_INTERVAL` | `300` 秒 | 监控 |
| 每服务探测记录保留 | `2000` 条 | 监控 |
| `_AVATAR_MAX_AGE` | `15 * 24 * 3600` | 头像缓存 |
| `_AVATAR_TIMEOUT` | `8` 秒 | 头像 |
| `_README_IMG_MAX` | `8 * 1024 * 1024` | README 图片 |
| `_README_IMG_EXT` | 8 种图片扩展 | README 图片 |
| `_README_FILENAMES` | `README.md` / `readme.md` / `Readme.md` / `README.markdown` | README |
| 项目缓存 TTL | `10` 分钟 | 项目 |
| 同步完成状态保留 | `600` 秒 | 项目 |
| `_THUMB_SIZE` | `(800, 600)` | 分享图 |
| 分享图缓存 | `86400` 秒 | 分享图 |
| 图片压缩最长边 | `1920` | 上传 |
| JPEG 质量 | `82` | 上传 |
| 上传大小上限 | `20MB` | 上传 |
| `UPGRADE_MAX_BYTES` | `200 * 1024 * 1024` | 升级 |
| `UPGRADE_LOCK_TTL` | `600` 秒 | 升级 |
| `UPGRADE_DOWNLOAD_TIMEOUT` | `60` 秒 | 升级 |
| 版本缓存 TTL | `600` 秒 | 升级 |
| RSS 条数 | 20 | RSS |
| 首页每页 | 10 | 分页 |
| 归档每页 | 20 | 分页 |
| 标签页 `per_page` | `99999` | 标签 |
| 摘要长度 | `200` 字 | 文章 |
| slug 上限 | `60` 字符 | 文章 |
| 阅读时长 | `max(1, 词数 // 200)` | 文章 |
| Token 刷新 | 无（长期有效） | 外部 |

### A.2 状态枚举

**`posts.status`**

| 值 | 含义 | 前台可见 |
|---|---|---|
| `published` | 已发布 | 是 |
| `draft` | 草稿 | 否（404） |

**`comments.status`**

| 值 | 含义 | 前台可见 |
|---|---|---|
| `pending` | 待审核 | 仅提交者（三重校验后） |
| `approved` | 已通过 | 是 |
| `spam` | 垃圾 | 否 |

**`links.status`**

| 值 | 含义 |
|---|---|
| `approved` | 已通过（默认） |
| `pending` | 待审核 |
| `hidden` | 隐藏 |

**主题模式 `data-theme-mode`**

| 值 | 含义 |
|---|---|
| `auto` | 跟随系统（默认） |
| `light` | 强制浅色 |
| `dark` | 强制深色 |

**服务状态 `service_checks.ok`**

| 值 | 含义 |
|---|---|
| `1` | 可访问 |
| `0` | 不可访问 |
| `NULL` | 尚未探测 |

**云到期状态**

| 值 | 判定 |
|---|---|
| `ok` | 剩余 > 30 天 |
| `warn` | 剩余 1–30 天 |
| `expired` | 已过期 |
| `none` | 未配置 |

### A.3 常用错误文案

| 文案 | 触发 |
|---|---|
| 用户名或密码错误 | 登录失败（不区分账号是否存在） |
| 登录失败次数过多，请 15 分钟后再试 | 锁定 |
| 验证码错误 | 算术题答案不对 |
| 动态验证码错误 | TOTP 不匹配 |
| 恢复码无效或已使用 | 恢复码校验失败 |
| 评论已提交，等待审核 | 默认 `pending` |
| 提交过于频繁，请稍后再试 | 30 秒冷却 |
| 评论内容不能为空 | 空内容 |
| 评论内容不能超过 2000 字 | 超长 |
| 昵称不可使用博主名称 | 保留字 |
| 图片格式不支持 | 扩展名不在白名单 |
| 文件过大 | 超过 20MB |
| 下载内容超过大小上限，已取消 | 升级包 > 200MB |
| 压缩包内含非法路径，已中止 | zip 路径穿越 |
| 下载的版本不高于当前版本，已中止 | 版本未递增 |
| 升级任务已在进行中，请稍候再试 | 锁冲突 |
| 升级成功：代码已从 vX 更新为 vY（替换 N 个文件） | 成功 |
| 当前已是最新版本，无需升级 | 无新版本 |
| 没有可替换的文件，已中止 | 包结构不对 |
| 文件不存在 | 备份删除/下载 |
| 同步已在进行中 | 项目同步锁 |
| 未找到该项目 | GitHub 404 |
| GitHub 访问受限（可能需要配置 Token） | 403 限流 |
| GitHub Token 无效或已过期 | 401 |

### A.4 术语对照

| 中文 | 代码标识 | 说明 |
|---|---|---|
| 文章 | `post` | 主体内容，有 slug |
| 草稿 | `draft` | `status='draft'` |
| 精选 | `is_featured` | 首页优先展示 |
| 分类 | `category` | 一对多，无外键 |
| 标签 | `tags` | 存 JSON 数组字符串 |
| 项目 | `project` | GitHub 仓库展示页 |
| 友链 | `link` | 友情链接 |
| 时间线 | `timeline` | 关于页履历 |
| 设置 | `setting` | K/V 表 |
| 主题 | `theme` | `templates/<key>/` |
| 上传 | `upload` | `uploads/YYYY/MM/` |
| 原图 | `.originals` | 无水印备份 |
| 水印 | `watermark` | Pillow 绘制 |
| 孤儿文件 | `orphan` | 无引用可删 |
| 骨架屏 | `skeleton` | 加载占位 |
| 阅读进度 | `reading-progress` | 顶部进度条 |
| 分享图 | `share-thumb` | 800×600 裁切 |
| 头像代理 | `avatar_proxy` | 站内缓存外部头像 |
| 恢复码 | `recovery code` | TOTP 备用码 |
| 单管理员守卫 | `users_single_admin_guard` | 触发器 |

### A.5 章节与源码行号映射

| 章节 | 主要源码位置 |
|---|---|
| §3 配置与入口 | `app.py#L228-L311`、`L336-L377` |
| §4 数据模型 | `app.py#L379-L489`、`L491-L618`、`L619-L701`、`L704-L785` |
| §5 生命周期 | `app.py#L3450-L3512` |
| §6 认证 | `app.py#L1641-L1710` |
| §7 内容管线 | `app.py#L2130-L2203`、`L2206-L2315` |
| §8 评论 | `app.py#L3880-L3959`、评论数据层 |
| §9 主题 | `app.py` 主题系统段（文件头部下方） |
| §11 后台 | `app.py#L4651-L4750` |
| §12 媒体 | `app.py#L5630-L5739`、`L5742-L5833` |
| §13 外部集成 | `app.py#L2411-L2442`、`L2445-L2874`、`L3068-L3157`、`L1008-L1137`、`L1247-L1336` |
| §14 导出与升级 | `app.py#L6302-L6422`、`L6474-L6804` |
| §15 前端 | `static/js/*.js`、`templates/default/post.html`、`templates/default/base.html` |

### A.6 关键文件清单

```text
app.py                       主应用（6814 行）
requirements.txt             依赖
gunicorn.conf.py             生产 WSGI 配置
blog.service                 systemd 单元
deploy_infowe.site.conf      Nginx 站点配置
DEPLOY.md                    部署说明
templates/
  default/                   内置主题（17 个模板 + info.json + preview.png）
  tech/                      第二主题（15 个模板 + theme.css + theme.js）
  admin/                     后台模板（24 个）
  _footer_text.html          页脚文案片段
static/
  css/                       style.css / admin.css / markdown-body.css / comments.css / ...
  js/                        main.js / admin.js / comments.js / share.js / status.js / toast.js / disable-zoom.js
  images/                    favicon / og-image
  cache/avatars/             头像代理缓存
data/
  blog.db                    SQLite 主库
  .secret_key                自动生成的会话密钥（600）
  .initial_admin_password    初始密码（首次改密后删除）
  .otp_disable               紧急关闭 2FA 的标记文件
  upgrade_cache.json         版本检测缓存
  project_gh_cache.json      GitHub 项目缓存
  project_sync_state.json    同步进度状态
  share_thumbs/              分享图缓存
uploads/
  YYYY/MM/                   文章图片
  .originals/                无水印原图
  projects/<slug>/readme/    README 本地化图片
  avatar/                    头像上传
backups/                     数据库与升级备份
fonts/                       水印字体（含 wqy-microhei.ttc）
vendor/                      ip2region 库与 xdb 文件
```

### A.7 一页速记

```text
架构：Flask 3 + SQLite(WAL) + Jinja2 SSR + 原生 JS，单文件 app.py
请求：before_request(settings→config, 主题缓存) → 视图(get_db/g) → context_processor(30+ 变量) → after_request(安全头)
主题：templates/<key>/{info.json,theme.css,preview.png,*.html}，查找序 当前主题 → default → 根
迁移：CREATE IF NOT EXISTS → 列探针 ALTER → 约束不符就建新表拷交集列改名
认证：pbkdf2:sha256(盐16) + 失败锁定(5次/15分钟) + 算术验证码 + TOTP(±1窗口) + 恢复码(一次性)
渲染：剥 front-matter → <url>自动链接 → 10 扩展 → TOC(保留中文) → 首图注宽高 → 链接加 target
评论：默认 pending，博主邮箱直通，同 IP 30 秒，组树单查询，删评论 BFS
上传：白名单(无 svg) + 20MB + Pillow(1920/q82) + HEIC + 水印 + .originals
升级：只校验 VERSION 递增 → 无签名 → 生产禁用
前端：head 内联防闪烁 → 三态主题 → rAF 合并 scroll → IntersectionObserver → 原生组件
风险：无 CSRF、WAL 备份不一致、CSP unsafe-inline、多 worker 限流失效
```

---

## 结语

这份文档描述的是一个**刻意保持简单**的个人博客系统：一个 Python 文件、一个 SQLite 文件、一套模板、一份原生 JS。它没有 ORM、没有前端框架、没有微服务、没有消息队列，也没有 Docker。所有能力都是「够用就好」，代价是 `app.py` 长到 6814 行、`UPGRADE_SKIP` 这种安全底线靠一个集合字面量维持、限流状态散落在各进程内存里。

复刻它时，最容易犯的错是「按现代工程规范重写」——拆包、上 ORM、上 TypeScript、上组件化。这样确实更"规范"，但会丢掉这套系统最核心的东西：**部署即复制目录、改一行 CSS 就生效、出问题看一个文件就能定位**。对于个人博客，这些比架构整洁更重要。

真正值得改的只有三件事：

1. **数据安全**：备份必须用 `VACUUM INTO`，不能 copy WAL 主库。
2. **攻击面**：在线升级没有签名校验，生产环境应当关掉。
3. **状态一致性**：单 worker 能解决 90% 的"玄学问题"，比引入 Redis 划算得多。

其余的（无 CSRF、CSP 有 `unsafe-inline`、评论两层不无限嵌套、图片不做 AVIF）在「单管理员 + 个人博客」的信任模型下都是合理取舍，写清楚、别装作不存在就够了。

最后提醒一句：这份文档里的所有代码片段都是从真实源码提炼的**行为描述**，不是可直接粘贴的生产代码。复刻时请以「行为一致」为目标，按自己的目录结构与命名习惯重写，并用 §17 的验收清单逐项验证。

---

**文档版本**：1.0
**对应源码**：`Contribuv/infowe_blog` @ `13b5c43`（`VERSION = 1.3.63`）
**最后更新**：2026-10-23



