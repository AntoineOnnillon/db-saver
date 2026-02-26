#!/usr/bin/env bash
set -euo pipefail

log() {
  local level="$1"
  shift
  local stack_prefix=""
  if [[ -n "${STACK_NAME:-}" ]]; then
    stack_prefix="[${STACK_NAME}] "
  fi
  printf '%s [%s] %s%s\n' "$(date -Iseconds)" "$level" "$stack_prefix" "$*"
}

die() {
  log "ERROR" "$*"
  exit 1
}

sql_escape_literal() {
  printf '%s' "$1" | sed "s/'/''/g"
}

pg_escape_identifier() {
  printf '%s' "$1" | sed 's/"/""/g'
}

DB_TYPE="${DB_TYPE:-}"
DB_NAME="${DB_NAME:-}"
DB_USER="${DB_USER:-}"
DB_PASSWORD="${DB_PASSWORD:-}"
BACKUP_DIR="${BACKUP_DIR:-/backups}"
STACK_NAME="${STACK_NAME:-}"
BACKUP_BASENAME="${BACKUP_BASENAME:-latest}"
WAIT_TIMEOUT_SEC="${WAIT_TIMEOUT_SEC:-120}"
RESTORE_IF_EMPTY="${RESTORE_IF_EMPTY:-1}"
EMPTY_CHECK_MODE="${EMPTY_CHECK_MODE:-tables_count}"
SENTINEL_TABLE="${SENTINEL_TABLE:-}"
TRIGGER_MODE="${TRIGGER_MODE:-1}"
TRIGGER_POLL_SEC="${TRIGGER_POLL_SEC:-2}"
TRIGGER_MARKER_FILE="${TRIGGER_MARKER_FILE:-.db-saver}"
TRIGGER_REQUEST_FILE="${TRIGGER_REQUEST_FILE:-.backup_request}"
TRIGGER_DONE_FILE="${TRIGGER_DONE_FILE:-.backup_done}"
TRIGGER_ERROR_FILE="${TRIGGER_ERROR_FILE:-.backup_error}"
TRIGGER_LOCK_FILE="${TRIGGER_LOCK_FILE:-.backup_lock}"
TRIGGER_LOCK_TIMEOUT_SEC="${TRIGGER_LOCK_TIMEOUT_SEC:-300}"
HEALTH_STATE_DIR="${HEALTH_STATE_DIR:-/tmp/db-saver-state}"
HEALTH_READY_FILE="${HEALTH_READY_FILE:-${HEALTH_STATE_DIR}/startup-ready}"
HEALTHCHECK_REQUIRE_DB="${HEALTHCHECK_REQUIRE_DB:-1}"

case "$DB_TYPE" in
  mysql | mariadb)
    DB_HOST="${DB_HOST:-mysql}"
    DB_PORT="${DB_PORT:-3306}"
    ;;
  postgres)
    DB_HOST="${DB_HOST:-postgres}"
    DB_PORT="${DB_PORT:-5432}"
    ;;
  "")
    die "DB_TYPE is required (mysql|mariadb|postgres)."
    ;;
  *)
    die "Unsupported DB_TYPE: ${DB_TYPE}."
    ;;
esac

[[ -n "$DB_NAME" ]] || die "DB_NAME is required."
[[ -n "$DB_PASSWORD" ]] || die "DB_PASSWORD is required."
if [[ "$DB_TYPE" == "postgres" && -z "$DB_USER" ]]; then
  die "DB_USER is required for PostgreSQL."
fi
if [[ "$RESTORE_IF_EMPTY" != "0" && "$RESTORE_IF_EMPTY" != "1" ]]; then
  die "RESTORE_IF_EMPTY must be 0 or 1."
fi
if [[ "$EMPTY_CHECK_MODE" != "tables_count" && "$EMPTY_CHECK_MODE" != "sentinel_table" ]]; then
  die "EMPTY_CHECK_MODE must be tables_count or sentinel_table."
fi
if [[ "$EMPTY_CHECK_MODE" == "sentinel_table" && -z "$SENTINEL_TABLE" ]]; then
  die "SENTINEL_TABLE is required when EMPTY_CHECK_MODE=sentinel_table."
