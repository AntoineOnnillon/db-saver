# DB Backup / Restore sidecar

Le service `db_backup` (build `./db-saver`) gère :
- backup logique dans `latest.*` (pas de rotation) ;
- mode incrémental MySQL/MariaDB (`BACKUP_MODE=incremental`) basé sur binlog ;
- restore auto au démarrage si DB vide ;
- backup à l'arrêt (`trap SIGTERM`) ;
- trigger backup par fichiers dans `/backups` (compatible Backrest sans accès Docker) ;
- healthcheck Docker "ready" après séquence startup (wait DB + restore-if-empty).

## Fichiers de dump

- MySQL / MariaDB : `/backups/latest.sql`
- MySQL / MariaDB (mode incrémental) : `/backups/latest.incremental.sql` + `/.incremental_state`
- PostgreSQL : `/backups/latest.dump`
- PostgreSQL (optionnel) : `/backups/globals.sql`
- Marker anti-boucle restore : `/backups/.restored`

## Protocole trigger fichiers (`/backups`)

- Marker obligatoire : `.db-saver`
- Requête : `.backup_request` (une seule ligne = `request_id`, écriture atomique côté déclencheur)
- Succès : `.backup_done` (exactement la même ligne `request_id`, avec newline)
- Erreur : `.backup_error` (`request_id` + message)
- Lock interne sidecar : `.backup_lock`

Comportement :
- si `.db-saver` absent : watcher inactif ;
- si `.backup_request` présent : lance `backup` selon le mode (`logical` ou `incremental`) ;
- succès : écrit `.backup_done`, supprime `.backup_request` ;
- échec : écrit `.backup_error`, conserve `.backup_request` ;
- polling (NFS-friendly) : `TRIGGER_POLL_SEC` (défaut `2`).

## Backup manuel

```bash
docker compose exec -T db_backup /entrypoint.sh backup
```

## Mode incrémental

Activer via `BACKUP_MODE=incremental`.

Comportement actuel :
- **MySQL/MariaDB** : base `latest.sql` + deltas binlog appendés dans `latest.incremental.sql`.
- **MySQL/MariaDB restore** : `latest.sql` puis application de `latest.incremental.sql` (si non vide).
- **PostgreSQL** : fallback en full logique (incrémental WAL non implémenté dans ce sidecar).

Le mode incrémental MySQL/MariaDB nécessite :
- binlog activé côté serveur (`log_bin=ON`) ;
- droits suffisants pour `SHOW MASTER STATUS`, `SHOW BINARY LOGS` et lecture binlog (`mysqlbinlog` remote).

`INCREMENTAL_REBASE_CRON` (défaut `0 3 * * *`) définit quand faire une nouvelle base full (cron 5 champs: minute heure jour mois jour-semaine).  
Le rebase s'exécute au premier backup qui tombe dans la fenêtre cron.

À l'arrêt (`SIGTERM`), `db_backup` lance un dernier `backup` (donc checkpoint incrémental si `BACKUP_MODE=incremental`) avant de quitter.

## Healthcheck `db_backup` (gating de démarrage)

`db_backup` expose `/entrypoint.sh healthcheck` :
- `healthy` uniquement quand le startup est terminé ;
- startup terminé = DB joignable + restore-if-empty exécuté (ou skip explicite) ;
- option `HEALTHCHECK_REQUIRE_DB=1` (défaut) vérifie aussi la connectivité DB à chaque probe.

Pour démarrer un service applicatif uniquement quand `db_backup` est prêt :

```yaml
services:
  app:
    depends_on:
      db_backup:
        condition: service_healthy
      mysql:
        condition: service_healthy
```

## Exemples Compose

### MariaDB + db_backup

