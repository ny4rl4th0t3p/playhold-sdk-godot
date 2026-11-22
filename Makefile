# The playhold version this SDK is built for: its frames come from that version's proto, and its tests run against a
# server on that version. testserver/go.mod must require the same one; make pin checks it.
PLAYHOLD_VERSION := v0.5.0
# The Godot version the SDK is tested with, and the binary that runs it. make pin checks they match.
GODOT_VERSION := 4.7.2
GODOT ?= godot

# The tools, fetched into addons/ at these refs and left out of git: Godobuf generates frames.gd, GUT runs the tests.
GODOBUF_REPO := https://github.com/oniksan/godobuf.git
GODOBUF_REF := 523a66e2388c4235ded0aa5f2fecf91cf7e7a861
GUT_REPO := https://github.com/bitwes/Gut.git
GUT_REF := v9.7.1

BUF_VERSION := v1.75.0
BUF := go run github.com/bufbuild/buf/cmd/buf@$(BUF_VERSION)
PROTO := https://github.com/ny4rl4th0t3p/playhold.git\#tag=$(PLAYHOLD_VERSION),subdir=proto

# fetch copies folder $(3) of repository $(1), at commit or tag $(2), to $(4), through a clone in .tools/$(5). It
# never deletes anything: if $(4) holds another ref, it stops and says what to delete.
fetch = @if [ -e $(4) ]; then \
		if [ "$$(cat $(4)/.ref 2>/dev/null)" != '$(2)' ]; then \
			echo "$(4) isn't at $(2): delete it and .tools/$(5), then run make tools again"; exit 1; \
		fi; \
	else \
		{ [ -d .tools/$(5) ] || git clone --quiet $(1) .tools/$(5); } && \
		git -C .tools/$(5) -c advice.detachedHead=false checkout --quiet '$(2)' && \
		mkdir -p $(dir $(4)) && cp -R .tools/$(5)/$(3) $(4) && echo '$(2)' > $(4)/.ref; \
	fi

.DEFAULT_GOAL := help

.PHONY: help check tools gen test server pin tidy

help: ## Show the available targets
	@awk 'BEGIN {FS = ":.*## "} /^[a-z]+:.*## / {printf "  %-6s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

check: test server pin ## Run every check

tools: ## Fetch Godobuf and GUT into addons/, at their pinned refs
	$(call fetch,$(GODOBUF_REPO),$(GODOBUF_REF),addons/godobuf,addons/godobuf,godobuf)
	$(call fetch,$(GUT_REPO),$(GUT_REF),addons/gut,addons/gut,gut)

gen: tools ## Generate addons/playhold/frames.gd from playhold's frames.proto at PLAYHOLD_VERSION
	@mkdir -p addons/playhold && \
	$(BUF) export '$(PROTO)' --path playhold/v1/frames.proto -o .tools/proto && \
	$(GODOT) --headless -s addons/godobuf/godobuf_cmdln.gd \
		--input=.tools/proto/playhold/v1/frames.proto --output=addons/playhold/frames.gd

test: tools ## Run the tests, with Godot headless; GUT reads which ones from .gutconfig.json
	$(GODOT) --headless --import
	$(GODOT) --headless -s addons/gut/gut_cmdln.gd -gexit

server: ## Build and vet the test server
	cd testserver && go build -o /dev/null . # a single main package: without -o, go build would write the binary here
	cd testserver && go vet ./...

pin: ## Check testserver/go.mod requires PLAYHOLD_VERSION, and $(GODOT) is GODOT_VERSION
	@got=$$(cd testserver && go list -m -f '{{.Version}}' github.com/ny4rl4th0t3p/playhold); \
	if [ "$$got" != "$(PLAYHOLD_VERSION)" ]; then \
		echo "testserver/go.mod requires playhold $$got, but PLAYHOLD_VERSION is $(PLAYHOLD_VERSION)"; exit 1; \
	fi
	@got=$$($(GODOT) --version 2>/dev/null); \
	case "$$got" in \
		$(GODOT_VERSION).stable*) ;; \
		*) echo "$(GODOT) is Godot $$got, but GODOT_VERSION is $(GODOT_VERSION)"; exit 1;; \
	esac

tidy: ## Tidy the test server's module
	cd testserver && go mod tidy