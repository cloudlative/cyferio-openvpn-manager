#!/usr/bin/env bash
# logger.sh — structured logging to $CYFERIO_LOG_DIR/cyferio.log (see
# docs/architecture/07-logging.md). Every module logs through log_info /
# log_warn / log_error — never raw `echo >> file`.

if [[ -n "${__CYFERIO_LOGGER_LOADED:-}" ]]; then
  return 0
fi
__CYFERIO_LOGGER_LOADED=1

_logger_file() {
  echo "${CYFERIO_LOG_DIR}/cyferio.log"
}

# _logger_write LEVEL TAG [key=value ...]
# Falls back to stderr-only (with a one-time notice) if the log directory
# isn't writable — e.g. running unprivileged in dev — rather than failing
# the whole command.
_logger_write() {
  local level="$1" tag="$2"
  shift 2
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local line="${ts} [${level}] [${tag}]"
  if [[ $# -gt 0 ]]; then
    line="${line} $*"
  fi

  local log_file
  log_file="$(_logger_file)"
  local log_dir
  log_dir="$(dirname "${log_file}")"

  if [[ -d "${log_dir}" && -w "${log_dir}" ]] || mkdir -p "${log_dir}" 2>/dev/null; then
    if echo "${line}" >>"${log_file}" 2>/dev/null; then
      return 0
    fi
  fi

  if [[ -z "${__CYFERIO_LOGGER_FALLBACK_WARNED:-}" ]]; then
    __CYFERIO_LOGGER_FALLBACK_WARNED=1
    echo "cyferio-vpn: warning: cannot write to ${log_file}, logging to stderr only" >&2
  fi
  echo "${line}" >&2
}

log_info()  { _logger_write "INFO"  "$1" "${@:2}"; }
log_warn()  { _logger_write "WARN"  "$1" "${@:2}"; }
log_error() { _logger_write "ERROR" "$1" "${@:2}"; }