fi
if ! [[ "$WAIT_TIMEOUT_SEC" =~ ^[0-9]+$ ]]; then
  die "WAIT_TIMEOUT_SEC must be an integer number of seconds."
fi
if [[ "$TRIGGER_MODE" != "0" && "$TRIGGER_MODE" != "1" ]]; then
  die "TRIGGER_MODE must be 0 or 1."
fi
if ! [[ "$TRIGGER_POLL_SEC" =~ ^[0-9]+$ ]] || [[ "$TRIGGER_POLL_SEC" == "0" ]]; then
  die "TRIGGER_POLL_SEC must be a positive integer number of seconds."
fi
if ! [[ "$TRIGGER_LOCK_TIMEOUT_SEC" =~ ^[0-9]+$ ]] || [[ "$TRIGGER_LOCK_TIMEOUT_SEC" == "0" ]]; then
  die "TRIGGER_LOCK_TIMEOUT_SEC must be a positive integer number of seconds."
fi
if [[ "$HEALTHCHECK_REQUIRE_DB" != "0" && "$HEALTHCHECK_REQUIRE_DB" != "1" ]]; then
  die "HEALTHCHECK_REQUIRE_DB must be 0 or 1."
fi

BACKUP_SQL_PATH="${BACKUP_DIR}/${BACKUP_BASENAME}.sql"
BACKUP_DUMP_PATH="${BACKUP_DIR}/${BACKUP_BASENAME}.dump"
BACKUP_GLOBALS_PATH="${BACKUP_DIR}/globals.sql"
RESTORE_MARKER_PATH="${BACKUP_DIR}/.restored"
TRIGGER_MARKER_PATH="${BACKUP_DIR}/${TRIGGER_MARKER_FILE}"
TRIGGER_REQUEST_PATH="${BACKUP_DIR}/${TRIGGER_REQUEST_FILE}"
TRIGGER_DONE_PATH="${BACKUP_DIR}/${TRIGGER_DONE_FILE}"
TRIGGER_ERROR_PATH="${BACKUP_DIR}/${TRIGGER_ERROR_FILE}"
TRIGGER_LOCK_PATH="${BACKUP_DIR}/${TRIGGER_LOCK_FILE}"
STARTUP_RESTORE_STATUS="not_run"

MYSQL_BIN=""
MYSQL_DUMP_BIN=""
if [[ "$DB_TYPE" == "mysql" || "$DB_TYPE" == "mariadb" ]]; then
  MYSQL_BIN="$(command -v mysql || true)"
  MYSQL_DUMP_BIN="$(command -v mysqldump || true)"
  if [[ -z "$MYSQL_DUMP_BIN" ]]; then
    MYSQL_DUMP_BIN="$(command -v mariadb-dump || true)"
  fi
  [[ -n "$MYSQL_BIN" ]] || die "mysql client not found in image."
  [[ -n "$MYSQL_DUMP_BIN" ]] || die "mysqldump/mariadb-dump not found in image."
fi

if [[ "$DB_TYPE" == "postgres" ]]; then
  command -v psql >/dev/null || die "psql client not found in image."
  command -v pg_dump >/dev/null || die "pg_dump client not found in image."
  command -v pg_restore >/dev/null || die "pg_restore client not found in image."
fi

ensure_backup_dir() {
  mkdir -p "$BACKUP_DIR"
}

ensure_health_state_dir() {
  mkdir -p "$HEALTH_STATE_DIR"
}

clear_startup_ready_state() {
  rm -f "$HEALTH_READY_FILE"
}

write_startup_ready_state() {
  local restore_status="$1"
  ensure_health_state_dir
  atomic_write_content "$HEALTH_READY_FILE" "$(printf 'ready=1\nrestore_status=%s\nupdated_at=%s\n' "$restore_status" "$(date -Iseconds)")"
}

is_startup_ready() {
  [[ -s "$HEALTH_READY_FILE" ]]
}

atomic_write_content() {
  local path="$1"
  local content="$2"
  local tmp_path="${path}.tmp.$$"
  printf '%s' "$content" >"$tmp_path"
  mv "$tmp_path" "$path"
}

