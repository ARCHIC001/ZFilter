#!/usr/bin/env bash
set -euo pipefail

# NIKONFILTER 一键安装脚本
# 功能：
# 1) 自动处理可执行权限
# 2) 自动安装软链接到可执行目录
# 3) 自动检查 PATH，并给出修复建议
#
# 默认行为：
# - 安装目标优先使用 /usr/local/bin（如有权限）
# - 无 sudo 或无写权限时，回退到 ~/.local/bin
#
# 用法：
#   bash install.sh
#   bash install.sh --prefix /custom/bin
#   bash install.sh --name nikonfilter
#   bash install.sh --dry-run
#
# 卸载：
#   bash install.sh --uninstall
#
# 说明：
# - 本脚本需与 `nikonfilter` 启动器、`nikonfilter.py` 在同一目录
# - 安装后可在任意目录执行：nikonfilter

APP_NAME_DEFAULT="nikonfilter"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAUNCHER_PATH="${SCRIPT_DIR}/nikonfilter"
PY_APP_PATH="${SCRIPT_DIR}/nikonfilter.py"

APP_NAME="${APP_NAME_DEFAULT}"
CUSTOM_PREFIX=""
DRY_RUN="false"
UNINSTALL="false"

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
CYAN="\033[36m"
RESET="\033[0m"

log_info() {
  printf "${CYAN}[INFO]${RESET} %s\n" "$*"
}

log_ok() {
  printf "${GREEN}[OK]${RESET} %s\n" "$*"
}

log_warn() {
  printf "${YELLOW}[WARN]${RESET} %s\n" "$*"
}

log_err() {
  printf "${RED}[ERROR]${RESET} %s\n" "$*" >&2
}

usage() {
  cat <<EOF
NIKONFILTER 安装脚本

用法:
  bash install.sh [选项]

选项:
  --prefix <dir>     指定安装目录（例如 /usr/local/bin 或 ~/.local/bin）
  --name <name>      指定命令名（默认: nikonfilter）
  --dry-run          演练模式，仅打印操作不执行
  --uninstall        卸载（删除已安装软链接）
  -h, --help         显示帮助

示例:
  bash install.sh
  bash install.sh --prefix ~/.local/bin
  bash install.sh --name nikonfilter-gui
  bash install.sh --dry-run
  bash install.sh --uninstall
EOF
}

contains_path_entry() {
  # 参数1：目录，参数2：PATH 字符串
  local needle="$1"
  local path_value="$2"
  case ":${path_value}:" in
    *":${needle}:"*) return 0 ;;
    *) return 1 ;;
  esac
}

shell_rc_file() {
  # 尽量推断当前 shell 对应 rc 文件
  local shell_name
  shell_name="$(basename "${SHELL:-}")"
  case "${shell_name}" in
    zsh)  echo "${HOME}/.zshrc" ;;
    bash) echo "${HOME}/.bashrc" ;;
    fish) echo "${HOME}/.config/fish/config.fish" ;;
    *)    echo "${HOME}/.profile" ;;
  esac
}

expand_tilde() {
  local p="$1"
  if [[ "${p}" == "~/"* ]]; then
    echo "${HOME}/${p#~/}"
  else
    echo "${p}"
  fi
}

run_cmd() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    printf "  [DRY-RUN] %s\n" "$*"
  else
    eval "$@"
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --prefix)
        [[ $# -ge 2 ]] || { log_err "--prefix 需要参数"; exit 2; }
        CUSTOM_PREFIX="$2"
        shift 2
        ;;
      --name)
        [[ $# -ge 2 ]] || { log_err "--name 需要参数"; exit 2; }
        APP_NAME="$2"
        shift 2
        ;;
      --dry-run)
        DRY_RUN="true"
        shift
        ;;
      --uninstall)
        UNINSTALL="true"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        log_err "未知参数: $1"
        usage
        exit 2
        ;;
    esac
  done
}

validate_files() {
  [[ -f "${LAUNCHER_PATH}" ]] || { log_err "缺少启动器: ${LAUNCHER_PATH}"; exit 1; }
  [[ -f "${PY_APP_PATH}" ]] || { log_err "缺少主程序: ${PY_APP_PATH}"; exit 1; }
}

choose_install_dir() {
  local target=""
  if [[ -n "${CUSTOM_PREFIX}" ]]; then
    target="$(expand_tilde "${CUSTOM_PREFIX}")"
    echo "${target}"
    return 0
  fi

  # 默认优先 /usr/local/bin，其次 ~/.local/bin
  if [[ -d "/usr/local/bin" ]]; then
    if [[ -w "/usr/local/bin" ]]; then
      echo "/usr/local/bin"
      return 0
    fi
    # 不可写也先返回 /usr/local/bin，后续尝试 sudo
    echo "/usr/local/bin"
    return 0
  fi

  echo "${HOME}/.local/bin"
}

