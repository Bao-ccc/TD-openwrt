# github-release-sync

**GitHub 上游同步 + OpenWrt 插件包版本/哈希自动维护工具**

两层能力：

| 层 | 作用 | 说明 |
|---|---|---|
| **A. `sources`** | 同步上游源码 | 把 `luci-app-XXX`、依赖包源码从上游仓库拉到本地，支持**多个上游**，按 commit 变化增量同步 |
| **B. `packages`** | 自动更新版本/校验值 | 在本地 Makefile 上自动写 `PKG_VERSION` / `PKG_HASH`，支持**三种策略** |

支持 **GitHub Actions 定时自动同步**，可选 **Telegram / WxPusher** 推送。

---

## 目录结构

```
your-repo/                           ← 仓库根目录（即 OpenWrt 的一个 package feed）
├── luci-app-passwall/               # ┐
├── luci-app-passwall2/              # │
├── xray-core/  sing-box/  ...       # ├─ 插件包 / 软件包，直接放在根目录
├── chinadns-ng/  naiveproxy/  ...   # ┘   （与 VIKINGYFY/packages 同布局）
├── update.sh                        # ┐
├── lib/notify.sh                    # │
├── config/packages.json             # ├─ 同步工具（无 Makefile，OpenWrt 会自动忽略）
├── test/test-write.sh               # │
├── .github/workflows/auto-sync.yml  # │
├── crontab.example                  # │
├── README.md  LICENSE  .gitignore   # ┘
└── .state/                          # 运行状态（已 .gitignore）
```

> **布局说明**：所有包目录**直接放在仓库根目录**，不嵌套二级目录。
> 这样 OpenWrt 可以直接把本仓库当作 feed 拉取：
> ```bash
> # feeds.conf.default
> src-link passwall /path/to/this/repo
> # 或直接克隆到 package/
> git clone <this-repo> <openwrt>/package/passwall
> ```
> 工具自身的 `config/` `lib/` `test/` 没有 `Makefile`，OpenWrt 会自动忽略。

---

## 快速开始

### 1. 依赖

```bash
# Debian / Ubuntu
sudo apt-get install -y curl jq coreutils tar

# macOS
brew install curl jq gnu-tar
```

### 2. 运行

```bash
bash update.sh                # 全量：同步源码 + 更新版本哈希
bash update.sh --dry-run      # 只看会改什么，不动文件
bash update.sh --force        # 忽略缓存，强制重新拉取 / 重算
bash update.sh --only xray-core
bash update.sh --sync-source  # 只同步上游源码
bash update.sh --skip-source  # 只更新版本哈希
```

### 3. 结果

仓库根目录下的每个包目录就是一套完整的 OpenWrt 插件包，
整个仓库可直接当作 feed 使用：

```bash
# 方式一：src-link
src-link passwall /path/to/this/repo

# 方式二：克隆到 OpenWrt 源码树
git clone <this-repo> <openwrt>/package/passwall

# 方式三：只挑几个包
cp -a xray-core sing-box <openwrt>/package/
```

---

## A. 上游源码同步（`sources`）

```json
{
  "sources": [
    {
      "name": "luci-app-passwall",
      "repo": "Openwrt-Passwall/openwrt-passwall",
      "ref": "main",
      "dirs": ["luci-app-passwall"],
      "target": "."
    },
    {
      "name": "passwall-packages",
      "repo": "Openwrt-Passwall/openwrt-passwall-packages",
      "ref": "main",
      "dirs": ["*"],
      "exclude": [".github", ".gitattributes", "LICENSE", "README.md"],
      "target": "."
    }
  ]
}
```

| 字段 | 必填 | 默认 | 说明 |
|---|---|---|---|
| `name` | ✅ | — | 名称，同时是状态文件名 |
| `repo` | ✅ | — | 上游仓库 `owner/repo` |
| `ref` | | `main` | 分支 / tag / commit |
| `dirs` | | `["*"]` | 要拷贝的目录；`"*"` = 顶层全部条目 |
| `exclude` | | `[]` | `dirs` 含 `"*"` 时排除的条目 |
| `target` | | `.` | 落地目录（`.` = 仓库根目录） |

**行为**：按 `ref` 拉上游 commit SHA，SHA 没变就跳过；变了就整目录 `rm -rf` 后重新拷贝，
保证上游删除的文件不会残留。每次同步写 `.state/source-<name>.json` 并推送通知。

> 想加更多上游（比如 `xiaorouji/openwrt-passwall`、`sbwml/openwrt-passwall`），
> 在 `sources` 里多加条目即可，无需改代码。

---

## B. 版本 / 哈希自动更新（`packages`）

三种策略：

### 策略 1：`tarball` —— 源码包（最常见）

自动取上游 Release/Tag → 下载源码包 → 算 SHA256 → 写 `PKG_VERSION` + `PKG_HASH`。