read_first_line() {
  local path="$1"
  local line=""
  if [[ -f "$path" ]]; then
    IFS= read -r line <"$path" || true
  fi
  line="${line%$'\r'}"
  printf '%s' "$line"
}

write_trigger_done() {
  local request_id="$1"
  atomic_write_content "$TRIGGER_DONE_PATH" "$(printf '%s\n' "$request_id")"
}

write_trigger_error() {
  local request_id="$1"
  local message="$2"
  atomic_write_content "$TRIGGER_ERROR_PATH" "$(printf '%s\n%s\n' "$request_id" "$message")"
}

acquire_trigger_lock() {
  local request_id="$1"
  local now_ts
  now_ts="$(date +%s)"

  if ( set -o noclobber; printf '%s\n%s\n' "$request_id" "$now_ts" >"$TRIGGER_LOCK_PATH" ) 2>/dev/null; then
    return 0
  fi

  if [[ ! -f "$TRIGGER_LOCK_PATH" ]]; then
    return 1
  fi

  local existing_id
  local existing_ts
  existing_id="$(sed -n '1p' "$TRIGGER_LOCK_PATH" 2>/dev/null | tr -d '\r' || true)"
  existing_ts="$(sed -n '2p' "$TRIGGER_LOCK_PATH" 2>/dev/null | tr -d '\r' || true)"

  if [[ "$existing_id" == "$request_id" ]]; then
    log "INFO" "Request ${request_id} is already being processed (lock present)."
    return 1
  fi

  if [[ ! "$existing_ts" =~ ^[0-9]+$ ]] || (( now_ts - existing_ts > TRIGGER_LOCK_TIMEOUT_SEC )); then
    log "WARN" "Stale trigger lock detected for request ${existing_id:-unknown}; removing lock."
    rm -f "$TRIGGER_LOCK_PATH"
    if ( set -o noclobber; printf '%s\n%s\n' "$request_id" "$now_ts" >"$TRIGGER_LOCK_PATH" ) 2>/dev/null; then
      return 0
    fi
  fi

  return 1
}

release_trigger_lock() {
  local request_id="$1"
  if [[ ! -f "$TRIGGER_LOCK_PATH" ]]; then
    return 0
  fi

  local existing_id
  existing_id="$(sed -n '1p' "$TRIGGER_LOCK_PATH" 2>/dev/null | tr -d '\r' || true)"
  if [[ -z "$existing_id" || "$existing_id" == "$request_id" ]]; then
    rm -f "$TRIGGER_LOCK_PATH"
  fi
}

mysql_exec() {
  local -a cmd=("$MYSQL_BIN" -h "$DB_HOST" -P "$DB_PORT" --protocol=TCP)
  if [[ -n "$DB_USER" ]]; then
    cmd+=(-u "$DB_USER")
  fi
  MYSQL_PWD="$DB_PASSWORD" "${cmd[@]}" "$@"
}

mysql_dump_exec() {
  local -a cmd=("$MYSQL_DUMP_BIN" -h "$DB_HOST" -P "$DB_PORT" --protocol=TCP)
  if [[ -n "$DB_USER" ]]; then
    cmd+=(-u "$DB_USER")
  fi
  MYSQL_PWD="$DB_PASSWORD" "${cmd[@]}" "$@"
}

pg_exec() {
  local -a cmd=(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -v ON_ERROR_STOP=1)
  PGPASSWORD="$DB_PASSWORD" "${cmd[@]}" "$@"
}

pg_query_scalar() {
  local database="$1"
  local query="$2"
  pg_exec -d "$database" -Atqc "$query"
}

db_ready() {
  case "$DB_TYPE" in
    mysql | mariadb)
      mysql_exec -Nse "SELECT 1;" >/dev/null 2>&1
      ;;
    postgres)
      pg_exec -d postgres -Atqc "SELECT 1;" >/dev/null 2>&1
      ;;
  esac
}

wait_for_db() {
  local timeout="$1"
  local start_ts
  local now_ts
  start_ts="$(date +%s)"
  while true; do
    if db_ready; then
      return 0
    fi
    now_ts="$(date +%s)"
    if (( now_ts - start_ts >= timeout )); then
      return 1
    fi
    sleep 2
  done
}

