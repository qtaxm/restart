#!/usr/bin/env bash
set -euo pipefail

DEFAULT_CODEX_BASE_URL="${DEFAULT_CODEX_BASE_URL:-https://api.apikey.fun/v1}"
DEFAULT_CODEX_MODEL="${DEFAULT_CODEX_MODEL:-gpt-5.5}"
ENV_CODEX_BASE_URL="${CODEX_BASE_URL:-}"
ENV_CODEX_API_KEY="${CODEX_API_KEY:-${OPENAI_API_KEY:-}}"
ENV_CODEX_MODEL="${CODEX_MODEL:-}"
ENV_CODEX_REVIEW_MODEL="${CODEX_REVIEW_MODEL:-}"

CODEX_BASE_URL=""
CODEX_MODEL="$DEFAULT_CODEX_MODEL"
CODEX_REVIEW_MODEL="$DEFAULT_CODEX_MODEL"
CODEX_PKG="${CODEX_PKG:-@openai/codex}"
MIN_NODE_MAJOR="${MIN_NODE_MAJOR:-22}"
INSTALL_NODE_VERSION="${INSTALL_NODE_VERSION:-lts/*}"
NVM_INSTALL_URL="${NVM_INSTALL_URL:-https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh}"
TARGET_USER="${SUDO_USER:-$(id -un)}"
TARGET_HOME="$HOME"
TARGET_SHELL="${SHELL:-/bin/bash}"

if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
  if command -v getent >/dev/null 2>&1; then
    TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
    TARGET_SHELL="$(getent passwd "$TARGET_USER" | cut -d: -f7)"
  else
    TARGET_HOME="$(eval "printf '%s' ~$TARGET_USER")"
  fi
fi

[ -n "$TARGET_HOME" ] || TARGET_HOME="$HOME"
[ -n "$TARGET_SHELL" ] || TARGET_SHELL="/bin/bash"

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

toml_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

attach_terminal_stdin() {
  if [ -r /dev/tty ]; then
    exec </dev/tty
  fi
}

target_group() {
  id -gn "$TARGET_USER" 2>/dev/null || printf '%s' "$TARGET_USER"
}

fix_target_ownership() {
  if [ "$(id -u)" -eq 0 ] && [ "$TARGET_USER" != "root" ]; then
    chown -R "$TARGET_USER:$(target_group)" "$@" 2>/dev/null || true
  fi
}

shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

run_target_bash() {
  local script="$1"
  if [ "$(id -u)" -eq 0 ] && [ "$TARGET_USER" != "root" ] && command -v sudo >/dev/null 2>&1; then
    sudo -H -u "$TARGET_USER" env HOME="$TARGET_HOME" bash -lc "$script"
  else
    HOME="$TARGET_HOME" bash -lc "$script"
  fi
}

target_env_args() {
  printf 'HOME=%s\0' "$TARGET_HOME"
}

target_login_shell_path() {
  if [ "$(id -u)" -eq 0 ] && [ "$TARGET_USER" != "root" ] && command -v sudo >/dev/null 2>&1; then
    sudo -H -u "$TARGET_USER" env HOME="$TARGET_HOME" "$TARGET_SHELL" -lc 'printf "%s" "$PATH"' 2>/dev/null || true
    return
  fi
  HOME="$TARGET_HOME" "$TARGET_SHELL" -lc 'printf "%s" "$PATH"' 2>/dev/null || true
}

prepend_path() {
  local dir="$1"
  [ -n "$dir" ] || return
  case ":$PATH:" in
    *":$dir:"*) ;;
    *) PATH="$dir:$PATH" ;;
  esac
}

load_target_user_path() {
  local login_path npm_prefix
  login_path="$(target_login_shell_path || true)"
  if [ -n "$login_path" ]; then
    PATH="$login_path:$PATH"
  fi

  prepend_path "$TARGET_HOME/.local/bin"
  prepend_path "$TARGET_HOME/.n/bin"
  prepend_path "$TARGET_HOME/.npm-global/bin"
  prepend_path "$TARGET_HOME/.yarn/bin"
  prepend_path "$TARGET_HOME/.config/yarn/global/node_modules/.bin"

  if command -v npm >/dev/null 2>&1; then
    npm_prefix="$(npm config get prefix 2>/dev/null || true)"
    if [ -n "$npm_prefix" ] && [ "$npm_prefix" != "undefined" ]; then
      prepend_path "$npm_prefix/bin"
    fi
  fi
  export PATH
}

