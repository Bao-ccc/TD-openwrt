#!/usr/bin/env bash
# ============================================================================
#  通知模块：Telegram + WxPusher
#  由 update.sh source 加载，配置全部来自环境变量（留空即跳过该渠道）
#
#    TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID
#    WXPUSHER_APP_TOKEN / WXPUSHER_UIDS / WXPUSHER_TOPIC_IDS
# ============================================================================

TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
WXPUSHER_APP_TOKEN="${WXPUSHER_APP_TOKEN:-}"
WXPUSHER_UIDS="${WXPUSHER_UIDS:-}"
WXPUSHER_TOPIC_IDS="${WXPUSHER_TOPIC_IDS:-}"

# HTML 转义（Telegram parse_mode=HTML 时需要）
html_escape() {
  printf '%s' "$1" \
    | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# ------------------------------ Telegram ------------------------------
send_telegram() {
  local text="$1"
  [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]] && return 0

  curl -sS -X POST \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "parse_mode=HTML" \
    --data-urlencode "text=${text}" \
    >/dev/null 2>&1 || echo "[warn] Telegram 发送失败" >&2
}

# ------------------------------ WxPusher ------------------------------
send_wxpusher() {
  local summary="$1"
  local content="$2"
  [[ -z "$WXPUSHER_APP_TOKEN" ]] && return 0

  local payload
  payload=$(jq -n \
    --arg appToken "$WXPUSHER_APP_TOKEN" \
    --arg content "$content" \
    --arg summary "$summary" \
    --arg uids "$WXPUSHER_UIDS" \
    --arg topics "$WXPUSHER_TOPIC_IDS" \
    '{
       appToken: $appToken,
       content: $content,
       summary: $summary,
       contentType: 2,
       uids:     ($uids   | split(",") | map(select(length > 0))),
       topicIds: ($topics | split(",") | map(select(length > 0)) | map(tonumber? // .))
     }')

  curl -sS -X POST "https://wxpusher.zjiecode.com/api/send/message" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    >/dev/null 2>&1 || echo "[warn] WxPusher 发送失败" >&2
}

# ------------------------------ 统一入口 ------------------------------
# notify <title> <body>
notify() {
  local title="$1"
  local body="$2"

  # Telegram：HTML，标题加粗，正文保持纯文本换行
  local tg_text
  tg_text="<b>$(html_escape "$title")</b>

$(html_escape "$body")"
  send_telegram "$tg_text"

  # WxPusher：HTML，标题 + 等宽正文
  send_wxpusher "$title" "<h3>$(html_escape "$title")</h3><pre>$(html_escape "$body")</pre>"
}
