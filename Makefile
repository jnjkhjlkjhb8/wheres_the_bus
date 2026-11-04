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


.PHONY: migrations-check run-test run-staging build-prod test test-go test-flutter quality quality-all lint lint-fix lint-tool proto-go proto-dart l10n-push l10n-pull l10n-pull-sources verify

test: test-go test-flutter

test-go: proto-go
	go vet ./...
	go test ./...

test-flutter: proto-dart
	cd app && flutter analyze --no-fatal-infos && flutter test

# CRAP <= 4, mutation score >= 90% and (Go) duplication < 0.8 on code changed since QUALITY_BASE
# (default HEAD: the uncommitted work). Slow, so not part of `make test`.
quality: proto-go proto-dart
	go test -coverprofile=coverage.out ./...
	cd app && flutter test --coverage
	./scripts/check-quality.sh go flutter

quality-all: export QUALITY_SCOPE = all
quality-all: proto-go proto-dart
	@if [ "$$QUALITY_SCOPE" != all ] || [ "$${QUALITY_PHASE:-all}" != all ] || \
	    [ "$${QUALITY_DART_SHARD_COUNT:-1}" != 1 ] || [ "$${QUALITY_DART_SHARD_INDEX:-0}" != 0 ]; then \
	  echo "quality-all requires the complete all phase and an unsharded Dart run; use check-quality.sh for diagnostics or workers" >&2; exit 2; \
	fi
	python3 scripts/quality-report.py go-preflight
	go test -p=1 -coverpkg=./... -coverprofile=coverage.out ./...
	./scripts/collect-quality-flutter.sh
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
	git diff --exit-code

migrations-check:
	./scripts/check-migrations.sh

run-test:
	cd app && flutter run --dart-define-from-file=env/test.json

run-staging:
	cd app && flutter run --dart-define-from-file=env/staging.json

build-prod:
	cd app && flutter build ipa --dart-define-from-file=env/prod.json
