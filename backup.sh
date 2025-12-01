#!/usr/bin/env bash
# backup.sh - MySQL dump -> gzip -> rotate -> (optional) git push
# Usage: /path/to/backup.sh
# Requirements: bash, mysqldump, gzip, git (optional), flock, find

set -euo pipefail
IFS=$'\n\t'

### Configuration - edit these ###
LOGFILE="/path/database_logs/backuplogs.log"         # absolute path
BACKUP_DIR="/path/database_backup"                    # absolute path, will be created if missing
PROJECT_NAME="mcci"
DATABASE_NAME="mcci"
RETENTION_DAYS=30                                     # how many days of backups to keep
MYSQLDUMP_OPTS="--single-transaction --quick --routines --events --triggers --skip-lock-tables"
# If you do not use .my.cnf, set MYSQL_USER and MYSQL_PWD via secure environment or vault.
GIT_REPO_ENABLE=false                                 # set true ONLY if you intentionally commit dumps to git
GIT_REMOTE="origin"
GIT_BRANCH="main"                                     # adjust
LOCKFILE="/var/lock/backup_${PROJECT_NAME}.lock"
### End configuration ###

timestamp() { date +"%Y%m%d%H%M%S"; }
log() {
    local ts
    ts="$(date +'%Y-%m-%d %H:%M:%S')"
    echo "$ts - $*" >> "$LOGFILE"
}

# Ensure required commands exist
require_cmds=(mysqldump gzip find flock)
if "$GIT_REPO_ENABLE"; then
    require_cmds+=(git)
fi

for cmd in "${require_cmds[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: required command '$cmd' not found. Aborting." >&2
        log "ERROR: required command '$cmd' not found. Aborting."
        exit 1
    fi
done

# Create directories
mkdir -p "$BACKUP_DIR"
mkdir -p "$(dirname "$LOGFILE")"
# Tighten permissions
umask 027

# Acquire lock to avoid concurrent runs
exec 9>"$LOCKFILE"
if ! flock -n 9; then
    log "Another backup process is running. Exiting."
    exit 0
fi

# Cleanup lock on exit
cleanup() {
    local rc=$?
    flock -u 9 || true
    rm -f "$LOCKFILE" || true
    log "Backup script exiting with code $rc."
    exit $rc
}
trap cleanup INT TERM EXIT

log "Backup started for project '$PROJECT_NAME', database '$DATABASE_NAME'."

# Prepare file names
TS="$(timestamp)"
TMPFILE="$(mktemp "$BACKUP_DIR/${PROJECT_NAME}_${TS}.sql.XXXX")"
OUTFILE="${BACKUP_DIR}/${PROJECT_NAME}_${TS}.sql.gz"

# Perform mysqldump -> compress
log "Running mysqldump into temporary file '$TMPFILE'."
if mysqldump $MYSQLDUMP_OPTS "$DATABASE_NAME" > "$TMPFILE"; then
    log "mysqldump completed successfully."
else
    log "ERROR: mysqldump failed."
    rm -f "$TMPFILE"
    exit 2
fi

log "Compressing dump to '$OUTFILE'."
if gzip -c "$TMPFILE" > "$OUTFILE"; then
    log "Compression successful."
    rm -f "$TMPFILE"
else
    log "ERROR: compression failed."
    rm -f "$TMPFILE" "$OUTFILE" || true
    exit 3
fi

# Create a checksum file (optional)
sha256sum "$OUTFILE" > "${OUTFILE}.sha256"
log "Checksum written to '${OUTFILE}.sha256'."

# Rotation: remove old backups
log "Removing backups older than ${RETENTION_DAYS} days in $BACKUP_DIR."
find "$BACKUP_DIR" -maxdepth 1 -type f -name "${PROJECT_NAME}_*.sql.gz" -mtime +"$RETENTION_DAYS" -print -exec rm -f {} \;
find "$BACKUP_DIR" -maxdepth 1 -type f -name "${PROJECT_NAME}_*.sql.gz.sha256" -mtime +"$RETENTION_DAYS" -print -exec rm -f {} \;

# Optional: push to git (NOT recommended for large backups)
if "$GIT_REPO_ENABLE"; then
    if [ -d "$BACKUP_DIR/.git" ]; then
        log "Preparing git push from $BACKUP_DIR."
        pushd "$BACKUP_DIR" >/dev/null
        # Safe pull
        git fetch "$GIT_REMOTE" "$GIT_BRANCH" || log "git fetch failed (continuing)."
        git pull --ff-only "$GIT_REMOTE" "$GIT_BRANCH" || log "git pull failed (continuing)."
        git add -A
        if git diff --cached --quiet; then
            log "No changes to commit."
        else
            git commit -m "Automatic backup - $TS"
            git push "$GIT_REMOTE" "$GIT_BRANCH"
            log "Changes pushed to git."
        fi
        popd >/dev/null
    else
        log "Git push requested but $BACKUP_DIR is not a git repo. Skipping git push."
    fi
fi

log "Backup completed: $OUTFILE"
# successful exit clears trap (cleanup will run)
exit 0
