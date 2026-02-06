# PostgreSQL S3 Backup Solution

A [Docker Compose](https://docs.docker.com/compose/)-based [PostgreSQL](https://www.postgresql.org/) backup solution that performs periodic [`pg_dump`](https://www.postgresql.org/docs/current/app-pgdump.html) backups and uploads them to S3-compatible storage (AWS S3, Backblaze B2, etc). We use [Garage](https://garagehq.deuxfleurs.fr/) for local testing.

## Architecture

```mermaid
flowchart LR
    subgraph Docker Compose Stack
        PG[(PostgreSQL)]
        Backup[Backup Container]
        S3[(Garage S3)]
        Ofelia[Ofelia Scheduler]

        PG <-->|pg_dump / psql| Backup
        Backup <-->|mc client| S3
        Ofelia -->|triggers| Backup
    end
```

## Quick Start

1. **Clone and configure:**

   ```bash
   cp .env.example .env
   # Edit .env with your settings
   ```

2. **Start all services:**

   ```bash
   make up
   ```

3. **Trigger a manual backup:**

   ```bash
   make backup
   ```

4. **List available backups:**

   ```bash
   make list-backups
   ```

5. **Restore a backup:**
   ```bash
   make restore FILE=2024/01/15/myapp_120000.sql.gz
   ```

## Configuration

All configuration is done via environment variables. See `.env.example` for available options:

| Variable            | Default              | Description                   |
| ------------------- | -------------------- | ----------------------------- |
| `POSTGRES_VERSION`  | `18`                 | PostgreSQL version (see note) |
| `POSTGRES_DB`       | `myapp`              | Database name                 |
| `POSTGRES_USER`     | `postgres`           | Database user                 |
| `POSTGRES_PASSWORD` | `changeme`           | Database password             |
| `BACKUP_SCHEDULE`   | `@hourly`            | Cron schedule (every hour)    |
| `CLEANUP_SCHEDULE`  | `0 0 1 * * *`        | Cleanup schedule (daily 1 AM) |
| `S3_ENDPOINT`       | `http://garage:3900` | S3 endpoint URL               |
| `S3_BUCKET`         | `backups`            | S3 bucket name                |
| `S3_ACCESS_KEY`     | `garage-access-key`  | S3 access key                 |
| `S3_SECRET_KEY`     | `garage-secret-key`  | S3 secret key                 |

> **Note:** Ofelia uses 6-field cron format (with seconds) or shortcuts like `@hourly`, `@daily`. See [Customizing the Backup Schedule](#customizing-the-backup-schedule).

### Retention Policy

Retention is configured using Restic-style time-bucket policies. Policies are **ORed** - a backup matching ANY policy is kept.

| Variable                 | Default | Description                           |
| ------------------------ | ------- | ------------------------------------- |
| `RETENTION_KEEP_LAST`    | `3`     | Keep N most recent backups            |
| `RETENTION_KEEP_HOURLY`  | `24`    | Keep one per hour for N hours         |
| `RETENTION_KEEP_DAILY`   | `7`     | Keep one per day for N days           |
| `RETENTION_KEEP_WEEKLY`  | `4`     | Keep one per week for N weeks         |
| `RETENTION_KEEP_MONTHLY` | `6`     | Keep one per month for N months       |
| `RETENTION_KEEP_YEARLY`  | `2`     | Keep one per year for N years         |
| `RETENTION_MIN_BACKUPS`  | `1`     | Minimum backups to keep (safety net)  |
| `RETENTION_DRY_RUN`      | `false` | Preview mode (log only, no deletions) |

With hourly backups, steady-state retention after 2+ years is approximately **39 backups**.

> **Note on PostgreSQL 18:** The Docker volume mount path has changed from `/var/lib/postgresql/data` to `/var/lib/postgresql`. This project uses the new path. If upgrading from an older PostgreSQL version, you may need to migrate your data.

## Available Commands

```bash
make help            # Show all available commands
make up              # Start all services
make down            # Stop all services
make backup          # Trigger manual backup
make restore FILE=x  # Restore specific backup
make cleanup         # Run retention cleanup
make cleanup-dry-run # Preview cleanup (no deletions)
make test            # Run integration tests
make test-retention  # Run retention policy tests
make logs            # Show logs from all services
make clean           # Stop services and remove volumes
make shell-postgres  # Open psql in postgres container
make shell-backup    # Open shell in backup container
make list-backups    # List all backups in S3
```

## Backup Storage Structure

Backups are stored in S3 with the following path structure:

```
backups/
└── YYYY/
    └── MM/
        └── DD/
            └── dbname_HHMMSS.sql.gz
```

Example: `backups/2024/01/15/myapp_120000.sql.gz`

## Adapting for Production

### Using External S3 Storage

To use AWS S3, MinIO, or another S3-compatible service instead of Garage:

1. Remove the `garage` and `garage-init` services from `docker-compose.yml`
2. Update `.env` with your S3 credentials:
   ```bash
   S3_ENDPOINT=https://s3.amazonaws.com
   S3_BUCKET=your-bucket-name
   S3_ACCESS_KEY=your-access-key
   S3_SECRET_KEY=your-secret-key
   ```

### Using Backblaze B2

For Backblaze B2:

1. Create a private bucket with **SSE-B2 encryption enabled**
2. Create an application key with **Read and Write** access to that bucket
3. Configure lifecycle settings: **"Keep only the last version of the file"** (so deletions by cleanup.sh actually free storage)
4. Update `.env`:
   ```bash
   S3_ENDPOINT=https://s3.{region}.backblazeb2.com  # e.g., s3.eu-central-003.backblazeb2.com
   S3_BUCKET=your-bucket-name
   S3_ACCESS_KEY=your-key-id
   S3_SECRET_KEY=your-application-key
   ```

### Customizing the Backup Schedule

The default schedule runs backups every hour. Modify `BACKUP_SCHEDULE` using cron format.

> **Note:** Ofelia uses **6-field cron format** (with seconds): `second minute hour day month weekday`. You can also use shortcuts like `@hourly`, `@daily`, `@weekly`.

```bash
# Every hour (using shortcut - recommended)
BACKUP_SCHEDULE=@hourly

# Every hour (6-field format)
BACKUP_SCHEDULE=0 0 * * * *

# Daily at midnight
BACKUP_SCHEDULE=0 0 0 * * *

# Weekly on Sunday at 2am
BACKUP_SCHEDULE=0 0 2 * * 0
```

### Backup Retention

Backup retention is built-in using Restic-style time-bucket policies. The cleanup job runs daily at 1 AM by default.

**Preview what would be deleted:**

```bash
make cleanup-dry-run
```

**Run cleanup manually:**

```bash
make cleanup
```

**Customize retention policy** by setting environment variables in `.env`:

```bash
# Keep more monthly archives for compliance
RETENTION_KEEP_MONTHLY=12

# Keep 2 weeks of hourly backups
RETENTION_KEEP_HOURLY=336
```

See `.env.example` for all available options

## Integrating into an Existing Project

### 1. Copy the backup stack

Copy these files to your project:

```
docker/
├── backup/
│   ├── Dockerfile
│   └── scripts/
│       ├── backup.sh
│       ├── restore.sh
│       └── cleanup.sh
└── garage/          # Optional: only for local S3 testing
    ├── garage.toml
    └── scripts/
        └── init.sh
```

### 2. Add services to your docker-compose.yml

```yaml
services:
  # Your existing app
  app:
    build: .
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      DATABASE_URL: postgres://postgres:changeme@postgres:5432/myapp

  # Add these services
  postgres:
    image: postgres:18-alpine
    environment:
      POSTGRES_DB: myapp
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:-changeme}
    volumes:
      - postgres_data:/var/lib/postgresql
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres -d myapp"]
      interval: 10s
      timeout: 5s
      retries: 5

  backup:
    build: ./docker/backup
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      POSTGRES_HOST: postgres
      POSTGRES_DB: myapp
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:-changeme}
      S3_ENDPOINT: ${S3_ENDPOINT}
      S3_BUCKET: ${S3_BUCKET}
      S3_ACCESS_KEY: ${S3_ACCESS_KEY}
      S3_SECRET_KEY: ${S3_SECRET_KEY}
    labels:
      ofelia.enabled: "true"
      ofelia.job-exec.backup.schedule: "@hourly"
      ofelia.job-exec.backup.command: "/scripts/backup.sh"
      ofelia.job-exec.cleanup.schedule: "0 0 1 * * *"
      ofelia.job-exec.cleanup.command: "/scripts/cleanup.sh"

  ofelia:
    image: mcuadros/ofelia:v3.0.8
    depends_on:
      - backup
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    command: daemon --docker

volumes:
  postgres_data:
```

### 3. Configure environment

```bash
# .env
POSTGRES_PASSWORD=your-secure-password
S3_ENDPOINT=https://s3.amazonaws.com   # or your S3-compatible endpoint
S3_BUCKET=myapp-backups
S3_ACCESS_KEY=AKIA...
S3_SECRET_KEY=...
```

### 4. Verify configuration

```bash
# Start services
docker compose up -d

# Check all services are healthy
docker compose ps

# Verify backup container can reach PostgreSQL
docker compose exec backup pg_isready -h postgres -U postgres

# Verify S3 connectivity
docker compose exec backup mc alias set s3 $S3_ENDPOINT $S3_ACCESS_KEY $S3_SECRET_KEY
docker compose exec backup mc ls s3/$S3_BUCKET/
```

### 5. Test first backup

```bash
# Run manual backup
docker compose exec backup /scripts/backup.sh

# Verify backup exists in S3
docker compose exec backup mc ls --recursive s3/$S3_BUCKET/
```

### 6. Test restore

```bash
# List available backups
docker compose exec backup mc ls --recursive s3/$S3_BUCKET/

# Restore (to same database or a test instance)
docker compose exec backup /scripts/restore.sh 2026/02/03/myapp_120000.sql.gz
```

### Quick verification script

Add this to your project as `scripts/verify-backup.sh`:

```bash
#!/bin/bash
set -euo pipefail

echo "=== Verifying backup configuration ==="

echo "1. Checking PostgreSQL..."
docker compose exec -T backup pg_isready -h postgres -U postgres

echo "2. Checking S3 access..."
docker compose exec -T backup mc ls s3/$S3_BUCKET/ >/dev/null

echo "3. Running test backup..."
docker compose exec -T backup /scripts/backup.sh

echo "4. Verifying backup in S3..."
BACKUP=$(docker compose exec -T backup mc ls --recursive s3/$S3_BUCKET/ | tail -1)
echo "   Latest backup: $BACKUP"

echo "=== All checks passed ==="
```

### Local development without real S3

For local development, include the Garage services from this project to have a local S3-compatible store - no AWS credentials needed.

## Testing

Run the integration test suite:

```bash
make test
```

This will:

1. Start all services with ephemeral volumes
2. Insert test data
3. Trigger a backup
4. Verify backup exists in S3
5. Restore to a second PostgreSQL instance
6. Verify restored data matches original
7. Clean up

## Troubleshooting

### Services won't start

Check service health:

```bash
docker compose ps
docker compose logs
```

### Backup fails

Check backup container logs:

```bash
make logs-backup
```

Verify S3 connectivity:

```bash
docker compose exec backup mc ls s3/
```

### Restore fails

Ensure the backup file exists:

```bash
make list-backups
```

Check for active connections blocking restore:

```bash
docker compose exec postgres psql -U postgres -c "SELECT * FROM pg_stat_activity WHERE datname='myapp';"
```

## CI/CD

This project includes a GitHub Actions workflow that:

1. **Lints** Dockerfiles, shell scripts, and compose config
2. **Runs integration tests** with full backup/restore cycle
3. **Captures logs** on failure for debugging

The workflow runs on:

- Push to `main` branch
- Pull requests to `main` branch

## Dependency Management

This project uses two tools for automated dependency updates:

| Tool           | Manages                             | Schedule          |
| -------------- | ----------------------------------- | ----------------- |
| **Dependabot** | GitHub Actions, Dockerfile          | Weekly (Saturday) |
| **Renovate**   | Docker images in docker-compose.yml | Weekly (Saturday) |

### Running Renovate Manually

To trigger Renovate on-demand:

1. Go to Actions > Renovate workflow
2. Click "Run workflow"
3. Optionally enable "Dry run" to preview changes without creating PRs

### Renovate Behavior

- Minor and patch updates are auto-merged after 3 days
- Major updates require manual review
- PostgreSQL version is managed via `POSTGRES_VERSION` env var (not auto-updated)

### Images Managed by Renovate

- `dxflrs/garage` - S3-compatible storage
- `alpine` - Used by garage-init
- `mcuadros/ofelia` - Job scheduler

### Setup (for maintainers)

Renovate requires a `RENOVATE_TOKEN` repository secret:

1. Go to GitHub Settings > Developer settings > Personal access tokens > Tokens (classic)
2. Generate new token with `repo` and `workflow` scopes
3. Add as repository secret named `RENOVATE_TOKEN`

## License

This project is licensed under the [MIT License](LICENSE).