```json
{
  "name": "xray-core",
  "repo": "XTLS/Xray-core",
  "makefile": "xray-core/Makefile",
  "strategy": "tarball",
  "source": "release",
  "include_prerelease": true,
  "tag_prefix": "v",
  "source_url": "https://codeload.github.com/XTLS/Xray-core/tar.gz/v${VERSION}?",
  "reset_release_on_change": false
}
```

| 字段 | 默认 | 说明 |
|---|---|---|
| `makefile` | `<name>/Makefile` | 目标 Makefile |
| `source` | `release` | `release` = 跟 Release；`tag` = 跟 Tag |
| `include_prerelease` | `true` | 是否包含 pre-release |
| `tag_prefix` | `""` | 剥掉的前缀，`v26.10.21` → `26.10.21` |
| `version_regex` | — | bash 正则，**组1 = 版本，组2（可选）= `PKG_RELEASE`**；优先于 `tag_prefix` |
| `source_url` | `https://codeload.github.com/${REPO}/tar.gz/${TAG}` | 下载地址模板 |
| `reset_release_on_change` | `false` | 版本变化时把 `PKG_RELEASE` 归 1 |

> ⚠️ `source_url` **必须和 Makefile 里 `PKG_SOURCE_URL` 的实际下载地址一致**，
> 否则算出的 `PKG_HASH` 和 OpenWrt 校验值对不上。
> 本项目默认从 `codeload.github.com` 下载（等价于 `github.com/.../archive/refs/tags/...tar.gz`）。

**已配置的 tarball 包（10 个）**：
`xray-core` `xray-plugin` `v2ray-plugin` `sing-box` `hysteria` `geoview`
`shadow-tls` `shadowsocks-rust` `ipt2socks` `microsocks`

### 策略 2：`assets` —— 多架构预编译 / geodata

一次性下载多个资源，**逐个算 SHA256** 并按 `anchor` 定位写回 Makefile 对应的
`PKG_HASH` / `HASH` 行。用于 `chinadns-ng`（17 个架构二进制）、`naiveproxy`
（21 个架构 tar.xz）、`v2ray-geodata`（`geoip.dat` / `geosite.dat`）。

```json
{
  "name": "chinadns-ng",
  "repo": "zfl9/chinadns-ng",
  "makefile": "chinadns-ng/Makefile",
  "strategy": "assets",
  "version": { "repo": "zfl9/chinadns-ng", "source": "release", "tag_prefix": "" },
  "assets": [
    {
      "id": "chinadns-ng+wolfssl@x86_64-linux-musl@x86_64@fast+lto",
      "anchor": "PKG_ARCH:=chinadns-ng+wolfssl@x86_64-linux-musl@x86_64@fast+lto",
      "asset": "chinadns-ng+wolfssl@x86_64-linux-musl@x86_64@fast+lto",
      "url": "https://github.com/zfl9/chinadns-ng/releases/download/${VERSION}/${ASSET}?",
      "hash_var": "PKG_HASH"
    }
  ]
}
```

| 字段 | 说明 |
|---|---|
| `version` | 包级版本来源（`repo`/`source`/`tag_prefix`/`version_regex`），可省略 |
| `assets[].id` | 资源标识，用于日志与状态 |
| `assets[].anchor` | **字面量锚点**，定位到 Makefile 中该资源所在块的起始行 |
| `assets[].asset` | 文件名，用于 `${ASSET}`；省略时取 `id` |
| `assets[].url` | 下载地址模板 |
| `assets[].hash_var` | 要写的校验变量名，默认 `PKG_HASH`（geodata 用 `HASH`） |
| `assets[].ver_anchor` / `ver_line` | 可选，顺带更新版本变量（如 `GEOIP_VER`） |
| `assets[].version` | 可选，该资源单独的版本来源 |

**URL / ver_line 模板占位符**：`${REPO}` `${TAG}` `${VERSION}` `${RELEASE}` `${ASSET}`，
也兼容 `$(PKG_VERSION)`。

**已配置的 assets 包（3 个）**：
`chinadns-ng`（14 个唯一资源） `naiveproxy`（21 个架构） `v2ray-geodata`（2 个）

### 策略 3：`notify` —— 只提醒，不自动改

用于**源码内嵌**（`dns2socks`、`shadowsocksr-libev`）或 **git-commit 型**
（`simple-obfs`、`tcping`、`smartdns`，用 `PKG_SOURCE_PROTO:=git` +
`PKG_MIRROR_HASH`，本地无法可靠复现 mirror hash）的包。只检测上游是否有新版并推送提醒。

```json
{
  "name": "simple-obfs",
  "makefile": "simple-obfs/Makefile",
  "strategy": "notify",
  "repo": "shadowsocks/simple-obfs",
  "source": "release",
  "include_prerelease": false,
  "tag_prefix": "v",
  "note": "git-commit 型，跟随上游 tag 提醒"
}
```