```yaml
services:
  mariadb:
    image: mariadb:11
    restart: unless-stopped
    environment:
      MARIADB_DATABASE: ${MARIADB_DATABASE}
      MARIADB_USER: ${MARIADB_USER}
      MARIADB_PASSWORD: ${MARIADB_PASSWORD}
      MARIADB_ROOT_PASSWORD: ${MARIADB_ROOT_PASSWORD}
    volumes:
      - ${MARIADB_DATA_PATH:-mariadb_data}:/var/lib/mysql
    healthcheck:
      test: ["CMD-SHELL", "mariadb-admin ping -h localhost -u root -p\"$${MARIADB_ROOT_PASSWORD}\""]
      interval: 20s
      timeout: 20s
      retries: 20

  db_backup:
    build:
      context: ./db-saver
    restart: unless-stopped
    depends_on:
      mariadb:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "/entrypoint.sh", "healthcheck"]
      interval: 10s
      timeout: 5s
      retries: 12
      start_period: 20s
    environment:
      DB_TYPE: mariadb
      DB_HOST: mariadb
      DB_PORT: 3306
      DB_NAME: ${MARIADB_DATABASE}
      DB_USER: root
      DB_PASSWORD: ${MARIADB_ROOT_PASSWORD}
      BACKUP_DIR: /backups
      STACK_NAME: ${STACK_NAME:-mariadb-stack}
      BACKUP_BASENAME: latest
      BACKUP_MODE: ${BACKUP_MODE:-logical}
      INCREMENTAL_REBASE_CRON: "${INCREMENTAL_REBASE_CRON:-0 3 * * *}"
      WAIT_TIMEOUT_SEC: ${WAIT_TIMEOUT_SEC:-120}
      RESTORE_IF_EMPTY: ${RESTORE_IF_EMPTY:-1}
      EMPTY_CHECK_MODE: ${EMPTY_CHECK_MODE:-tables_count}
      TRIGGER_MODE: ${TRIGGER_MODE:-1}
      TRIGGER_POLL_SEC: ${TRIGGER_POLL_SEC:-2}
      TRIGGER_MARKER_FILE: ${TRIGGER_MARKER_FILE:-.db-saver}
      TRIGGER_REQUEST_FILE: ${TRIGGER_REQUEST_FILE:-.backup_request}
      TRIGGER_DONE_FILE: ${TRIGGER_DONE_FILE:-.backup_done}
      TRIGGER_ERROR_FILE: ${TRIGGER_ERROR_FILE:-.backup_error}
      HEALTHCHECK_REQUIRE_DB: ${HEALTHCHECK_REQUIRE_DB:-1}
    volumes:
      - ${DB_BACKUP_PATH:-/db_dump/mariadb-stack}:/backups
    stop_grace_period: 3m

volumes:
  mariadb_data:
```

### PostgreSQL + db_backup

```yaml
services:
  postgres:
    image: postgres:17
    restart: unless-stopped
    environment:
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - ${POSTGRES_DATA_PATH:-postgres_data}:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -h localhost -p 5432 -U $${POSTGRES_USER} -d $${POSTGRES_DB}"]
      interval: 20s
      timeout: 20s
      retries: 20

  db_backup:
    build:
      context: ./db-saver
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "/entrypoint.sh", "healthcheck"]
      interval: 10s
      timeout: 5s
      retries: 12
      start_period: 20s
    environment:
      DB_TYPE: postgres
      DB_HOST: postgres
      DB_PORT: 5432
      DB_NAME: ${POSTGRES_DB}
      DB_USER: ${POSTGRES_USER}
      DB_PASSWORD: ${POSTGRES_PASSWORD}
      BACKUP_DIR: /backups
      STACK_NAME: ${STACK_NAME:-postgres-stack}
      BACKUP_BASENAME: latest
      BACKUP_MODE: ${BACKUP_MODE:-logical}
      INCREMENTAL_REBASE_CRON: "${INCREMENTAL_REBASE_CRON:-0 3 * * *}"
      WAIT_TIMEOUT_SEC: ${WAIT_TIMEOUT_SEC:-120}
      RESTORE_IF_EMPTY: ${RESTORE_IF_EMPTY:-1}
      EMPTY_CHECK_MODE: ${EMPTY_CHECK_MODE:-tables_count}
      TRIGGER_MODE: ${TRIGGER_MODE:-1}
      TRIGGER_POLL_SEC: ${TRIGGER_POLL_SEC:-2}
      TRIGGER_MARKER_FILE: ${TRIGGER_MARKER_FILE:-.db-saver}
      TRIGGER_REQUEST_FILE: ${TRIGGER_REQUEST_FILE:-.backup_request}
      TRIGGER_DONE_FILE: ${TRIGGER_DONE_FILE:-.backup_done}
      TRIGGER_ERROR_FILE: ${TRIGGER_ERROR_FILE:-.backup_error}
      HEALTHCHECK_REQUIRE_DB: ${HEALTHCHECK_REQUIRE_DB:-1}
    volumes:
      - ${DB_BACKUP_PATH:-/db_dump/postgres-stack}:/backups
    stop_grace_period: 3m

volumes:
  postgres_data:
```

