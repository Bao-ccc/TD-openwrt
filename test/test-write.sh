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

echo "════ 8. 版本比较 ver_cmp / is_newer ════"
tc() { local want="$1" a="$2" b="$3" got
  ver_cmp "$a" "$b"; got=$?
  [[ "$got" == "$want" ]] && ok "ver_cmp $a $b → $got" || bad "ver_cmp $a $b → $got（期望 $want）"; }
tc 0 '1.0.0'  '1.0.0'
tc 1 '1.0.1'  '1.0.0'
tc 2 '1.0.0'  '1.0.1'
tc 1 '26.10.21' '26.9.15'      # 月份 10 > 9（逐段数字比较）
tc 2 '26.9.15'  '26.10.21'
tc 1 '1.14.3'  '1.9.9'         # 14 > 9
ntc() { local want="$1" a="$2" b="$3" got=1
  is_newer "$a" "$b" && got=0
  [[ "$got" == "$want" ]] && ok "is_newer $a $b → $got" || bad "is_newer $a $b → $got（期望 $want）"; }
ntc 0 '2.0.0' '1.9.9'
ntc 1 '1.9.9' '2.0.0'
ntc 1 '2.0.0' '2.0.0'          # 相等不算更新
ntc 0 '2.0.0' ''               # 本地无版本 → 需要更新
ntc 1 ''      '2.0.0'          # 上游无版本 → 不更新

echo "════ 9. 版本闸门 should_skip_sync ════"
sc() { local want="$1" up="$2" loc="$3" gate="$4" got=1
  should_skip_sync "$up" "$loc" "$gate" && got=0
  [[ "$got" == "$want" ]] && ok "up=$up loc=$loc gate=$gate → skip=$got" || bad "→ skip=$got（期望 $want）"; }
sc 0 '1.0.0' '2.0.0' true     # 上游旧 → 忽略
sc 0 '2.0.0' '2.0.0' true     # 相等 → 忽略
sc 1 '2.0.1' '2.0.0' true     # 上游新 → 同步
sc 1 '1.0.0' '2.0.0' false    # 闸门关闭 → 同步
sc 1 ''      '2.0.0' true     # 无版本信息 → 同步
sc 1 '1.0.0' ''      true     # 本地无版本 → 同步

echo "════ 10. 源码闸门（多版本变量） should_skip_source ════"
mk() { printf 'PKG_VERSION:=%s\nGEOIP_VER:=%s\nGEOSITE_VER:=%s\n' "$1" "$2" "$3"; }
VARS=$'PKG_VERSION\nGEOIP_VER\nGEOSITE_VER'
sx() { local want="$1" desc="$2" got=1
  should_skip_source "$T/up.mk" "$T/loc.mk" true "$VARS" && got=0
  [[ "$got" == "$want" ]] && ok "$desc → skip=$got" || bad "$desc → skip=$got（期望 $want）"; }

mk 1.0.0 202601010000 202601010000 > "$T/up.mk";  mk 2.0.0 202601010000 202601010000 > "$T/loc.mk"
sx 0 'PKG_VERSION 上游旧 → 忽略'
mk 3.0.0 202601010000 202601010000 > "$T/up.mk"
sx 1 'PKG_VERSION 上游新 → 同步'
mk 1.0.0 202602020000 202601010000 > "$T/up.mk";  mk 1.0.0 202601010000 202601010000 > "$T/loc.mk"
sx 1 'GEOIP_VER 上游新 → 同步（即使 PKG_VERSION 相同）'
mk 1.0.0 202501010000 202601010000 > "$T/up.mk"
sx 0 'GEOIP_VER 上游旧且其余相同 → 忽略'
mk 1.0.0 202501010000 202501010000 > "$T/up.mk";  mk 1.0.0 202601010000 202601010000 > "$T/loc.mk"
sx 0 '全部变量上游都不更高 → 忽略'
mk 1.0.0 202501010000 202602020000 > "$T/up.mk"
sx 1 'GEOSITE_VER 上游新 → 同步'
# 无任何可比变量（如无 PKG_VERSION 也无 *_VER）
printf 'FOO:=1\n' > "$T/up.mk"; printf 'FOO:=2\n' > "$T/loc.mk"
sx 1 '无可比版本变量 → 保守放行'
# 闸门关闭
mk 1.0.0 202501010000 202501010000 > "$T/up.mk";  mk 2.0.0 202601010000 202601010000 > "$T/loc.mk"
got=1; should_skip_source "$T/up.mk" "$T/loc.mk" false "$VARS" && got=0
[[ "$got" == 1 ]] && ok "skip_if_not_newer=false → 同步" || bad "→ skip=$got"
# 真实文件：v2ray-geodata 上游 vs 抬高的本地
sed 's/^GEOIP_VER:=.*/GEOIP_VER:=209901010000/' v2ray-geodata/Makefile > "$T/loc.mk"
got=1; should_skip_source v2ray-geodata/Makefile "$T/loc.mk" true "$VARS" && got=0
[[ "$got" == 0 ]] && ok "真实 v2ray-geodata：本地 GEOIP_VER 更高 → 忽略" || bad "→ skip=$got"

