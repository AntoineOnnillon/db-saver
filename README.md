# DB Backup / Restore sidecar

Le service `db_backup` (build `./db-saver`) gère :
- backup logique dans `latest.*` (pas de rotation) ;
- restore auto au démarrage si DB vide ;
- backup à l'arrêt (`trap SIGTERM`) ;
- trigger backup par fichiers dans `/backups` (compatible Backrest sans accès Docker) ;
- healthcheck Docker "ready" après séquence startup (wait DB + restore-if-empty).

## Fichiers de dump

- MySQL / MariaDB : `/backups/latest.sql`
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
- si `.backup_request` présent : backup logique vers `latest.*` ;
- succès : écrit `.backup_done`, supprime `.backup_request` ;
- échec : écrit `.backup_error`, conserve `.backup_request` ;
- polling (NFS-friendly) : `TRIGGER_POLL_SEC` (défaut `2`).

## Backup manuel

```bash
docker compose exec -T db_backup /entrypoint.sh backup
```

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