postgres_db_exists() {
  local escaped_name
  escaped_name="$(sql_escape_literal "$DB_NAME")"
  local exists
  exists="$(pg_query_scalar postgres "SELECT 1 FROM pg_database WHERE datname='${escaped_name}';" || true)"
  [[ "${exists}" == "1" ]]
}

is_db_empty() {
  local count
  local escaped_db
  local escaped_table
  local regclass_name
  local escaped_regclass

  case "$DB_TYPE" in
    mysql | mariadb)
      escaped_db="$(sql_escape_literal "$DB_NAME")"
      if [[ "$EMPTY_CHECK_MODE" == "tables_count" ]]; then
        count="$(mysql_exec -Nse "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${escaped_db}';")"
        [[ "${count:-0}" == "0" ]]
      else
        escaped_table="$(sql_escape_literal "$SENTINEL_TABLE")"
        count="$(mysql_exec -Nse "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${escaped_db}' AND table_name='${escaped_table}';")"
        [[ "${count:-0}" == "0" ]]
      fi
      ;;
    postgres)
      if ! postgres_db_exists; then
        return 0
      fi
      if [[ "$EMPTY_CHECK_MODE" == "tables_count" ]]; then
        count="$(pg_query_scalar "$DB_NAME" "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE';")"
        [[ "${count:-0}" == "0" ]]
      else
        regclass_name="$SENTINEL_TABLE"
        if [[ "$regclass_name" != *.* ]]; then
          regclass_name="public.${regclass_name}"
        fi
        escaped_regclass="$(sql_escape_literal "$regclass_name")"
        count="$(pg_query_scalar "$DB_NAME" "SELECT CASE WHEN to_regclass('${escaped_regclass}') IS NULL THEN 0 ELSE 1 END;")"
        [[ "${count:-0}" == "0" ]]
      fi
      ;;
  esac
}

latest_backup_exists() {
  case "$DB_TYPE" in
    mysql | mariadb)
      [[ -s "$BACKUP_SQL_PATH" ]]
      ;;
    postgres)
      [[ -s "$BACKUP_DUMP_PATH" ]]
      ;;
  esac
}

perform_backup() {
  ensure_backup_dir
  local tmp_path
  local rc

  case "$DB_TYPE" in
    mysql | mariadb)
      tmp_path="${BACKUP_SQL_PATH}.tmp"
      log "INFO" "Creating logical dump ${BACKUP_SQL_PATH}."
      mysql_dump_exec \
        --single-transaction \
        --quick \
        --routines \
        --events \
        --triggers \
        --databases "$DB_NAME" >"$tmp_path"
      mv "$tmp_path" "$BACKUP_SQL_PATH"
      ;;
    postgres)
      tmp_path="${BACKUP_DUMP_PATH}.tmp"
      log "INFO" "Creating logical dump ${BACKUP_DUMP_PATH}."
      PGPASSWORD="$DB_PASSWORD" pg_dump \
        -h "$DB_HOST" \
        -p "$DB_PORT" \
        -U "$DB_USER" \
        -d "$DB_NAME" \
        -Fc \
        -f "$tmp_path"
      mv "$tmp_path" "$BACKUP_DUMP_PATH"

      local tmp_globals="${BACKUP_GLOBALS_PATH}.tmp"
      set +e
      PGPASSWORD="$DB_PASSWORD" pg_dumpall \
        -h "$DB_HOST" \
        -p "$DB_PORT" \
        -U "$DB_USER" \
        --globals-only >"$tmp_globals"
      rc=$?
      set -e
      if [[ "$rc" -eq 0 ]]; then
        mv "$tmp_globals" "$BACKUP_GLOBALS_PATH"
      else
        rm -f "$tmp_globals"
        log "WARN" "Unable to dump PostgreSQL globals (roles), continuing without globals.sql."
      fi
      ;;
  esac
}

ensure_postgres_database_exists() {
  if postgres_db_exists; then
    return 0
  fi

  local escaped_ident
  escaped_ident="$(pg_escape_identifier "$DB_NAME")"
  log "INFO" "Database ${DB_NAME} does not exist, creating it."
  pg_exec -d postgres -c "CREATE DATABASE \"${escaped_ident}\";"
}

