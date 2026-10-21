# github-release-sync

**GitHub 上游同步 + OpenWrt 插件包版本/哈希自动维护工具**

两层能力：

| 层 | 作用 | 说明 |
|---|---|---|
| **A. `sources`** | 同步上游源码 | 把 `luci-app-XXX`、依赖包源码从上游仓库拉到本地，支持**多个上游**，按 commit 变化增量同步 |
| **B. `packages`** | 自动更新版本/校验值 | 在本地 Makefile 上自动写 `PKG_VERSION` / `PKG_HASH`，支持**三种策略** |

外加**版本闸门**：上游版本不高于本地已算出的版本就**忽略同步**，不会把你的包降级。

支持 **GitHub Actions 定时自动同步**，可选 **Telegram / WxPusher** 推送。

---

## 目录布局

**插件包 / 软件包目录直接放在仓库根目录**，不嵌套二级目录
（与 [`VIKINGYFY/packages`](https://github.com/VIKINGYFY/packages) 同布局）：

```
your-repo/                        ← 仓库根目录 = 一个 OpenWrt package feed
├── luci-app-passwall/            # ┐
├── luci-app-passwall2/           # │
├── luci-app-nikki/               # │ 插件 + 软件包全部在根目录
├── xray-core/  sing-box/  ...    # │
├── chinadns-ng/  naiveproxy/ ... # ┘
├── update.sh  config/  lib/      #   同步工具（无 Makefile，OpenWrt 自动忽略）
├── test/  .github/  README.md
└── .state/                       # 运行状态（已 .gitignore）
```

OpenWrt 直接拉取，不用再套一层：

```bash
src-link passwall /path/to/repo           # 或
git clone <repo> <openwrt>/package/passwall
```

---

## 快速开始

```bash
# 依赖
sudo apt-get install -y curl jq coreutils tar     # macOS: brew install curl jq gnu-tar

bash update.sh                # 全量：同步源码 + 更新版本哈希
bash update.sh --dry-run      # 只看会改什么，不动文件
bash update.sh --force        # 忽略缓存与版本闸门，强制重新拉取 / 重算
bash update.sh --only xray-core
bash update.sh --sync-source  # 只同步上游源码
bash update.sh --skip-source  # 只更新版本哈希
```

---

## A. 上游源码同步（`sources`）

已配置 5 个上游：

| name | 上游 | 同步内容 |
|---|---|---|
| `luci-app-passwall` | `Openwrt-Passwall/openwrt-passwall` | `luci-app-passwall/` |
| `luci-app-passwall2` | `Openwrt-Passwall/openwrt-passwall2` | `luci-app-passwall2/` |
| `passwall-packages` | `Openwrt-Passwall/openwrt-passwall-packages` | 17 个依赖包（**不含 `sing-box`**） |
| `nikki` | `nikkinikki-org/OpenWrt-nikki` | `luci-app-nikki/` `nikki/` `mihomo-meta/` `mihomo-alpha/` |
| `vikingyfy-packages` | `VIKINGYFY/packages` | `sing-box/` `axonhub/` `gecoosac/` `luci-app-homeproxy/` `luci-app-wolultra/` `luci-app-axonhub/` `luci-app-gecoosac/` |
| `luci-theme-material3` | `KawaiiHachimi/luci-theme-material3` | **整个仓库** → `luci-theme-material3/`（`as_package` 模式） |

> **`sing-box` 取自 `VIKINGYFY/packages`**（`passwall-packages` 的 `sing-box` 已加进 `exclude`）。
> VIKINGYFY 的版本用 `PKG_UPSTREAM_VERSION` 承载（`PKG_VERSION` 由 `$(subst)` 派生），
> 已通过 `version_var: "PKG_UPSTREAM_VERSION"` 适配，不会破坏派生式。

```json
{
  "name": "vikingyfy-packages",
  "repo": "VIKINGYFY/packages",
  "ref": "main",
  "dirs": ["*"],
  "exclude": [".github", ".gitattributes", "LICENSE", "README.md"],
  "target": "."
}
```

| 字段 | 默认 | 说明 |
|---|---|---|
| `name` | — | 名称，同时是状态文件名 |
| `repo` | — | 上游仓库 `owner/repo` |
| `ref` | `main` | 分支 / tag / commit |
| `dirs` | `["*"]` | 要拷贝的目录；`"*"` = 顶层全部条目 |
| `exclude` | `[]` | `dirs` 含 `"*"` 时排除的条目 |
| `target` | `.` | 落地目录（`.` = 仓库根目录） |
| `as_package` | `false` | **上游整棵树就是一个包**，全部落到 `target` 目录内（先清空再拷） |
| `skip_if_not_newer` | `true` | **版本闸门**，见下 |
| `version_vars` | `["PKG_VERSION","PKG_UPSTREAM_VERSION","GEOIP_VER","GEOSITE_VER"]` | 参与版本比较的变量 |

**行为**：按 `ref` 拉上游 commit SHA，SHA 没变就跳过；变了才下载。

* **默认模式**（`as_package: false`）：每个条目落到 `target/<条目>`，逐条 `rm -rf` 后重拷，
  保证上游删除的文件不残留。
* **`as_package: true`**：上游仓库**本身就是一个 OpenWrt 包**（如 LuCI 主题），
  整棵树落到 `target` 目录内，**先清空 `target` 再拷**。
  版本闸门以 `target/Makefile` 整包判定一次，
  **判定为“忽略”时不会动本地目录**（不会先删再跳）。

```json
{
  "name": "luci-theme-material3",
  "repo": "KawaiiHachimi/luci-theme-material3",
  "ref": "main",
  "as_package": true,
  "target": "luci-theme-material3",
  "exclude": [".github", "Readme.md", "imgs"]
}
```

---

## B. 版本 / 哈希自动更新（`packages`）

### 策略 1：`tarball` —— 源码包（最常见）

```json
{
  "name": "sing-box",
  "repo": "SagerNet/sing-box",
  "makefile": "sing-box/Makefile",
  "strategy": "tarball",
  "source": "release",
  "include_prerelease": true,
  "tag_prefix": "v",
  "version_var": "PKG_UPSTREAM_VERSION",
  "hash_var": "PKG_HASH",
  "source_url": "https://codeload.github.com/SagerNet/sing-box/tar.gz/v${VERSION}?"
}
```

| 字段 | 默认 | 说明 |
|---|---|---|
| `makefile` | `<name>/Makefile` | 目标 Makefile |
| `source` | `release` | `release` = 跟 Release；`tag` = 跟 Tag |
| `include_prerelease` | `true` | 是否包含 pre-release |
| `tag_prefix` | `""` | 剥掉的前缀，`v26.10.21` → `26.10.21` |
| `version_regex` | — | bash 正则，**组1 = 版本，组2（可选）= `PKG_RELEASE`**；优先于 `tag_prefix` |
| `version_var` | `PKG_VERSION` | 版本写到哪个变量（VIKINGYFY 的 sing-box 用 `PKG_UPSTREAM_VERSION`） |
| `hash_var` | `PKG_HASH` | 校验值写到哪个变量 |
| `source_url` | `https://codeload.github.com/${REPO}/tar.gz/${TAG}` | 下载地址模板 |
| `reset_release_on_change` | `false` | 版本变化时把 `PKG_RELEASE` 归 1 |
| `skip_if_not_newer` | `true` | 版本闸门 |

> ⚠️ `source_url` **必须和 Makefile 里 `PKG_SOURCE_URL` 的实际下载地址一致**，
> 否则算出的 `PKG_HASH` 和 OpenWrt 校验值对不上。
>
> ⚠️ `version_var` 指到的变量**只改第一处赋值**，后续的
> `PKG_VERSION:=$(subst …)` 这类派生式不会被碰。

**已配置（11 个）**：`xray-core` `xray-plugin` `v2ray-plugin` `sing-box` `hysteria`
`geoview` `shadow-tls` `shadowsocks-rust` `ipt2socks` `microsocks`（+ 见下）

### 策略 2：`assets` —— 多架构预编译 / geodata

一次性下载多个资源，**逐个算 SHA256**，按 `anchor` 定位写回对应的 `PKG_HASH` / `HASH` 行。

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
| `version` | 包级版本来源；也可用 `version_var` 指定写入的变量 |
| `assets[].id` | 资源标识，用于日志与状态 |
| `assets[].anchor` | **字面量锚点**，定位到该资源所在块的起始行 |
| `assets[].asset` | 文件名，用于 `${ASSET}`；省略时取 `id` |
| `assets[].url` | 下载地址模板 |
| `assets[].hash_var` | 校验变量名，默认 `PKG_HASH`（geodata 用 `HASH`） |
| `assets[].ver_anchor` / `ver_line` | 可选，顺带更新版本变量（如 `GEOIP_VER`） |
| `assets[].version` | 可选，该资源单独的版本来源 |

**已配置（3 个）**：`chinadns-ng`（14 个唯一资源） `naiveproxy`（21 个架构）
`v2ray-geodata`（`geoip.dat` / `geosite.dat`）

### 策略 3：`notify` —— 只提醒，不自动改

用于**源码内嵌**（`dns2socks`、`shadowsocksr-libev`）或 **git-commit 型**
（`simple-obfs` `tcping` `smartdns` `mihomo-meta` `mihomo-alpha` `axonhub`）。
`PKG_MIRROR_HASH` 是 OpenWrt 对 git 仓库打包后的镜像哈希，本地无法可靠复现，
硬写会让构建失败，所以只做提醒。

`repo` 留空 = 不轮询上游（由 `sources` 的源码同步维护），仅登记一笔。

---

## ⚠️ 版本闸门（`skip_if_not_newer`）

> **上游版本没有本地已算出的版本高，就忽略这个包的同步。**

这是为了避免上游回退 / 上游滞后 / 你自己抬过版本时被覆盖。

| 场景 | 行为 |
|---|---|
| 上游 `2.0.1` vs 本地 `2.0.0` | ✅ 同步 |
| 上游 `2.0.0` vs 本地 `2.0.0` | ⏭️ 忽略（不重复拉取） |
| 上游 `1.9.9` vs 本地 `2.0.0` | ⏭️ **忽略，不降级** |
| 本地无版本号 | ✅ 同步 |
| 值是 `$(subst …)` 派生式 | ✅ 同步（无法比较则放行） |

**多版本变量**（源码同步）：比较 `PKG_VERSION` / `PKG_UPSTREAM_VERSION` /
`GEOIP_VER` / `GEOSITE_VER` 一组变量 —— **只要有一个上游严格更新就同步**，
全部不更高才忽略。这样 `v2ray-geodata`（靠 `GEOIP_VER`/`GEOSITE_VER` 版本化）
也能正确判定。

* 想强制覆盖：`bash update.sh --force`
* 想关掉某个包的闸门：配置里写 `"skip_if_not_newer": false`

### 版本比较规则

点分段逐段数字比较（`26.10.21 > 26.9.15`，`1.14.3 > 1.9.9`）；
遇到非数字段退化为字符串比较。

---

## 模板占位符

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

配置即生效，留空则跳过。**建议用环境变量，不要写死在脚本里。**

```bash
export TELEGRAM_BOT_TOKEN="***"
export TELEGRAM_CHAT_ID="123456789"

export WXPUSHER_APP_TOKEN="***"
export WXPUSHER_UIDS="UID_xxx,UID_yyy"
export WXPUSHER_TOPIC_IDS="123,456"
```

---

## GitHub Actions 自动同步

1. **推到 GitHub**：`git init && git add . && git commit -m init && git push`
2. **（可选）Secrets**：`TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID` /
   `WXPUSHER_APP_TOKEN` / `WXPUSHER_UIDS` / `WXPUSHER_TOPIC_IDS`
   （`GITHUB_TOKEN` 自动提供）
3. **触发**：`schedule`（每 6 小时）/ `workflow_dispatch`（手动，可选 force/only/commit|pr）/
   `push`（改 `config/` 或脚本时）
4. **落地**：`commit` 直推（带 `[skip ci]` 防递归）或 `pr` 开分支审核

---

## 🔨 GitHub Actions 编译插件

`.github/workflows/build.yml` —— 用 **OpenWrt SDK** 在 Actions 里交叉编译插件，
产物（`.ipk` / `.apk`）作为 artifact 下载。

仓库 → **Actions → Build Packages → Run workflow**

### 选平台（默认 X86_64）

| 选项 | 说明 |
|---|---|
| **`x86/64`** | **X86_64（默认）** |
| `x86/generic` | X86 32 位 |
| `armsr/armv8` | AArch64 通用 |
| `armsr/armv7` | ARMv7 通用 |
| `rockchip/armv8` | Rockchip RK33xx / RK35xx |
| `bcm27xx/bcm2711` | 树莓派 4 / 5 (aarch64) |
| `bcm27xx/bcm2710` | 树莓派 2 / 3 |
| `mediatek/filogic` | MTK Filogic (aarch64) |
| `ramips/mt7621` | MTK MT7621 (mipsel) |
| `ramips/mt76x8` | MTK MT76x8 (mipsel) |
| `ath79/generic` | Atheros AR7xxx (mips) |
| `ipq807x/generic` | 高通 IPQ807x (aarch64) |
| `sunxi/cortexa8` | 全志 H3 |

### 选编译哪些插件（`preset`）

| preset | 内容 |
|---|---|
| **`all`** | **全部 31 个包（默认）** |
| `luci-app` | 所有 `luci-app-*` |
| `theme` | 所有 `luci-theme-*` |
| `proxy-core` | `xray-core` `sing-box` `hysteria` `shadowsocks-rust` `mihomo-*` `naiveproxy` `chinadns-ng` 等 15 个 |
| `passwall` | passwall 全家桶 19 个（luci-app + 全部依赖） |
| `nikki` | nikki 全家桶 4 个 |
| `custom` | 自己填，用 `packages` 输入 |

`custom` 时在 `packages` 里填包名，**空格或逗号分隔**，例如：

```
luci-app-passwall, xray-core, sing-box
```

### 其他参数

| 参数 | 默认 | 说明 |
|---|---|---|
| `openwrt_version` | `25.12.6` | 也可填 `24.10.5` / `snapshot` |
| `upload_all` | `false` | 开启则连 `-dbg` / `-dev` 一起上传 |

### 实现要点

* **SDK 文件名动态解析**：`openwrt-sdk-<ver>-<target>-<subtarget>_gcc-<gcc>_musl.Linux-x86_64.tar.zst`
  里的 GCC 版本会随 OpenWrt 版本变（25.12 是 `gcc-14.3.0`，24.10 是 `gcc-13.3.0`），
  硬编码必失效。改为**拉目录列表正则匹配**，任何版本/平台都能解析。
* **`.ipk` / `.apk` 都收**：OpenWrt 25.x 换成 `apk` 包管理，24.x 及以前是 `ipk`。
* **包名冲突处理**：官方 `packages` feed 里可能有同名包（如 `microsocks`），
  注入前先删掉 `package/feeds/**/<name>`，保证用的是本仓库版本。
* **单包失败不拖垮整个 job**：逐包编译，失败的记进 `build-result.txt` 并在
  Summary 里列出，产物与日志仍会上传。
* **产物**：
  * `packages` —— 编译出的 `.ipk`/`.apk`
  * `build-logs` —— 每个包一份完整 `V=s` 编译日志（失败时排查用）

### 本地跑同样的事

```bash
# 1. 下 SDK（以 x86/64 + 25.12.6 为例）
BASE=https://downloads.openwrt.org/releases/25.12.6/targets/x86/64
SDK=$(curl -sL "$BASE/" | grep -oE 'openwrt-sdk-[^"<]+\.Linux-x86_64\.tar\.(zst|xz)' | sort -u | head -1)
curl -LO "$BASE/$SDK"

# 2. 解压 + feeds
mkdir sdk && tar --zstd -xf "$SDK" -C sdk --strip-components=1
cd sdk && ./scripts/feeds update -a && ./scripts/feeds install -a

# 3. 放包 + 编译
cp -a ../xray-core ../sing-box package/
make defconfig
make package/xray-core/compile -j$(nproc) V=s

# 4. 产物
ls bin/packages/*/*/*.ipk bin/packages/*/*/*.apk 2>/dev/null
```

---

## 状态文件

```
.state/
├── source-<name>.json     # 上游 commit + 已同步 / 已忽略的条目
└── pkg-<name>.json        # tag / version / hash 明细
```

---

## 自测

```bash
bash test/test-write.sh
```

覆盖：Makefile 写入（缩进保留、只改第一处、不碰 `$(subst)` 派生式）、
多架构锚点替换（含重复锚点）、**原值写回逐字节一致的回环测试**、
版本比较、版本闸门、字面量判定、模板展开。

---

## FAQ

**Q：`chinadns-ng` / `naiveproxy` 这种多架构的怎么办？**
A：`assets` 策略逐个下载每个 `PKG_ARCH` / `ARCH_PREBUILT` 对应文件算 hash。
同一 `PKG_ARCH` 出现多次（如 arm v6 与 v7 无 FPU 共用一个二进制）会全部一起更新。

**Q：为什么 `sing-box` 的 `PKG_VERSION` 是 `$(subst …)`？**
A：那是 VIKINGYFY 的写法 —— `PKG_UPSTREAM_VERSION` 存上游原版（如 `1.15.0-alpha.12`），
`PKG_VERSION` 在 make 时把 `-alpha.` 转成 `_alpha` 以满足 APK 的预发布后缀格式。
工具通过 `version_var: "PKG_UPSTREAM_VERSION"` 只写上游版本变量，派生式原样保留。

**Q：`simple-obfs` / `tcping` / `smartdns` / `mihomo-*` 为什么不自动更新？**
A：`PKG_SOURCE_PROTO:=git` + `PKG_MIRROR_HASH` / `PKG_SOURCE_VERSION` 型。
镜像哈希本地无法可靠复现，只做版本提醒，避免写错哈希导致构建失败。

**Q：想再加一个上游？**
A：`sources` 里加一条即可：

```json
{ "name": "luci-app-xxx", "repo": "someone/luci-app-xxx",
  "ref": "main", "dirs": ["luci-app-xxx"], "target": "." }
```

**Q：GitHub API 限流？**
A：设置 `GITHUB_TOKEN`。Actions 已自动用 `secrets.GITHUB_TOKEN`，
本地建议用 PAT（勾 `public_repo` 即可）。

**Q：能只跑一半吗？**
A：`--sync-source` 只同步源码，`--skip-source` 只更新版本哈希，
`--only <name>` 处理单项，`--force` 绕过缓存与版本闸门。
