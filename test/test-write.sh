#!/usr/bin/env bash
# 离线单元测试：验证 Makefile 写入逻辑（不联网）
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

GRM_LIB_ONLY=1 source ./update.sh
set +e   # update.sh 里的 set -e 会作用于调用方，这里关掉，改为逐断言计数
set -uo pipefail

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()   { echo "  ✅ $*"; pass=$((pass+1)); }
bad()  { echo "  ❌ $*"; fail=$((fail+1)); }

# 从 Makefile 里抽出 (锚点 -> hash) 映射；用字面量查找避免 awk 正则方言差异
extract_naive() {
  awk '{
         p = index($0, "$(ARCH_PREBUILT),")
         if (p > 0) {
           rest = substr($0, p + 17)
           c   = index(rest, ")")
           cur = substr(rest, 1, c - 1)
           next
         }
         if (cur != "" && match($0, /^[ \t]*PKG_HASH:=/)) {
           print cur "=" substr($0, RLENGTH + 1)
           cur = ""
         }
       }' "$1"
}
extract_china() {
  awk '/^ *PKG_ARCH:=/ { cur = substr($0, index($0,":=")+2); next }
       /^ *PKG_HASH:=/ && cur != "" { print cur "=" substr($0, index($0,"=")+1); cur="" }' "$1"
}

