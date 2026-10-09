COMPOSE ?= docker compose --project-directory .

# Pinned protoc plugin versions. protoc-gen-go tracks the google.golang.org/protobuf
# version in go.mod; protoc-gen-go-grpc is versioned independently. Bump both
# deliberately, never via @latest, so `make proto-go` is reproducible from a
# clean checkout.
PROTOC_GEN_GO_VERSION := v1.36.11
PROTOC_GEN_GO_GRPC_VERSION := v1.6.2
# Same rule for the linter: pinned, installed into .tools/bin, never @latest,
# so `make lint` reports the same issues here and in CI.
GOLANGCI_LINT_VERSION := v2.12.2
TOOLS_BIN := $(CURDIR)/.tools/bin

# each service reads only its own rendered env file (scripts/render-env.sh,
# allowlisted by scripts/env-allowlists/*.txt), not the operator's single
# env/<env>.env — see docs/config.md. The operator contract is unchanged
# (still one env/<env>.env to fill in); render-env-% regenerates
# env/.rendered/<env>/*.env from it before every up-%.
RENDERED_TEST := env/.rendered/test
RENDERED_STAGING := env/.rendered/staging
RENDERED_PROD := env/.rendered/prod

# One compose invocation per environment, shared by up-/logs-/down-. Keeping
# the project name, env file, and overlay list in one place stops the three
# targets of an environment from drifting apart. ENV_FILE stays set (compose-
# level ${BIND_HOST:-...} etc. substitution, and the default env_file: for
# any service that doesn't set its own ENV_FILE_<SERVICE> override) alongside
# the per-service ENV_FILE_<SERVICE> overrides.
COMPOSE_TEST := ENV_FILE=env/test.env \
	ROUTING_NETWORK=bus-test-routing \
	ENV_FILE_ROUTER=$(RENDERED_TEST)/router.env ENV_FILE_FUNCTIONS=$(RENDERED_TEST)/functions.env \
	ENV_FILE_PIPELINE=$(RENDERED_TEST)/pipeline.env ENV_FILE_RIDER=$(RENDERED_TEST)/rider.env \
	ENV_FILE_POWERSYNC=$(RENDERED_TEST)/powersync.env ENV_FILE_MOTIS=$(RENDERED_TEST)/motis.env \
	COMPOSE_PROFILES=motis \
	$(COMPOSE) -p test --env-file ./env/test.env -f docker/docker-compose.yaml -f docker/docker-compose.test.yaml
COMPOSE_STAGING := ENV_FILE=env/staging.env \
	ROUTING_NETWORK=bus-routing \
	ENV_FILE_ROUTER=$(RENDERED_STAGING)/router.env ENV_FILE_FUNCTIONS=$(RENDERED_STAGING)/functions.env \
	ENV_FILE_PIPELINE=$(RENDERED_STAGING)/pipeline.env ENV_FILE_RIDER=$(RENDERED_STAGING)/rider.env \
	ENV_FILE_POWERSYNC=$(RENDERED_STAGING)/powersync.env ENV_FILE_MOTIS=$(RENDERED_STAGING)/motis.env \
	$(COMPOSE) -p staging --env-file ./env/staging.env -f docker/docker-compose.yaml -f docker/docker-compose.staging.yaml
COMPOSE_PROD := ENV_FILE=env/prod.env \
	ROUTING_NETWORK=bus-routing \
	ENV_FILE_ROUTER=$(RENDERED_PROD)/router.env ENV_FILE_FUNCTIONS=$(RENDERED_PROD)/functions.env \
	ENV_FILE_PIPELINE=$(RENDERED_PROD)/pipeline.env ENV_FILE_RIDER=$(RENDERED_PROD)/rider.env \
	ENV_FILE_POWERSYNC=$(RENDERED_PROD)/powersync.env ENV_FILE_MOTIS=$(RENDERED_PROD)/motis.env \
	COMPOSE_PROFILES=motis \
	$(COMPOSE) -p prod --env-file ./env/prod.env -f docker/docker-compose.yaml -f docker/docker-compose.prod.yaml

# Optional service filter for the logs- targets: `make logs-prod SERVICE=router`.
# Empty (the default) follows every service in the environment.
SERVICE ?=

.PHONY: up-test up-staging up-prod logs-test logs-staging logs-prod down-test down-staging down-prod migrations-check run-test run-staging build-prod test test-go test-flutter quality lint lint-fix lint-tool proto-go proto-dart l10n-push l10n-pull l10n-pull-sources verify render-env-test render-env-staging render-env-prod refresh-motis-prod

test: test-go test-flutter

test-go: proto-go
	go vet ./...
	go test ./...

test-flutter: proto-dart
	cd app && flutter analyze --no-fatal-infos && flutter test

# CRAP <= 8 and mutation score >= 90% on code changed since QUALITY_BASE
# (default HEAD: the uncommitted work). Slow, so not part of `make test`.
quality: proto-go proto-dart
	go test -coverprofile=coverage.out ./...
	cd app && flutter test --coverage
	./scripts/check-quality.sh go flutter

# lint reads .golangci.yml. lint-fix additionally applies the fixes the enabled
# linters can make on their own (gofmt + the auto-fixable staticcheck rules).
lint: lint-tool
	$(TOOLS_BIN)/golangci-lint run ./...