target_path_bootstrap() {
  printf '%s' 'export PATH="$HOME/.local/bin:$HOME/.n/bin:$HOME/.npm-global/bin:$HOME/.yarn/bin:$HOME/.config/yarn/global/node_modules/.bin:$PATH"; export NVM_DIR="$HOME/.nvm"; [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"; command -v nvm >/dev/null 2>&1 && nvm use --silent default >/dev/null 2>&1 || true; if command -v npm >/dev/null 2>&1; then npm_prefix="$(npm config get prefix 2>/dev/null || true)"; [ -n "$npm_prefix" ] && [ "$npm_prefix" != "undefined" ] && export PATH="$npm_prefix/bin:$PATH"; fi'
}

exec_target_command() {
  local command_name="$1"
  attach_terminal_stdin
  if [ "$(id -u)" -eq 0 ] && [ "$TARGET_USER" != "root" ] && command -v sudo >/dev/null 2>&1; then
    local env_args=()
    while IFS= read -r -d '' item; do
      env_args+=("$item")
    done < <(target_env_args)
    exec sudo -H -u "$TARGET_USER" env "${env_args[@]}" bash -lc "$(target_path_bootstrap); exec $(shell_quote "$command_name")"
  fi

  load_target_node_env
  if command -v "$command_name" >/dev/null 2>&1; then
    exec "$command_name"
  fi
  return 1
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

confirm_yes() {
  local prompt="$1"
  local default_yes="${2:-no}"
  local answer
  read_input answer "$prompt"
  if [ -z "$answer" ]; then
    [ "$default_yes" = "yes" ]
    return
  fi
  case "$answer" in
    y|Y|yes|YES|Yes) return 0 ;;
    *) return 1 ;;
  esac
}

detect_shell_rc() {
  case "${TARGET_SHELL##*/}" in
    zsh)
      printf '%s/.zshrc' "$TARGET_HOME"
      return
      ;;
    bash)
      printf '%s/.bashrc' "$TARGET_HOME"
      return
      ;;
  esac
  if [ -n "${ZSH_VERSION:-}" ]; then
    printf '%s/.zshrc' "$TARGET_HOME"
    return
  fi
  if [ -n "${BASH_VERSION:-}" ]; then
    printf '%s/.bashrc' "$TARGET_HOME"
    return
  fi
  case "$(uname -s 2>/dev/null || true)" in
    Darwin) printf '%s/.zshrc' "$TARGET_HOME" ;;
    *) printf '%s/.profile' "$TARGET_HOME" ;;
  esac
}

load_target_node_env() {
  load_target_user_path
  export NVM_DIR="$TARGET_HOME/.nvm"
  if [ -s "$NVM_DIR/nvm.sh" ]; then
    # shellcheck disable=SC1091
    . "$NVM_DIR/nvm.sh"
    command -v nvm >/dev/null 2>&1 && nvm use --silent default >/dev/null 2>&1 || true
  fi
  load_target_user_path
}

current_node_version() {
  load_target_node_env
  if command -v node >/dev/null 2>&1; then
    node -v 2>/dev/null
    return
  fi
  if [ "$(id -u)" -eq 0 ] && [ "$TARGET_USER" != "root" ]; then
    run_target_bash "$(target_path_bootstrap); command -v node >/dev/null 2>&1 && node -v" 2>/dev/null || true
  fi
}

current_node_major() {
  local version
  version="$(current_node_version || true)"
  if [ -n "$version" ]; then
    printf '%s\n' "$version" | sed 's/^v//' | cut -d. -f1
  fi
}

ensure_nvm_loaded() {
  export NVM_DIR="$TARGET_HOME/.nvm"
  if [ -s "$NVM_DIR/nvm.sh" ]; then
    # shellcheck disable=SC1091
    . "$NVM_DIR/nvm.sh"
    command -v nvm >/dev/null 2>&1 && nvm use --silent default >/dev/null 2>&1 || true
  fi
}

