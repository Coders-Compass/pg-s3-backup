.PHONY: up down backup restore test logs clean help

# Default environment file
ENV_FILE ?= .env

# Load environment if exists
ifneq (,$(wildcard $(ENV_FILE)))
    include $(ENV_FILE)
    export
endif

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-15s\033[0m %s\n", $$1, $$2}'

up: ## Start all services
	docker compose up -d --wait

down: ## Stop all services
	docker compose down

backup: ## Trigger a manual backup
	docker compose exec backup /scripts/backup.sh

restore: ## Restore a backup (usage: make restore FILE=backups/2024/01/01/myapp_120000.sql.gz)
	@if [ -z "$(FILE)" ]; then echo "Usage: make restore FILE=path/to/backup.sql.gz"; exit 1; fi
	docker compose exec backup /scripts/restore.sh $(FILE)

test: ## Run integration tests
	docker compose -f docker-compose.yml -f docker-compose.test.yml up -d --build --wait
	./test/integration.sh
	docker compose -f docker-compose.yml -f docker-compose.test.yml down -v

logs: ## Show logs from all services
	docker compose logs -f

logs-backup: ## Show logs from backup service
	docker compose logs -f backup

clean: ## Stop services and remove volumes
	docker compose down -v --remove-orphans
	docker compose -f docker-compose.yml -f docker-compose.test.yml down -v --remove-orphans 2>/dev/null || true

build: ## Build the backup image
	docker compose build backup

shell-backup: ## Open a shell in the backup container
	docker compose exec backup sh

shell-postgres: ## Open psql in the postgres container
	docker compose exec postgres psql -U $${POSTGRES_USER:-postgres} -d $${POSTGRES_DB:-myapp}

list-backups: ## List all backups in S3
	docker compose exec backup mc ls --recursive s3/backups/