echo "════ 1. naiveproxy：21 个架构锚点 + PKG_HASH ════"
cp naiveproxy/Makefile "$T/n.orig"
cp "$T/n.orig" "$T/n.new"
mapfile -t ARCHS < <(jq -r '.packages[] | select(.name=="naiveproxy") | .assets[].id' config/packages.json)
[[ ${#ARCHS[@]} -eq 21 ]] && ok "配置解析出 21 个架构" || bad "架构数=${#ARCHS[@]}，期望 21"
[[ $(extract_naive "$T/n.orig" | wc -l) -eq 21 ]] && ok "Makefile 解析出 21 组 (架构→hash)" \
  || bad "解析出 $(extract_naive "$T/n.orig" | wc -l) 组"

i=0
for a in "${ARCHS[@]}"; do
  fake="fakehash$(printf '%02d' $i)xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
  replace_hash_after_anchor "$T/n.new" "ifeq (\$(ARCH_PREBUILT),$a)" "PKG_HASH" "$fake"
  i=$((i+1))
done

# 每个锚点都应拿到自己的 fake hash
i=0; mism=0
for a in "${ARCHS[@]}"; do
  fake="fakehash$(printf '%02d' $i)xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
  got=$(grep -A1 -F "ifeq (\$(ARCH_PREBUILT),$a)" "$T/n.new" | grep -m1 'PKG_HASH:=' | sed 's/.*PKG_HASH:=//')
  [[ "$got" == "$fake" ]] || { bad "  $a -> $got"; mism=$((mism+1)); }
  i=$((i+1))
done
[[ $mism -eq 0 ]] && ok "21 个锚点的 PKG_HASH 全部写对"

# 除 PKG_HASH 行外不应有其他改动
changed=$(diff "$T/n.orig" "$T/n.new" | grep -E '^[<>]' | grep -vcE '^[<>] +PKG_HASH:=')
[[ "$changed" -eq 0 ]] && ok "除 PKG_HASH 行外无其他改动" || bad "有 $changed 行非 PKG_HASH 被改动"
[[ $(grep -c 'fakehash' "$T/n.new") -eq 21 ]] && ok "恰好 21 处 hash 被替换" || bad "替换处数=$(grep -c 'fakehash' "$T/n.new")"

# 回环测试：用原值再写一遍，必须逐字节回到原文件（验证缩进/格式不被破坏）
cp "$T/n.new" "$T/n.rev"
for a in "${ARCHS[@]}"; do
  orig=$(extract_naive "$T/n.orig" | grep -F "${a}=" | head -1 | cut -d= -f2-)
  replace_hash_after_anchor "$T/n.rev" "ifeq (\$(ARCH_PREBUILT),$a)" "PKG_HASH" "$orig"
done
diff -q "$T/n.orig" "$T/n.rev" >/dev/null 2>&1 \
  && ok "回环测试：原值写回后与原文件逐字节一致（缩进/格式完好）" \
  || bad "回环测试失败：$(diff "$T/n.orig" "$T/n.rev" | head -4 | tr '\n' ' ')"

echo "════ 2. chinadns-ng：14 个唯一资源（含重复锚点） ════"
cp chinadns-ng/Makefile "$T/c.orig"
cp "$T/c.orig" "$T/c.new"
mapfile -t ASSETS < <(jq -r '.packages[] | select(.name=="chinadns-ng") | .assets[].id' config/packages.json)
[[ ${#ASSETS[@]} -eq 14 ]] && ok "配置解析出 14 个唯一资源" || bad "资源数=${#ASSETS[@]}"

i=0
for a in "${ASSETS[@]}"; do
  fake="chinhash$(printf '%02d' $i)xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
  replace_hash_after_anchor "$T/c.new" "PKG_ARCH:=$a" "PKG_HASH" "$fake"
  i=$((i+1))
done

# 同一 PKG_ARCH 出现两次的（arm v6 / v7 无 FPU）应全部被替换
[[ $(grep -c 'chinhash02' "$T/c.new") -eq 2 ]] && ok "重复锚点的 2 处 hash 都被替换" \
  || bad "重复锚点替换处数=$(grep -c 'chinhash02' "$T/c.new")（期望 2）"
[[ $(grep -c 'chinhash' "$T/c.new") -eq 15 ]] && ok "15 处 hash 被替换（14 唯一 + 1 重复）" \
  || bad "替换处数=$(grep -c 'chinhash' "$T/c.new")（期望 15）"
changed=$(diff "$T/c.orig" "$T/c.new" | grep -E '^[<>]' | grep -vcE '^[<>] +PKG_HASH:=')
[[ "$changed" -eq 0 ]] && ok "除 PKG_HASH 行外无其他改动" || bad "有 $changed 行非 PKG_HASH 被改动"

# 回环测试（含重复锚点场景）
cp "$T/c.new" "$T/c.rev"
for a in "${ASSETS[@]}"; do
  orig=$(extract_china "$T/c.orig" | grep -F "${a}=" | head -1 | cut -d= -f2-)
  replace_hash_after_anchor "$T/c.rev" "PKG_ARCH:=$a" "PKG_HASH" "$orig"
done
diff -q "$T/c.orig" "$T/c.rev" >/dev/null 2>&1 \
  && ok "回环测试：原值写回后与原文件逐字节一致" \
  || bad "回环测试失败：$(diff "$T/c.orig" "$T/c.rev" | head -4 | tr '\n' ' ')"

echo "════ 3. replace_var_line：PKG_VERSION / PKG_RELEASE ════"
cp xray-core/Makefile "$T/x.new"
replace_var_line "$T/x.new" "PKG_VERSION" "99.88.77"
replace_var_line "$T/x.new" "PKG_HASH" "$(printf 'ab%.0s' {1..32})"
replace_var_line "$T/x.new" "PKG_RELEASE" "7"
grep -q '^PKG_VERSION:=99.88.77$' "$T/x.new" && ok "PKG_VERSION 被改写" || bad "PKG_VERSION 未改写"
grep -q '^PKG_RELEASE:=7$' "$T/x.new" && ok "PKG_RELEASE 被改写" || bad "PKG_RELEASE 未改写"
grep -qF 'v$(PKG_VERSION)?' "$T/x.new" && ok "PKG_SOURCE_URL 里的 \$(PKG_VERSION) 未被误伤" || bad "PKG_SOURCE_URL 被误伤"
# 回环
replace_var_line "$T/x.new" "PKG_VERSION" "$(read_var_line xray-core/Makefile PKG_VERSION)"
replace_var_line "$T/x.new" "PKG_RELEASE" "$(read_var_line xray-core/Makefile PKG_RELEASE)"
replace_var_line "$T/x.new" "PKG_HASH" "$(read_var_line xray-core/Makefile PKG_HASH)"
diff -q xray-core/Makefile "$T/x.new" >/dev/null 2>&1 \
  && ok "回环测试：PKG_VERSION/RELEASE/HASH 写回后逐字节一致" \
  || bad "回环测试失败：$(diff packages/xray-core/Makefile "$T/x.new" | head -4 | tr '\n' ' ')"

echo "════ 4. replace_line_after_anchor：GEOIP_VER ════"
cp v2ray-geodata/Makefile "$T/g.new"
replace_line_after_anchor "$T/g.new" "GEOIP_VER:=" "GEOIP_VER:=209901010000"
grep -q '^GEOIP_VER:=209901010000$' "$T/g.new" && ok "GEOIP_VER 被改写" || bad "GEOIP_VER 未改写"
grep -q 'geoip.dat.\$(GEOIP_VER)' "$T/g.new" && ok "GEOIP_FILE 行未被误伤" || bad "GEOIP_FILE 行被误伤"

echo "════ 5. replace_hash_after_anchor：geodata 的 HASH:= ════"
replace_hash_after_anchor "$T/g.new" "define Download/geosite" "HASH" "$(printf 'cd%.0s' {1..32})"
g1=$(awk '/define Download\/geoip/{f=1} f&&/^ *HASH:=/{print; exit}' "$T/g.new")
g2=$(awk '/define Download\/geosite/{f=1} f&&/^ *HASH:=/{print; exit}' "$T/g.new")
[[ "$g1" == *4a1b1edd* ]] && ok "geoip 的 HASH 未被误改" || bad "geoip HASH=$g1"
[[ "$g2" == *cdcdcdcd* ]] && ok "geosite 的 HASH 被改写" || bad "geosite HASH=$g2"

echo "════ 6. derive_version：tag_prefix / version_regex ════"
v=$(derive_version "v26.10.21" "v" "")
[[ "$v" == "26.10.21" ]] && ok "tag_prefix=v → 26.10.21" || bad "got=$v"
v=$(derive_version "app/v2.13.0" "app/v" "")
[[ "$v" == "2.13.0" ]] && ok "tag_prefix=app/v → 2.13.0" || bad "got=$v"
v=$(derive_version "0.2.8" "" "")
[[ "$v" == "0.2.8" ]] && ok "无前缀 → 0.2.8" || bad "got=$v"
v=$(derive_version "v154.0.8037.49-4" "" '^v(.+)-([0-9]+)$')
[[ "$v" == $'154.0.8037.49\t4' ]] && ok "regex 双捕获组 → 版本+RELEASE" || bad "got=$(printf %q "$v")"

echo "════ 7. expand_tpl 占位符 ════"
s=$(expand_tpl 'u/${REPO}|${TAG}|${VERSION}|${RELEASE}|${ASSET}|$(PKG_VERSION)' 'o/r' 'v1' '1' 'a.bin' '2')
[[ "$s" == 'u/o/r|v1|1|2|a.bin|1' ]] && ok "全部占位符展开正确" || bad "got=$s"

echo
echo "════ 结果：通过 ${pass} / 失败 ${fail} ════"
[[ $fail -eq 0 ]]