perform_restore() {
  case "$DB_TYPE" in
    mysql | mariadb)
      log "INFO" "Restoring ${BACKUP_SQL_PATH} into ${DB_NAME}."
      mysql_exec <"$BACKUP_SQL_PATH"
      ;;
    postgres)
      ensure_postgres_database_exists

      if [[ -f "$BACKUP_GLOBALS_PATH" ]]; then
        local globals_rc
        log "INFO" "Applying PostgreSQL globals from ${BACKUP_GLOBALS_PATH}."
        set +e
        pg_exec -d postgres -f "$BACKUP_GLOBALS_PATH"
        globals_rc=$?
        set -e
        if [[ "$globals_rc" -ne 0 ]]; then
          log "WARN" "Applying globals.sql failed, continuing with database restore."
        fi
      fi

      log "INFO" "Restoring ${BACKUP_DUMP_PATH} into ${DB_NAME}."
      PGPASSWORD="$DB_PASSWORD" pg_restore \
        -h "$DB_HOST" \
        -p "$DB_PORT" \
        -U "$DB_USER" \
        -d "$DB_NAME" \
        "$BACKUP_DUMP_PATH"
      ;;
  esac
}

restore_if_empty_logic() {
  ensure_backup_dir

  if [[ -f "$RESTORE_MARKER_PATH" ]]; then
    log "INFO" "Restore marker ${RESTORE_MARKER_PATH} found, skipping auto-restore."
    STARTUP_RESTORE_STATUS="marker_present"
    return 0
  fi

  if ! latest_backup_exists; then
    log "INFO" "No latest backup file found, skipping auto-restore."
    STARTUP_RESTORE_STATUS="no_backup_found"
    return 0
  fi

  if is_db_empty; then
    log "INFO" "Database considered empty, running restore from latest backup."
    perform_restore
    touch "$RESTORE_MARKER_PATH"
    log "INFO" "Restore completed; marker written to ${RESTORE_MARKER_PATH}."
    STARTUP_RESTORE_STATUS="restored"
  else
    log "INFO" "Database is not empty, skipping auto-restore."
    STARTUP_RESTORE_STATUS="db_not_empty"
  fi
}

process_trigger_request_if_present() {
  if [[ ! -f "$TRIGGER_REQUEST_PATH" ]]; then
    return 0
  fi

  local request_id
  request_id="$(read_first_line "$TRIGGER_REQUEST_PATH")"
  if [[ -z "$request_id" ]]; then
    log "ERROR" "Trigger file ${TRIGGER_REQUEST_PATH} is empty."
    write_trigger_error "(empty)" "Empty request id in ${TRIGGER_REQUEST_FILE}."
    return 0
  fi

  if ! acquire_trigger_lock "$request_id"; then
    return 0
  fi

  log "INFO" "Trigger request detected: ${request_id}."

  local error_message=""
  if ! wait_for_db "$WAIT_TIMEOUT_SEC"; then
    error_message="Database not reachable within ${WAIT_TIMEOUT_SEC}s."
  elif ! perform_backup; then
    error_message="Backup command failed."
  fi

  if [[ -z "$error_message" ]]; then
    write_trigger_done "$request_id"
    rm -f "$TRIGGER_ERROR_PATH"
    rm -f "$TRIGGER_REQUEST_PATH"
    log "INFO" "Trigger backup completed for request ${request_id}."
  else
    write_trigger_error "$request_id" "$error_message"
    log "ERROR" "Trigger backup failed for request ${request_id}: ${error_message}"
  fi

  release_trigger_lock "$request_id"
}