ensure_executable_permissions() {
  log_info "设置可执行权限..."
  run_cmd "chmod +x \"${LAUNCHER_PATH}\""
  run_cmd "chmod +x \"${PY_APP_PATH}\""
  log_ok "权限处理完成"
}

install_link() {
  local install_dir="$1"
  local link_path="${install_dir}/${APP_NAME}"

  if [[ "${DRY_RUN}" == "true" ]]; then
    if [[ ! -d "${install_dir}" ]]; then
      printf "  [DRY-RUN] mkdir -p \"%s\"\n" "${install_dir}"
    fi
    printf "  [DRY-RUN] ln -sf \"%s\" \"%s\"\n" "${LAUNCHER_PATH}" "${link_path}"
    return 0
  fi

  if [[ ! -d "${install_dir}" ]]; then
    mkdir -p "${install_dir}"
  fi

  if [[ -w "${install_dir}" ]]; then
    ln -sf "${LAUNCHER_PATH}" "${link_path}"
  else
    if command -v sudo >/dev/null 2>&1; then
      log_warn "${install_dir} 不可写，尝试使用 sudo 安装..."
      sudo mkdir -p "${install_dir}"
      sudo ln -sf "${LAUNCHER_PATH}" "${link_path}"
    else
      log_warn "没有 sudo 权限，回退安装到 ~/.local/bin"
      install_dir="${HOME}/.local/bin"
      mkdir -p "${install_dir}"
      link_path="${install_dir}/${APP_NAME}"
      ln -sf "${LAUNCHER_PATH}" "${link_path}"
    fi
  fi

  log_ok "软链接安装完成: ${link_path}"
}

uninstall_link() {
  local install_dir="$1"
  local link_path="${install_dir}/${APP_NAME}"

  if [[ "${DRY_RUN}" == "true" ]]; then
    printf "  [DRY-RUN] rm -f \"%s\"\n" "${link_path}"
    return 0
  fi

  if [[ -L "${link_path}" || -e "${link_path}" ]]; then
    if [[ -w "${install_dir}" ]]; then
      rm -f "${link_path}"
    else
      if command -v sudo >/dev/null 2>&1; then
        sudo rm -f "${link_path}"
      else
        log_err "无法删除 ${link_path}（无写权限且无 sudo）"
        exit 1
      fi
    fi
    log_ok "已卸载: ${link_path}"
  else
    log_warn "未找到安装项: ${link_path}"
  fi
}

check_path_and_hint() {
  local install_dir="$1"
  local rc_file
  rc_file="$(shell_rc_file)"

  if contains_path_entry "${install_dir}" "${PATH}"; then
    log_ok "PATH 已包含: ${install_dir}"
    return 0
  fi

  log_warn "PATH 未包含安装目录: ${install_dir}"
  log_info "你可以把以下内容加入 ${rc_file}："
  echo ""
  if [[ "$(basename "${rc_file}")" == "config.fish" ]]; then
    echo "  set -gx PATH \"${install_dir}\" \$PATH"
  else
    echo "  export PATH=\"${install_dir}:\$PATH\""
  fi
  echo ""

  log_info "添加后请重新加载 shell 配置，例如："
  case "$(basename "${rc_file}")" in
    .zshrc)  echo "  source ~/.zshrc" ;;
    .bashrc) echo "  source ~/.bashrc" ;;
    .profile) echo "  source ~/.profile" ;;
    config.fish) echo "  source ~/.config/fish/config.fish" ;;
    *) echo "  source \"${rc_file}\"" ;;
  esac
}

verify_command() {
  local expect_link="$1"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "演练模式下跳过命令验证"
    return 0
  fi

  if command -v "${APP_NAME}" >/dev/null 2>&1; then
    local resolved
    resolved="$(command -v "${APP_NAME}")"
    log_ok "命令可用: ${APP_NAME} -> ${resolved}"
  else
    log_warn "当前 shell 还找不到命令 ${APP_NAME}"
    log_warn "通常是 PATH 尚未生效，重新打开终端或 source 配置后再试。"
  fi

  log_info "你现在可以运行："
  echo "  ${APP_NAME}"
  echo ""
  log_info "如果需要，直接调用安装路径："
  echo "  ${expect_link}"
}

main() {
  parse_args "$@"
  validate_files

  local install_dir
  install_dir="$(choose_install_dir)"
  install_dir="$(expand_tilde "${install_dir}")"

  log_info "项目目录: ${SCRIPT_DIR}"
  log_info "安装命令名: ${APP_NAME}"
  log_info "安装目录: ${install_dir}"
  [[ "${DRY_RUN}" == "true" ]] && log_warn "当前为 DRY-RUN 演练模式，不会改动系统"

  ensure_executable_permissions

  if [[ "${UNINSTALL}" == "true" ]]; then
    uninstall_link "${install_dir}"
    exit 0
  fi

  install_link "${install_dir}"
  check_path_and_hint "${install_dir}"

  local installed_path="${install_dir}/${APP_NAME}"
  verify_command "${installed_path}"

  log_ok "安装流程结束。"
}

main "$@"