Créer ensuite le marker sur le dossier monté (`/db_dump/<stack>/.db-saver`) pour activer les triggers par fichiers.

## Exemple script Backrest (sans Docker)

Script type `snapshot_start` : parcours tous les sous-dossiers de `/db_dump/*`, déclenche les sidecars marqués `.db-saver`, attend `done` ou `error`.

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${1:-/db_dump}"
POLL_SEC="${POLL_SEC:-2}"
TIMEOUT_SEC="${TIMEOUT_SEC:-300}"

for stack_dir in "${ROOT_DIR}"/*; do
  [[ -d "${stack_dir}" ]] || continue

  marker="${stack_dir}/.db-saver"
  request="${stack_dir}/.backup_request"
  done_file="${stack_dir}/.backup_done"
  error_file="${stack_dir}/.backup_error"

  if [[ ! -f "${marker}" ]]; then
    echo "skip ${stack_dir}: marker missing"
    continue
  fi

  request_id="$(basename "${stack_dir}")-$(date +%s)-$$"
  printf '%s\n' "${request_id}" > "${request}.tmp"
  mv "${request}.tmp" "${request}"
  echo "trigger ${stack_dir} request_id=${request_id}"

  deadline=$(( $(date +%s) + TIMEOUT_SEC ))
  while true; do
    if [[ -f "${done_file}" ]]; then
      done_id="$(sed -n '1p' "${done_file}" | tr -d '\r')"
      if [[ "${done_id}" == "${request_id}" ]]; then
        echo "ok ${stack_dir}"
        break
      fi
    fi

    if [[ -f "${error_file}" ]]; then
      error_id="$(sed -n '1p' "${error_file}" | tr -d '\r')"
      if [[ "${error_id}" == "${request_id}" ]]; then
        echo "error ${stack_dir}"
        cat "${error_file}"
        exit 1
      fi
    fi

    if (( $(date +%s) >= deadline )); then
      echo "timeout ${stack_dir} (request_id=${request_id})"
      exit 1
    fi

    sleep "${POLL_SEC}"
  done
done
```

## Marker `.db-saver`

Créer le marker dans chaque sous-dossier à superviser, par exemple :

```bash
mkdir -p /db_dump/mysql-test
touch /db_dump/mysql-test/.db-saver
```

## Variables clés du sidecar

- `DB_TYPE=mysql|mariadb|postgres` (obligatoire)
- `DB_HOST`, `DB_PORT`
- `DB_NAME` (obligatoire)
- `DB_USER` (optionnel pour mysql/mariadb, requis pour postgres)
- `DB_PASSWORD` (obligatoire)
- `BACKUP_DIR` (défaut `/backups`)
- `BACKUP_BASENAME` (défaut `latest`)
- `BACKUP_MODE=logical|incremental` (défaut `logical`)
- `INCREMENTAL_STATE_FILE` (défaut `.incremental_state`)
- `INCREMENTAL_REBASE_CRON` (défaut `0 3 * * *`)
- `WAIT_TIMEOUT_SEC` (défaut `120`)
- `RESTORE_IF_EMPTY=1|0`
- `EMPTY_CHECK_MODE=tables_count|sentinel_table`
- `SENTINEL_TABLE` (requis si `sentinel_table`)
- `TRIGGER_MODE=1|0` (défaut `1`, active le watcher en mode `run`)
- `TRIGGER_POLL_SEC` (défaut `2`)
- `TRIGGER_MARKER_FILE` (défaut `.db-saver`)
- `TRIGGER_REQUEST_FILE` (défaut `.backup_request`)
- `TRIGGER_DONE_FILE` (défaut `.backup_done`)
- `TRIGGER_ERROR_FILE` (défaut `.backup_error`)
- `TRIGGER_LOCK_FILE` (défaut `.backup_lock`)
- `TRIGGER_LOCK_TIMEOUT_SEC` (défaut `300`)
- `HEALTH_STATE_DIR` (défaut `/tmp/db-saver-state`)
- `HEALTH_READY_FILE` (défaut `/tmp/db-saver-state/startup-ready`)
- `HEALTHCHECK_REQUIRE_DB=1|0` (défaut `1`)

## Test restore (manuel)

1. Créer une table + insérer une ligne dans la DB.
2. Lancer un backup manuel.
3. Supprimer/vider le volume DB (commande destructive, à lancer volontairement).
4. Relancer la stack : si DB vide et `latest.*` présent, restore auto (une seule fois via `.restored`).