ensure_nvm_init_in_rc() {
  local rc_file="$1"
  local marker="# >>> Custom Codex nvm init >>>"
  if grep -qF "$marker" "$rc_file" 2>/dev/null; then
    return
  fi
  cat >> "$rc_file" <<'EOF'

# >>> Custom Codex nvm init >>>
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/nvm.sh" ] && nvm use --silent default >/dev/null 2>&1 || true
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
# <<< Custom Codex nvm init <<<
EOF
  fix_target_ownership "$rc_file"
}

auto_install_node_via_nvm() {
  local rc_file="$1"
  if ! command -v curl >/dev/null 2>&1; then
    say "未找到 curl，无法自动安装 nvm。请先安装 Node.js $MIN_NODE_MAJOR+ 后重试。"
    exit 1
  fi

  if [ "$(id -u)" -eq 0 ] && [ "$TARGET_USER" != "root" ]; then
    say "正在为 $TARGET_USER 安装 nvm..."
    run_target_bash "set -e; export NVM_DIR=\"\$HOME/.nvm\"; if [ ! -s \"\$NVM_DIR/nvm.sh\" ]; then curl -fsSL $(shell_quote "$NVM_INSTALL_URL") | bash; fi; . \"\$NVM_DIR/nvm.sh\"; nvm install $(shell_quote "$INSTALL_NODE_VERSION"); nvm alias default $(shell_quote "$INSTALL_NODE_VERSION"); nvm use default"
    ensure_nvm_loaded
    ensure_nvm_init_in_rc "$rc_file"
    return
  fi

  export NVM_DIR="$TARGET_HOME/.nvm"
  if [ ! -s "$NVM_DIR/nvm.sh" ]; then
    say "正在安装 nvm..."
    curl -fsSL "$NVM_INSTALL_URL" | bash
  fi
  ensure_nvm_loaded
  if ! command -v nvm >/dev/null 2>&1; then
    say "nvm 加载失败，请重开终端后重试，或手动安装 Node.js $MIN_NODE_MAJOR+。"
    exit 1
  fi

  say "正在安装稳定版 Node.js LTS..."
  nvm install "$INSTALL_NODE_VERSION"
  nvm alias default "$INSTALL_NODE_VERSION"
  nvm use default
  ensure_nvm_init_in_rc "$rc_file"
}

ensure_node() {
  local rc_file="$1"
  local major
  local version
  major="$(current_node_major || true)"
  if [ -n "$major" ] && [ "$major" -ge "$MIN_NODE_MAJOR" ]; then
    version="$(current_node_version || true)"
    say "Node.js 已满足要求：$version"
    return
  fi

  if [ -z "$major" ]; then
    say "未检测到 Node.js。"
  else
    version="$(current_node_version || true)"
    say "当前 Node.js 版本 $version 低于 v$MIN_NODE_MAJOR。"
  fi

  if confirm_yes "是否自动通过 nvm 安装稳定版 Node.js LTS？[Y/n]: " "yes"; then
    auto_install_node_via_nvm "$rc_file"
  else
    say "Codex 需要 Node.js $MIN_NODE_MAJOR+。请先安装后重新运行本脚本。"
    exit 1
  fi
}

