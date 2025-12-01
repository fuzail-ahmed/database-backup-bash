# Database backup script (Bash)

A small script to automate MySQL dumps, compress them, and rotate old backups.

## Features
- `mysqldump` with sensible options for InnoDB
- gzip compression and checksum
- retention-based rotation
- optional Git push (not recommended for large dumps)

## Installation
1. Make the script executable:
```bash
chmod +x /path/backup.sh
```

2. Edit configuration variables at the top of `backup.sh` (backup dir, DB name, retention, git enable).

3. Create `~/.my.cnf` for credentials (recommended) and restrict permissions:

```ini
[client]
user=backup_user
password=your_password
```

```bash
chmod 600 ~/.my.cnf
```

4. Test manually:

```bash
/path/backup.sh
tail -n 50 /path/database_logs/backuplogs.log
```

5. Add cron job (use absolute path):

```cron
0 1 * * * /path/backup.sh >> /path/database_logs/cron_wrapper.log 2>&1
```

## Security note

Avoid committing raw database dumps into Git — prefer object storage (S3/GCS) or an artifact repository. Use a secrets manager to store DB credentials for production.

## Author

Fuzail Ahmed

## License

GNU General Public License - see LICENSE.md