echo "════ 11. 字面量判定 is_literal_ver（排除 Makefile 派生式） ════"
lv() { local want="$1" v="$2" got=1; is_literal_ver "$v" && got=0
  [[ "$got" == "$want" ]] && ok "is_literal_ver '$v' → $got" || bad "' $v' → $got（期望 $want）"; }
lv 0 '1.2.3'
lv 0 '1.15.0-alpha.12'
lv 0 '2026.10.21'
lv 1 '$(subst -alpha.,_alpha,$(PKG_UPSTREAM_VERSION))'
lv 1 '$(PKG_UPSTREAM_VERSION)'
lv 1 '${VERSION}'
lv 1 ''
# 派生式不应参与比较 → 放行同步
got=1
should_skip_sync '$(subst -alpha.,_alpha,$(PKG_UPSTREAM_VERSION))' '1.14.3' true && got=0
[[ "$got" == 1 ]] && ok "上游是派生式 → 不闸、放行同步" || bad "→ skip=$got"
got=1
should_skip_source <(printf 'PKG_VERSION:=%s\n' '$(subst -a.,_a,$(PKG_UPSTREAM_VERSION))') \
                   <(printf 'PKG_VERSION:=%s\n' '1.14.3') true $'PKG_VERSION' && got=0
[[ "$got" == 1 ]] && ok "源码闸门：派生式不参与比较 → 放行" || bad "→ skip=$got"

echo "════ 12. version_var：只写变量、不碰 \$(subst) 派生式 ════"
cp sing-box/Makefile "$T/s.new"
replace_var_line "$T/s.new" "PKG_UPSTREAM_VERSION" "9.9.9-test"
grep -q '^PKG_UPSTREAM_VERSION:=9.9.9-test$' "$T/s.new" \
  && ok "PKG_UPSTREAM_VERSION 被改写" || bad "PKG_UPSTREAM_VERSION 未改写"
[[ $(grep -c 'PKG_VERSION:=\$(subst' "$T/s.new") -eq 3 ]] \
  && ok "3 条 PKG_VERSION:=\$(subst …) 派生式未被误伤" \
  || bad "派生式被改动：$(grep -c 'PKG_VERSION:=\$(subst' "$T/s.new") 条"
grep -q 'PKG_SOURCE_URL:=.*v\$(PKG_UPSTREAM_VERSION)?' "$T/s.new" \
  && ok "PKG_SOURCE_URL 引用未被误伤" || bad "PKG_SOURCE_URL 被误伤"
# 回环
replace_var_line "$T/s.new" "PKG_UPSTREAM_VERSION" "$(read_var_line sing-box/Makefile PKG_UPSTREAM_VERSION)"
diff -q sing-box/Makefile "$T/s.new" >/dev/null 2>&1 \
  && ok "回环测试：写回原值后逐字节一致" || bad "回环失败：$(diff sing-box/Makefile "$T/s.new" | head -3 | tr '\n' ' ')"

echo
echo "════ 结果：通过 ${pass} / 失败 ${fail} ════"
[[ $fail -eq 0 ]]
