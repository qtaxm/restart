#!/usr/bin/env bash
set -euo pipefail

DEFAULT_CODEX_BASE_URL="${DEFAULT_CODEX_BASE_URL:-https://api.apikey.fun/v1}"
DEFAULT_CODEX_MODEL="${DEFAULT_CODEX_MODEL:-gpt-5.5}"

CODEX_BASE_URL="${CODEX_BASE_URL:-}"
CODEX_API_KEY="${CODEX_API_KEY:-${OPENAI_API_KEY:-}}"
ENV_CODEX_MODEL="${CODEX_MODEL:-}"
ENV_CODEX_REVIEW_MODEL="${CODEX_REVIEW_MODEL:-}"
CODEX_MODEL="${ENV_CODEX_MODEL:-$DEFAULT_CODEX_MODEL}"
CODEX_REVIEW_MODEL="$ENV_CODEX_REVIEW_MODEL"
TARGET_USER="${SUDO_USER:-$(id -un)}"
TARGET_HOME="$HOME"

resolve_user_home() {
  local user="$1"
  local resolved_home=""

  if command -v getent >/dev/null 2>&1; then
    resolved_home="$(getent passwd "$user" | cut -d: -f6)"
  elif command -v dscl >/dev/null 2>&1; then
    resolved_home="$(dscl . -read "/Users/$user" NFSHomeDirectory 2>/dev/null | sed 's/^NFSHomeDirectory:[[:space:]]*//')"
  fi

  if [ -n "$resolved_home" ]; then
    printf '%s' "$resolved_home"
  else
    eval "printf '%s' ~$user"
  fi
}

if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
  TARGET_HOME="$(resolve_user_home "$TARGET_USER")"
fi

[ -n "$TARGET_HOME" ] || TARGET_HOME="$HOME"

CODEX_HOME="$TARGET_HOME/.codex"
CONFIG_FILE="$CODEX_HOME/config.toml"
AUTH_FILE="$CODEX_HOME/auth.json"

if ! { exec 3</dev/tty; } 2>/dev/null; then
  exec 3<&0
fi

say() {
  printf '%s\n' "$*"
}

trim() {
  printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

normalize_base_url() {
  local value
  value="$(trim "$1")"
  while [ "${value%/}" != "$value" ]; do
    value="${value%/}"
  done
  printf '%s' "$value"
}

validate_base_url() {
  case "$1" in
    http://*|https://*) return 0 ;;
    *)
      say "接口地址必须以 http:// 或 https:// 开头。"
      exit 1
      ;;
  esac
}

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

toml_escape() {
  json_escape "$1"
}

target_group() {
  id -gn "$TARGET_USER" 2>/dev/null || printf '%s' "$TARGET_USER"
}

fix_target_ownership() {
  if [ "$(id -u)" -eq 0 ] && [ "$TARGET_USER" != "root" ]; then
    chown -R "$TARGET_USER:$(target_group)" "$@" 2>/dev/null || true
  fi
}

read_input() {
  local var_name="$1"
  local prompt="$2"
  read -r -u 3 -p "$prompt" "$var_name"
}

read_secret() {
  local var_name="$1"
  local prompt="$2"
  if [ -t 3 ]; then
    read -r -s -u 3 -p "$prompt" "$var_name"
    printf '\n' >/dev/tty 2>/dev/null || printf '\n'
  else
    read_input "$var_name" "$prompt"
  fi
}

backup_if_exists() {
  local file="$1"
  if [ -f "$file" ]; then
    local stamp
    stamp="$(date +%Y%m%d%H%M%S)"
    cp "$file" "$file.bak.$stamp"
    fix_target_ownership "$file.bak.$stamp"
    say "已备份现有文件：$file.bak.$stamp"
  fi
}

configure_base_url() {
  local input
  if [ -n "$CODEX_BASE_URL" ]; then
    input="$CODEX_BASE_URL"
    say "已从环境变量 CODEX_BASE_URL 读取接口地址。"
  else
    read_input input "请输入自定义接口地址 [默认: $DEFAULT_CODEX_BASE_URL]: "
    if [ -z "$input" ]; then
      input="$DEFAULT_CODEX_BASE_URL"
    fi
  fi

  CODEX_BASE_URL="$(normalize_base_url "$input")"
  if [ -z "$CODEX_BASE_URL" ]; then
    say "接口地址不能为空。"
    exit 1
  fi
  validate_base_url "$CODEX_BASE_URL"
}

configure_model() {
  local input
  if [ -n "$ENV_CODEX_MODEL" ]; then
    say "已从环境变量 CODEX_MODEL 读取模型名：$CODEX_MODEL"
  else
    read_input input "请输入模型名 [默认: $DEFAULT_CODEX_MODEL]: "
    if [ -n "$input" ]; then
      CODEX_MODEL="$(trim "$input")"
    fi
  fi

  if [ -z "$CODEX_MODEL" ]; then
    say "模型名不能为空。"
    exit 1
  fi

  if [ -z "${CODEX_REVIEW_MODEL:-}" ]; then
    CODEX_REVIEW_MODEL="$CODEX_MODEL"
  fi
}

configure_api_key() {
  if [ -n "$CODEX_API_KEY" ]; then
    say "已从环境变量 CODEX_API_KEY/OPENAI_API_KEY 读取 API Key。"
    return
  fi

  read_secret CODEX_API_KEY "请输入 API Key: "
  if [ -z "$CODEX_API_KEY" ]; then
    say "API Key 不能为空。"
    exit 1
  fi
}

write_config() {
  local base_url_escaped model_escaped review_model_escaped
  base_url_escaped="$(toml_escape "$CODEX_BASE_URL")"
  model_escaped="$(toml_escape "$CODEX_MODEL")"
  review_model_escaped="$(toml_escape "$CODEX_REVIEW_MODEL")"

  mkdir -p "$CODEX_HOME"
  fix_target_ownership "$CODEX_HOME"
  backup_if_exists "$CONFIG_FILE"
  cat > "$CONFIG_FILE" <<EOF
model_provider = "codex"
model = "$model_escaped"
review_model = "$review_model_escaped"
model_reasoning_effort = "high"
disable_response_storage = true
network_access = "enabled"
windows_wsl_setup_acknowledged = true
model_context_window = 270000
model_auto_compact_token_limit = 270000
effective_context_window_percent = 95

[model_providers.codex]
name = "codex"
base_url = "$base_url_escaped"
wire_api = "responses"
requires_openai_auth = true
EOF
  fix_target_ownership "$CONFIG_FILE"
}

write_auth() {
  local escaped_key
  escaped_key="$(json_escape "$CODEX_API_KEY")"

  mkdir -p "$CODEX_HOME"
  fix_target_ownership "$CODEX_HOME"
  backup_if_exists "$AUTH_FILE"
  printf '{\n  "OPENAI_API_KEY": "%s"\n}\n' "$escaped_key" > "$AUTH_FILE"
  chmod 600 "$AUTH_FILE" 2>/dev/null || true
  fix_target_ownership "$AUTH_FILE"
}

main() {
  say "Custom Codex 配置写入脚本"
  say ""
  say "只修改配置文件，不安装 Node.js，不安装或启动 Codex。"
  say "将写入："
  say "  - $CONFIG_FILE"
  say "  - $AUTH_FILE"
  say ""

  configure_base_url
  configure_model
  configure_api_key
  write_config
  write_auth

  say ""
  say "Codex 配置已写入完成："
  say "  - 接口地址：$CODEX_BASE_URL"
  say "  - 模型：$CODEX_MODEL"
  say ""
  say "如果是 Codex App，请彻底退出并重新启动后生效。"
}

main "$@"