npm_install_global() {
  local package_name="$1"
  load_target_node_env
  local npm_path
  npm_path="$(command -v npm 2>/dev/null || true)"
  if [ -z "$npm_path" ]; then
    say "未找到 npm，请先安装 Node.js，再执行：npm install -g $package_name"
    exit 1
  fi
  if [ "$(id -u)" -eq 0 ] && [ "$TARGET_USER" != "root" ] && case "$npm_path" in "$TARGET_HOME"/*) true ;; *) false ;; esac; then
    run_target_bash "$(target_path_bootstrap); npm install -g $(shell_quote "$package_name")"
  else
    npm install -g "$package_name"
  fi
}

target_command_info() {
  local command_name="$1"
  load_target_node_env
  if command -v "$command_name" >/dev/null 2>&1; then
    "$command_name" --version 2>/dev/null || command -v "$command_name"
    return
  fi
  if [ "$(id -u)" -eq 0 ] && [ "$TARGET_USER" != "root" ]; then
    run_target_bash "$(target_path_bootstrap); if command -v $(shell_quote "$command_name") >/dev/null 2>&1; then $(shell_quote "$command_name") --version 2>/dev/null || command -v $(shell_quote "$command_name"); fi" 2>/dev/null || true
  fi
}

ensure_codex() {
  local rc_file="$1"
  local installed
  installed="$(target_command_info codex || true)"
  if [ -n "$installed" ]; then
    say "Codex 已安装：$installed"
    return
  fi

  say "当前 Node.js 环境未检测到 Codex CLI。"
  if ! confirm_yes "是否使用 npm 安装 Codex？[Y/n]: " "yes"; then
    say "已跳过安装。请先安装 Codex 后再运行：codex"
    return
  fi

  ensure_node "$rc_file"
  npm_install_global "$CODEX_PKG"
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
  local api_key="$1"
  mkdir -p "$CODEX_HOME"
  fix_target_ownership "$CODEX_HOME"
  backup_if_exists "$AUTH_FILE"
  local escaped_key
  escaped_key=$(printf "%s" "$api_key" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
  printf '{\n  "OPENAI_API_KEY": "%s"\n}\n' "$escaped_key" > "$AUTH_FILE"
  chmod 600 "$AUTH_FILE" 2>/dev/null || true
  fix_target_ownership "$AUTH_FILE"
}

configure_base_url() {
  local input
  if [ -n "$ENV_CODEX_BASE_URL" ]; then
    input="$ENV_CODEX_BASE_URL"
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

configure_models() {
  local input
  if [ -n "$ENV_CODEX_MODEL" ]; then
    CODEX_MODEL="$(trim "$ENV_CODEX_MODEL")"
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

  if [ -n "$ENV_CODEX_REVIEW_MODEL" ]; then
    CODEX_REVIEW_MODEL="$(trim "$ENV_CODEX_REVIEW_MODEL")"
    say "已从环境变量 CODEX_REVIEW_MODEL 读取 review 模型名：$CODEX_REVIEW_MODEL"
  else
    CODEX_REVIEW_MODEL="$CODEX_MODEL"
  fi
}

configure_api_key() {
  local api_key
  if [ -n "$ENV_CODEX_API_KEY" ]; then
    api_key="$ENV_CODEX_API_KEY"
    say "已从环境变量 CODEX_API_KEY/OPENAI_API_KEY 读取 API Key。"
  else
    read_secret api_key "请输入 API Key: "
  fi

  if [ -z "$api_key" ]; then
    say "API Key 不能为空。"
    exit 1
  fi

  write_auth "$api_key"
}

main() {
  say "Custom Codex 交互式配置"
  say ""
  say "脚本会写入 ~/.codex/config.toml 与 ~/.codex/auth.json。"
  say "可通过环境变量 CODEX_BASE_URL、CODEX_API_KEY、CODEX_MODEL 跳过对应输入。"
  say ""

  configure_base_url
  configure_models
  say ""
  say "当前配置："
  say "  - 接口地址：$CODEX_BASE_URL"
  say "  - 模型：$CODEX_MODEL"
  say ""

  say "请选择要在哪个 Codex 客户端中使用："
  say "1) Codex CLI"
  say "2) Codex 桌面版 App"
  say "直接回车：Codex CLI 和 Codex 桌面版 App 都使用"
  local usage_target
  read_input usage_target "请输入序列号 [直接回车=全部]: "
  case "$usage_target" in
    ""|1|2) ;;
    *)
      say "无效选择：$usage_target"
      exit 1
      ;;
  esac
  say ""

  local rc_file
  rc_file="$(detect_shell_rc)"

  write_config
  configure_api_key

  say ""
  say "Codex 配置已写入："
  say "  - $CONFIG_FILE"
  say "  - $AUTH_FILE"

  if [ "$usage_target" = "2" ]; then
    say "配置已写入，现在彻底退出 Codex App，并重新启动 Codex App 即可生效！"
    return
  fi

  ensure_codex "$rc_file"

  if confirm_yes "是否立即启动 Codex？[y/N]: "; then
    exec_target_command codex || true
    say "未找到 codex 命令，请安装后手动运行：codex"
  else
    say "已跳过启动。请运行：codex"
  fi
  say "现在 Codex CLI 和 App 均已生效！"
}

main "$@"