`repo` 留空 = 不轮询上游（由 `sources` 的源码同步维护），仅登记一笔。

---

## 配置模板占位符速查

| 占位符 | 含义 |
|---|---|
| `${REPO}` | `owner/repo` |
| `${TAG}` | 上游 tag 原文（如 `v26.10.21`） |
| `${VERSION}` | 推导出的版本号（如 `26.10.21`） |
| `${RELEASE}` | `version_regex` 第 2 捕获组（如 `PKG_RELEASE`） |
| `${ASSET}` | 资源文件名 |
| `$(PKG_VERSION)` | 同 `${VERSION}`，方便直接抄 Makefile 写法 |

---

## 推送通知（可选）

配置即生效，留空则跳过该渠道。**建议用环境变量，不要写死在脚本里。**

```bash
# Telegram
export TELEGRAM_BOT_TOKEN="***"
export TELEGRAM_CHAT_ID="123456789"

# WxPusher
export WXPUSHER_APP_TOKEN="***"
export WXPUSHER_UIDS="UID_xxx,UID_yyy"     # 多个用英文逗号
export WXPUSHER_TOPIC_IDS="123,456"        # 或/且用主题
```

---

## GitHub Actions 自动同步

### 1. 推到 GitHub

```bash
cd github-release-sync
git init && git add . && git commit -m "init: github-release-sync"
git remote add origin git@github.com:<you>/<repo>.git
git push -u origin main
```

### 2. （可选）配置 Secrets

仓库 → **Settings → Secrets and variables → Actions**：

| Secret | 用途 |
|---|---|
| `TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID` | Telegram 推送 |
| `WXPUSHER_APP_TOKEN` / `WXPUSHER_UIDS` / `WXPUSHER_TOPIC_IDS` | WxPusher 推送 |

`GITHUB_TOKEN` 由 Actions 自动提供（已申请 `contents: write`）。

### 3. 触发方式

| 触发 | 说明 |
|---|---|
| `schedule` | 每 6 小时一次（`cron: "15 */6 * * *"`，可改） |
| `workflow_dispatch` | 手动运行：可勾 **force**、指定 **only**、选 **commit / pr** |
| `push`（改 `config/` 或脚本） | 配置一变就立即同步 |

### 4. 变更落地

* **commit**（默认）：直接 commit + push，message 带 `[skip ci]` 防递归。
* **pr**：开 `auto-sync/upstream` 分支的 Pull Request，人工审核后合并。

---

## 状态文件

每次运行在 `.state/` 留一份记录，便于排查：

```
.state/
├── source-luci-app-passwall.json      # 上游 commit + 同步的条目
├── source-passwall-packages.json
├── pkg-xray-core.json                 # tag / version / hash
├── pkg-chinadns-ng.json               # 各资源 version 明细
└── ...
```

---

## FAQ

**Q：算出的 `PKG_HASH` 和 OpenWrt 校验值对不上？**
A：`source_url` 必须和 Makefile 里 `PKG_SOURCE_URL` 的**实际下载地址**完全一致。

**Q：`chinadns-ng` / `naiveproxy` 这种多架构的怎么办？**
A：用 `assets` 策略。工具会逐个下载每个 `PKG_ARCH` / `ARCH_PREBUILT` 对应的文件算 hash，
再按 `anchor` 写回 Makefile 对应的分支。同一 `PKG_ARCH` 出现多次（比如 arm v6 与
arm v7 无 FPU 共用一个二进制）会全部一起更新。

**Q：为什么 `dns2socks` / `shadowsocksr-libev` 不自动更新版本？**
A：它们源码直接内嵌在包目录里（`src/`），没有可下载的源码包，
由 `sources` 从 `openwrt-passwall-packages` 上游整体同步维护。

**Q：`simple-obfs` / `tcping` / `smartdns` 呢？**
A：`PKG_SOURCE_PROTO:=git` + `PKG_MIRROR_HASH` 型。`PKG_MIRROR_HASH` 是 OpenWrt
对 git 仓库打包后的镜像哈希，本地无法可靠复现，所以只做版本提醒，避免写错哈希导致构建失败。

**Q：想再加一个 luci-app？**
A：`sources` 里加一条即可，例如：

```json
{ "name": "luci-app-xxx", "repo": "someone/luci-app-xxx",
  "ref": "main", "dirs": ["luci-app-xxx"], "target": "packages" }
```

**Q：GitHub API 限流？**
A：设置 `GITHUB_TOKEN`。Actions 里已经自动用上了 `secrets.GITHUB_TOKEN`，
本地建议用 Personal Access Token（勾 `public_repo` 即可）。

**Q：能只跑一半吗？**
A：`--sync-source` 只同步源码，`--skip-source` 只更新版本哈希，`--only <name>` 处理单项。
