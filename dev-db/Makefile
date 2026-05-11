SHELL := /bin/bash
ENV_FILE := .env

# Load defaults from .env.example when no .env exists yet so plain `make up`
# works on a fresh checkout without forcing the user to copy the file first.
ifeq ($(wildcard $(ENV_FILE)),)
include .env.example
export
else
include $(ENV_FILE)
export
endif

PORT ?= $(POSTGRES_PORT)
DB   ?= $(POSTGRES_DB)
USER ?= $(POSTGRES_USER)
PASS ?= $(POSTGRES_PASSWORD)

.PHONY: up down stop restart reset logs psql info port wait status

up:
	docker compose up -d
	@$(MAKE) --no-print-directory wait
	@$(MAKE) --no-print-directory info

down:
	docker compose down

stop:
	docker compose stop

restart:
	docker compose restart

# Wipes the data volume so the next `up` re-runs every init script. Use this
# whenever you change anything under init/.
reset:
	docker compose down -v
	docker compose up -d
	@$(MAKE) --no-print-directory wait
	@$(MAKE) --no-print-directory info

logs:
	docker compose logs -f postgres

# Block until pg_isready returns success — saves users from "connection
# refused" the moment after `up`, before the cluster has finished initdb.
wait:
	@printf "Waiting for postgres on 127.0.0.1:$(PORT)..."
	@for i in $$(seq 1 60); do \
		if docker compose exec -T postgres pg_isready -U $(USER) -d $(DB) >/dev/null 2>&1; then \
			echo " ready."; exit 0; \
		fi; \
		printf "."; sleep 1; \
	done; \
	echo " timed out."; exit 1

psql:
	docker compose exec -e PGPASSWORD=$(PASS) postgres psql -U $(USER) -d $(DB)

port:
	@echo $(PORT)

status:
	@docker compose ps

info:
	@echo
	@echo "  SequelPG demo database is up."
	@echo "  ─────────────────────────────"
	@echo "  Host:     127.0.0.1"
	@echo "  Port:     $(PORT)"
	@echo "  Database: $(DB)"
	@echo "  User:     $(USER)"
	@echo "  Password: $(PASS)"
	@echo
	@echo "  psql:     psql -h 127.0.0.1 -p $(PORT) -U $(USER) -d $(DB)"
	@echo "  URI:      postgres://$(USER):$(PASS)@127.0.0.1:$(PORT)/$(DB)"
	@echo