watch_trigger_loop() {
  local watcher_state=""

  while true; do
    if [[ ! -d "$BACKUP_DIR" ]]; then
      if [[ "$watcher_state" != "missing_backup_dir" ]]; then
        log "WARN" "Backup directory ${BACKUP_DIR} is missing; trigger watcher is idle."
        watcher_state="missing_backup_dir"
      fi
      sleep "$TRIGGER_POLL_SEC"
      continue
    fi

    if [[ ! -f "$TRIGGER_MARKER_PATH" ]]; then
      if [[ "$watcher_state" != "missing_marker" ]]; then
        log "INFO" "Marker ${TRIGGER_MARKER_PATH} not found; trigger watcher is idle."
        watcher_state="missing_marker"
      fi
      sleep "$TRIGGER_POLL_SEC"
      continue
    fi

    if [[ "$watcher_state" != "active" ]]; then
      log "INFO" "Marker ${TRIGGER_MARKER_PATH} detected; trigger watcher is active."
      watcher_state="active"
    fi

    process_trigger_request_if_present
    sleep "$TRIGGER_POLL_SEC"
  done
}

shutdown_in_progress=0
on_term() {
  if [[ "$shutdown_in_progress" -eq 1 ]]; then
    return
  fi
  shutdown_in_progress=1

  clear_startup_ready_state
  log "INFO" "Signal received, attempting backup before exit."
  set +e
  if wait_for_db 10; then
    perform_backup
    local backup_rc=$?
    if [[ "$backup_rc" -eq 0 ]]; then
      log "INFO" "Shutdown backup completed successfully."
    else
      log "WARN" "Shutdown backup failed with exit code ${backup_rc}, exiting anyway."
    fi
  else
    log "WARN" "Database not reachable during shutdown, skipping backup."
  fi
  set -e
  exit 0
}
trap on_term TERM INT

mode="${1:-run}"

case "$mode" in
  run)
    clear_startup_ready_state
    log "INFO" "Mode=run, waiting for database at ${DB_HOST}:${DB_PORT}."
    if ! wait_for_db "$WAIT_TIMEOUT_SEC"; then
      die "Database did not become ready within ${WAIT_TIMEOUT_SEC}s."
    fi
    log "INFO" "Database is reachable."

    if [[ "$RESTORE_IF_EMPTY" == "1" ]]; then
      restore_if_empty_logic
    else
      log "INFO" "RESTORE_IF_EMPTY=0, skipping auto-restore."
      STARTUP_RESTORE_STATUS="restore_disabled"
    fi

    write_startup_ready_state "$STARTUP_RESTORE_STATUS"
    log "INFO" "Startup checks completed (restore_status=${STARTUP_RESTORE_STATUS}); db_backup is ready."

    if [[ "$TRIGGER_MODE" == "1" ]]; then
      log "INFO" "TRIGGER_MODE=1, starting trigger watcher loop."
      watch_trigger_loop
    else
      log "INFO" "TRIGGER_MODE=0, entering idle loop."
      while true; do
        sleep 3600 & wait $!
      done
    fi
    ;;
  backup)
    log "INFO" "Mode=backup, waiting for database at ${DB_HOST}:${DB_PORT}."
    if ! wait_for_db "$WAIT_TIMEOUT_SEC"; then
      die "Database did not become ready within ${WAIT_TIMEOUT_SEC}s."
    fi
    perform_backup
    log "INFO" "Backup completed."
    ;;
  restore-if-empty)
    log "INFO" "Mode=restore-if-empty, waiting for database at ${DB_HOST}:${DB_PORT}."
    if ! wait_for_db "$WAIT_TIMEOUT_SEC"; then
      die "Database did not become ready within ${WAIT_TIMEOUT_SEC}s."
    fi
    restore_if_empty_logic
    log "INFO" "restore-if-empty completed."
    ;;
  watch)
    log "INFO" "Mode=watch, waiting for database at ${DB_HOST}:${DB_PORT}."
    if ! wait_for_db "$WAIT_TIMEOUT_SEC"; then
      die "Database did not become ready within ${WAIT_TIMEOUT_SEC}s."
    fi
    write_startup_ready_state "watch_mode"
    log "INFO" "Starting trigger watcher loop."
    watch_trigger_loop
    ;;
  healthcheck)
    if ! is_startup_ready; then
      exit 1
    fi
    if [[ "$HEALTHCHECK_REQUIRE_DB" == "1" ]] && ! db_ready; then
      exit 1
    fi
    exit 0
    ;;
  *)
    die "Unsupported mode: ${mode}. Use run|backup|restore-if-empty|watch|healthcheck."
    ;;
esac
