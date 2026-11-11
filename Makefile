# odoo-platform dev/ops targets. Consumed from a PRODUCT repo root via its
# thin Makefile:
#
#   OWN_MODULES ?= my_module_a,my_module_b
#   include platform/Makefile
#
# All targets run from the product root. `make help` for the list.
COMPOSE ?= docker compose
# Dev stack = prod compose + the dev override (ports, live mount, reload).
COMPOSE_DEV ?= $(COMPOSE) -f docker-compose.yml -f platform/docker-compose.override.yml
SERVICE ?= odoo
ODOO_RC ?= /etc/odoo/odoo.conf
# Product-specific: set OWN_MODULES in the product Makefile before the include.
OWN_MODULES ?=

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

.PHONY: env
env: ## Create .env from .env.example if missing
	@test -f .env || (cp .env.example .env && echo "created .env — edit it")

.PHONY: build
build: ## Build the Odoo image
	$(COMPOSE) build

.PHONY: up
up: env ## Start the full stack (dev: ports + reload via override)
	$(COMPOSE_DEV) up -d --build

.PHONY: debug
debug: env ## Start with debugpy and wait for the IDE to attach (port 5678)
	DEBUG=1 DEBUGPY_WAIT=1 $(COMPOSE_DEV) up --build

.PHONY: down
down: ## Stop the stack
	$(COMPOSE) down

.PHONY: restart
restart: ## Restart the odoo service
	$(COMPOSE) restart $(SERVICE)

.PHONY: logs
logs: ## Tail odoo logs
	$(COMPOSE) logs -f $(SERVICE)

.PHONY: shell
shell: ## Bash inside the running odoo container
	$(COMPOSE) exec $(SERVICE) bash

.PHONY: odoo-shell
odoo-shell: ## Odoo interactive shell (python). db=NAME to target (default DB_NAME)
	$(COMPOSE) exec $(SERVICE) odoo shell -c $(ODOO_RC) -d $${db:-$${DB_NAME:-odoo}} --no-http

.PHONY: psql
psql: ## psql into a database. db=NAME (default DB_NAME)
	$(COMPOSE) exec db psql -U $${DB_USER:-odoo} -d $${db:-$${DB_NAME:-odoo}}

.PHONY: init
init: ## First-time install of own modules on a fresh DB. db=NAME (default DB_NAME)
	$(COMPOSE) run --rm $(SERVICE) odoo -c $(ODOO_RC) -d $${db:-$${DB_NAME:-odoo}} \
		-i base,$(OWN_MODULES) --stop-after-init

.PHONY: upgrade
upgrade: ## Upgrade own modules. m=mod1,mod2 to target; db=NAME
	$(COMPOSE) exec $(SERVICE) odoo -c $(ODOO_RC) -d $${db:-$${DB_NAME:-odoo}} \
		-u $${m:-$(OWN_MODULES)} --stop-after-init

# --- Database management (works regardless of list_db) -----------------------
.PHONY: dblist
dblist: ## List all databases
	$(COMPOSE) exec db psql -U $${DB_USER:-odoo} -d postgres -c "\l"

.PHONY: dbcreate
dbcreate: ## Create + init a new DB: make dbcreate db=test
	$(COMPOSE) run --rm $(SERVICE) odoo -c $(ODOO_RC) -d $${db:?set db=name} \
		-i base,$(OWN_MODULES) --stop-after-init

.PHONY: dbtest
dbtest: ## Clone production DB into a fresh test copy: make dbtest [from=odoo to=test]
	$(COMPOSE) exec db sh -c 'dropdb -U $${DB_USER:-odoo} --if-exists $${to:-test} && \
		createdb -U $${DB_USER:-odoo} -T $${from:-odoo} $${to:-test}'
	@echo "Cloned $${from:-odoo} -> $${to:-test}. (Neutralize crons/mail in the test DB!)"

.PHONY: dbdrop
dbdrop: ## Drop a DB: make dbdrop db=test
	$(COMPOSE) exec db dropdb -U $${DB_USER:-odoo} --if-exists $${db:?set db=name}

.PHONY: dbbackup
dbbackup: ## Dump a DB to ./backups: make dbbackup db=odoo
	@mkdir -p backups
	$(COMPOSE) exec -T db pg_dump -U $${DB_USER:-odoo} -Fc $${db:?set db=name} \
		> backups/$${db}-$$(date +%Y%m%d-%H%M%S).dump
	@echo "wrote backups/$${db}-*.dump"

.PHONY: dbrestore
dbrestore: ## Restore: make dbrestore db=test file=backups/odoo-x.dump
	$(COMPOSE) exec -T db pg_restore -U $${DB_USER:-odoo} -d $${db:?set db=name} \
		--clean --if-exists < $${file:?set file=path}

# --- Repo plumbing ------------------------------------------------------------
.PHONY: check
check: ## Verify src/ layout (only custom_addons + third_party_addons)
	bash platform/scripts/check-layout.sh

.PHONY: selection
selection: check ## Regenerate _selected from selection.txt + stub selection_reasons.md
	bash platform/scripts/build-selection.sh
	bash platform/scripts/selection-reasons.sh --sync

.PHONY: reasons
reasons: ## Verify every loaded module has a why-line in selection_reasons.md
	bash platform/scripts/selection-reasons.sh --check

.PHONY: hooks
hooks: ## Install the repo pre-commit checks (layout + selection reasons)
	git config core.hooksPath platform/githooks
	@echo "pre-commit checks active (git config core.hooksPath platform/githooks)"

# SSH submodule URLs exist for the deploy pipeline (Dokploy pulls them with a
# server-side SSH key). Local dev machines authenticate via gh over HTTPS, so
# rewrite those URLs to HTTPS in LOCAL config only — .gitmodules is untouched.
.PHONY: dev-remotes
dev-remotes: ## Point SSH-only submodules at HTTPS locally (deploy keeps SSH)
	@git config --file .gitmodules --get-regexp '^submodule\..*\.url$$' | \
	while read -r key url; do \
		case "$$url" in \
		git@github.com:*) \
			https="https://github.com/$${url#git@github.com:}"; \
			name="$${key#submodule.}"; name="$${name%.url}"; \
			path="$$(git config --file .gitmodules submodule.$$name.path)"; \
			git config "submodule.$$name.url" "$$https"; \
			if [ -e "$$path/.git" ]; then git -C "$$path" remote set-url origin "$$https"; fi; \
			echo "local override: $$name -> $$https"; \
			;; \
		esac; \
	done

.PHONY: submodules
submodules: dev-remotes ## Pull latest upstream for all _vendor submodules
	git submodule update --init --remote -- src/third_party_addons/_vendor
	@echo "review + commit the bumps: git add src/third_party_addons/_vendor"

.PHONY: platform
platform: ## Pull the latest odoo-platform (this submodule)
	git submodule update --remote -- platform
	@echo "review + commit the bump: git add platform"
