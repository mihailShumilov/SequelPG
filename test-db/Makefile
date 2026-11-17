# SequelPG automated-test cluster. See README.md.
SHELL := /bin/bash
ROOT  := $(abspath ..)
PROJECT := $(ROOT)/SequelPG.xcodeproj
DEST  := platform=macOS
RESULTS := $(ROOT)/build/test-results
DERIVED := $(ROOT)/build/DerivedData
UITEST  := $(ROOT)/UITest/.build/release/sequelpg-uitest
# Xcode output is long; set V=1 to see all of it.
FILTER := $(if $(V),cat,grep -E '(error|warning: .*Test|Test Case .* (failed|passed)|Executed|\*\* TEST|skipped|XCTAssert)' || true)

.PHONY: up down reset wait status logs psql check assets \
        test test-unit test-integration build-app build-uitest test-ui test-ui-smoke ui-list test-all clean

assets:
	@./scripts/gen-assets.sh

check:
	@./scripts/check-config.py

up: check assets
	docker compose up -d --build
	@$(MAKE) --no-print-directory wait

down:
	docker compose down --remove-orphans

# Containers keep their data on tmpfs, so a restart is a fresh initdb.
reset: down up

wait:
	@printf "Waiting for test cluster"
	@for i in $$(seq 1 120); do \
		healthy=$$(docker compose ps -a --format '{{.Service}} {{.Health}}' | grep -c ' healthy$$' || true); \
		dead=$$(docker compose ps -a --format '{{.Service}} {{.State}}' | grep -c ' exited$$' || true); \
		if [[ "$$dead" -gt 0 ]]; then echo " a container exited:"; docker compose ps -a; \
			echo "Inspect with: make logs S=<service>"; exit 1; fi; \
		if [[ "$$healthy" -ge 4 ]]; then echo " ready."; exit 0; fi; \
		printf "."; sleep 1; \
	done; echo " timed out."; docker compose ps; exit 1

status:
	@docker compose ps

logs:
	docker compose logs -f $(S)

# make psql [S=pg18|pg16|pg13]
psql:
	docker compose exec $(or $(S),pg18) psql -U sp_admin -d sequelpg_test

# ── Test runs (all local) ──────────────────────────────────────────────
test-unit:
	@mkdir -p $(RESULTS)
	set -o pipefail; xcodebuild test -project $(PROJECT) -scheme SequelPG -destination '$(DEST)' \
		-resultBundlePath $(RESULTS)/unit-$$(date +%s).xcresult 2>&1 | $(FILTER)

# ONLY=Class or Class/testMethod narrows the run.
test-integration:
	@mkdir -p $(RESULTS)
	set -o pipefail; TEST_RUNNER_SEQUELPG_REQUIRE_CLUSTER=1 xcodebuild test -project $(PROJECT) -scheme SequelPGIntegrationTests -destination '$(DEST)' \
		$(if $(ONLY),-only-testing:SequelPGIntegrationTests/$(ONLY)) \
		-resultBundlePath $(RESULTS)/integration-$$(date +%s).xcresult 2>&1 | $(FILTER)

# UI scenarios drive the real app through the accessibility API, in the
# background: no mouse, no focus, no locked screen. The terminal running
# them needs Accessibility permission. ONLY="smoke edit-rows" narrows the run;
# the report is build/uitest/report/report.html.
build-app:
	set -o pipefail; xcodebuild build -project $(PROJECT) -scheme SequelPG -configuration Debug -destination '$(DEST)' \
		-derivedDataPath $(DERIVED) 2>&1 | { grep -E '( error|BUILD)' || true; }
	@test -x $(DERIVED)/Build/Products/Debug/SequelPG.app/Contents/MacOS/SequelPG

build-uitest:
	set -o pipefail; cd $(ROOT)/UITest && swift build -c release 2>&1 | { grep -E '(error|Build complete)' || true; }
	@test -x $(UITEST)

test-ui: build-app build-uitest
	$(UITEST) run $(ONLY)

test-ui-smoke:
	@$(MAKE) --no-print-directory test-ui ONLY=smoke

ui-list: build-uitest
	@$(UITEST) list

# Full local pipeline: fresh cluster → unit → integration → UI.
test-all: reset test-unit test-integration test-ui

clean:
	rm -rf $(RESULTS) $(ROOT)/build/uitest