lint-fix: lint-tool
	$(TOOLS_BIN)/golangci-lint fmt ./...
	$(TOOLS_BIN)/golangci-lint run --fix ./...

# Always installs rather than testing for the binary: a bumped
# GOLANGCI_LINT_VERSION must not keep running the previously installed one.
# The install is a no-op against a warm module cache.
lint-tool:
	mkdir -p $(TOOLS_BIN)
	GOBIN=$(TOOLS_BIN) go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@$(GOLANGCI_LINT_VERSION)

proto-go:
	mkdir -p $(TOOLS_BIN)
	GOBIN=$(TOOLS_BIN) go install google.golang.org/protobuf/cmd/protoc-gen-go@$(PROTOC_GEN_GO_VERSION)
	GOBIN=$(TOOLS_BIN) go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@$(PROTOC_GEN_GO_GRPC_VERSION)
	PATH="$(TOOLS_BIN):$$PATH" protoc --go_out=paths=source_relative:models --go-grpc_out=paths=source_relative:models -I models models/*.proto

proto-dart:
	mkdir -p app/lib/data/generated
	PATH="$$PATH:$$HOME/.pub-cache/bin" protoc --dart_out=grpc:app/lib/data/generated -I models models/*.proto

# Crowdin round trip. `app/lib/l10n/app_zh.arb` is the source; every other ARB
# is a Crowdin artifact, pulled and committed as-is. All three targets need
# CROWDIN_PERSONAL_TOKEN. The pull targets regenerate the Dart classes so a
# pull that adds a locale or changes a placeholder is compilable in one step.
l10n-push:
	crowdin push sources

l10n-pull:
	crowdin pull
	cd app && flutter gen-l10n

# Brings zh-TW source edits made in the Crowdin editor back into app_zh.arb.
# Overwrites the hand-authored file, so run it on a clean tree and read the
# diff before committing — in particular check that the `@key` descriptions
# survived the round trip, since they travel as Crowdin string context.
l10n-pull-sources:
	crowdin download sources
	cd app && flutter gen-l10n

verify: proto-go
	./scripts/ci.sh contracts
	./scripts/ci.sh go
	./scripts/ci.sh flutter
	./scripts/ci.sh security
	./scripts/ci.sh migrations
	./scripts/check-container-hardening.sh
	./scripts/check-spacing-tokens.sh
	git diff --exit-code

render-env-test:
	./scripts/render-env.sh env/test.env $(RENDERED_TEST)

render-env-staging:
	./scripts/render-env.sh env/staging.env $(RENDERED_STAGING)

render-env-prod:
	./scripts/render-env.sh env/prod.env $(RENDERED_PROD)

up-test: render-env-test
	ROUTING_NETWORK=bus-test-routing ./scripts/ensure-routing-network.sh
	$(COMPOSE_TEST) up -d --build postgres redis router functions

up-staging: render-env-staging
	./scripts/ensure-routing-network.sh
	$(COMPOSE_STAGING) up -d --build --wait

up-prod: render-env-prod
	./scripts/ensure-routing-network.sh
	$(COMPOSE_PROD) up -d --build --wait

# Re-fetch the OSM extract, rebuild the MOTIS data set if either input has
# changed, and restart motis so it maps the new one. motis-import renames the
# finished directory into place, which a running motis does not observe -- it
# keeps the inodes it mmapped at start -- so the restart is what actually
# publishes the rebuild. Both steps are no-ops when neither gtfs.zip nor the
# PBF has changed, because the built directory is content-addressed on both.
#
# This is also the nightly hook: the loader publishes gtfs.zip at the end of
# its 03:30 chain, so run this after it. Geofabrik rotates the PBF weekly and
# osrm-data is shared with staging.
#   30 4 * * * cd /srv/bus && make refresh-motis-prod >> /var/log/motis-refresh.log 2>&1
#
# The planner returns errors while motis is down rather than degrading -- there
# is deliberately no automatic TDX fallback (ADR-0022) -- so unlike the OSRM
# refresh this replaced, the restart is user-visible for the few seconds it
# takes. MAAS_BACKEND=tdx is the way to cover a longer outage.
refresh-motis-prod: render-env-prod
	$(COMPOSE_PROD) up osrm-fetch motis-import
	$(COMPOSE_PROD) restart motis

# logs- follows (Ctrl-C to stop) and starts from the last 200 lines, enough to
# catch the failure that prompted the call without replaying the whole history.
logs-test:
	$(COMPOSE_TEST) logs -f --tail=200 $(SERVICE)

logs-staging:
	$(COMPOSE_STAGING) logs -f --tail=200 $(SERVICE)

logs-prod:
	$(COMPOSE_PROD) logs -f --tail=200 $(SERVICE)

# down stops and removes containers, never volumes -- prod's ./osrm-data and the
# test postgres survive a down/up cycle.
down-test:
	$(COMPOSE_TEST) down

down-staging:
	$(COMPOSE_STAGING) down

down-prod:
	$(COMPOSE_PROD) down

migrations-check:
	./scripts/check-migrations.sh

run-test:
	cd app && flutter run --dart-define-from-file=env/test.json

run-staging:
	cd app && flutter run --dart-define-from-file=env/staging.json

build-prod:
	cd app && flutter build ipa --dart-define-from-file=env/prod.json
