#!/usr/bin/env bash
# ============================================================================
#  auto-deps.sh —— 自动补全缺失的构建依赖
#
#  问题：有些包的 PKG_BUILD_DEPENDS 引用了**官方 feed 里不存在**的宿主工具包。
#        例：VIKINGYFY 的 axonhub 写了 `PKG_BUILD_DEPENDS:=golang/host node/host node-pnpm/host`，
#        但 openwrt/packages 的 lang/ 下只有 node / node-yarn / node-javascript-obfuscator，
#        **没有 node-pnpm** → make 直接 "No rule to make target 'package/node-pnpm/host/...'"
#
#  做法：扫描 package/*/Makefile 里的 PKG_BUILD_DEPENDS（以及 DEPENDS 里的 x/host），
#        找出 SDK 里不存在的 <name>/host，**自动生成一个 HostBuild 存根包**，
#        存根包的 Host/Compile 按下面的 hint 表安装真正的工具。
#
#  用法：在 SDK 根目录运行
#        bash tools/auto-deps.sh [package 列表文件，默认 pkglist.txt]
#
#  环境变量：
#        AUTO_DEPS_DRY=1   只打印会做什么，不落地
# ============================================================================
set -uo pipefail

LIST_FILE="${1:-pkglist.txt}"
DRY="${AUTO_DEPS_DRY:-0}"

if [ ! -d package ]; then
  echo "[auto-deps] 当前不在 SDK 根目录（找不到 package/），退出"
  exit 1
fi

if [ ! -f "$LIST_FILE" ]; then
  echo "[auto-deps] 找不到包列表 $LIST_FILE，退出"
  exit 1
fi

# ---------------------------------------------------------------------------
# hint 表：<name> → 存根包 Host/Compile 里要跑的安装命令
#            （留空则只做存在性检查，不安装任何东西）
# ---------------------------------------------------------------------------
hint_install() {
  case "$1" in
    node-pnpm|pnpm)      echo "sudo npm install -g pnpm || npm install -g pnpm" ;;
    yarn)                echo "sudo npm install -g yarn || npm install -g yarn" ;;
    corepack)            echo "sudo npm install -g corepack || npm install -g corepack" ;;
    node-sass)           echo "sudo npm install -g node-sass || npm install -g node-sass" ;;
    rust|rustc|cargo)    echo "command -v cargo >/dev/null 2>&1 || (curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y)" ;;
    *)                   echo "" ;;
  esac
}

# hint 表：<name> → 装完后应该出现的**二进制名**（跟包名不一定一样）
#   如 node-pnpm 装出来的是 pnpm，拿包名去 command -v 会误报
hint_binary() {
  case "$1" in
    node-pnpm|pnpm)   echo "pnpm" ;;
    node-yarn|yarn)   echo "yarn" ;;
    node-sass)        echo "node-sass" ;;
    rust|rustc)       echo "rustc" ;;
    cargo)            echo "cargo" ;;
    *)                echo "$1" ;;
  esac
}

# 该依赖是否已经存在（package/ 或 feeds/ 下有同名包）
dep_exists() {
  local n="$1"
  [ -d "package/$n" ] && return 0
  find package/feeds feeds -maxdepth 4 -name "$n" 2>/dev/null | grep -q . && return 0
  return 1
}

# 生成 HostBuild 存根包
gen_stub() {
  local n="$1" cmd="$2"
  local bin dir="package/$n"
  bin=$(hint_binary "$n")
  mkdir -p "$dir"

  local compile_body
  if [ -n "$cmd" ]; then
    compile_body="	@echo \"[auto-deps] 安装宿主工具: $n → $bin\"
	$cmd
	@command -v $bin >/dev/null 2>&1 || echo \"[auto-deps][warn] 装完仍找不到 $bin，看上面的输出\""
  else
    compile_body="	@echo \"[auto-deps] $n 无安装提示，跳过安装\"
	@command -v $bin >/dev/null 2>&1 || echo \"[auto-deps][warn] 缺少 $bin，请自行安装\""
  fi

  cat > "$dir/Makefile" <<EOF
# 本文件由 tools/auto-deps.sh 自动生成，用于补全 \$(PKG_BUILD_DEPENDS) 里
# 官方 feed 中不存在的宿主工具包。删掉后会重新生成。
include \$(TOPDIR)/rules.mk

PKG_NAME:=$n
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_LICENSE:=MIT
PKG_MAINTAINER:=auto-deps

include \$(INCLUDE_DIR)/host-build.mk

define Host/Prepare
	mkdir -p \$(HOST_BUILD_DIR)
endef

define Host/Compile
$compile_body
endef

define Host/Install
endef

define Host/Clean
endef

\$(eval \$(call HostBuild))
EOF
  echo "[auto-deps] ✅ 生成存根包 package/$n  （→ 二进制 $bin，安装: ${cmd:-<无提示>}）"
}

echo "[auto-deps] ══════════════════════════════════════════════════"
echo "[auto-deps] 扫描 PKG_BUILD_DEPENDS，补全缺失的宿主工具包"
echo "[auto-deps] ══════════════════════════════════════════════════"

# ---- 收集所有 PKG_BUILD_DEPENDS 里的 <name>/host ----
DEPS=""
for p in $(cat "$LIST_FILE"); do
  mk="package/$p/Makefile"
  [ -f "$mk" ] || continue
  # PKG_BUILD_DEPENDS 可跨行（行尾 \），先拍平
  flat=$(awk '{
        line=$0
        if (match(line, /^[ \t]*PKG_BUILD_DEPENDS[ \t]*[:?+]?=/)) {
          sub(/^[ \t]*PKG_BUILD_DEPENDS[ \t]*[:?+]?=/, "", line)
          buf=line
          while (buf ~ /\\$/) { sub(/\\$/, "", buf); if (getline nl > 0) buf=buf nl }
          print buf
        }
      }' "$mk")
  for d in $flat; do
    case "$d" in
      */host) DEPS="$DEPS ${d%/host}" ;;
      host)   DEPS="$DEPS " ;;
    esac
  done
done

DEPS=$(echo "$DEPS" | tr ' ' '\n' | sort -u | grep -v '^$' | tr '\n' ' ')
echo "[auto-deps] 出现在 PKG_BUILD_DEPENDS 里的宿主工具: ${DEPS:-<无>}"

MADE=0
for n in $DEPS; do
  if dep_exists "$n"; then
    echo "[auto-deps] ✓ $n 已存在，跳过"
    continue
  fi
  cmd=$(hint_install "$n")
  if [ "$DRY" = "1" ]; then
    echo "[auto-deps][dry] 将生成 package/$n  （Host/Compile: ${cmd:-<无提示>}）"
  else
    gen_stub "$n" "$cmd"
    MADE=$((MADE + 1))
  fi
done

echo "[auto-deps] ───────────────────────────────────────────────────"
if [ "$DRY" = "1" ]; then
  echo "[auto-deps] dry-run 结束"
else
  echo "[auto-deps] 本次生成 $MADE 个存根包"
fi

# 退出码：0 = 正常（生成 0 个也算正常）
exit 0
