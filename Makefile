.PHONY: test test-py test-ex lint fmt run-runtime clean e2e e2e-ci e2e-01 e2e-02 e2e-04 e2e-05 e2e-06 e2e-07

test: test-py test-ex

test-py:
	cd py && uv run pytest

test-ex:
	cd runtime && mix test

lint:
	cd py && uv run ruff check . && uv run mypy src/
	cd runtime && mix credo --strict

fmt:
	cd py && uv run ruff format .
	cd runtime && mix format

run-runtime:
	cd runtime && iex -S mix

clean:
	cd py && rm -rf .venv .pytest_cache .ruff_cache .mypy_cache
	cd runtime && mix clean

# --- PR-7 end-to-end scenarios ---------------------------------------
# Run all three scenarios serially. Wall-time budget: <5 min total.
# Hard timeout wrapper — prevents a hung esrd from holding CI. Uses
# `perl -e 'alarm ...'` for portability (macOS ships without GNU
# `timeout`; CI runners have perl in the base image).
E2E_TIMEOUT ?= 420
E2E_RUN = perl -e 'alarm shift; exec @ARGV' $(E2E_TIMEOUT) bash

e2e: e2e-01 e2e-02 e2e-04 e2e-05 e2e-06 e2e-07

e2e-01:
	$(E2E_RUN) tests/e2e/scenarios/01_single_user_create_and_end.sh

e2e-02:
	$(E2E_RUN) tests/e2e/scenarios/02_two_users_concurrent.sh

e2e-04:
	$(E2E_RUN) tests/e2e/scenarios/04_multi_app_routing.sh

e2e-05:
	$(E2E_RUN) tests/e2e/scenarios/05_topology_routing.sh

e2e-06:
	$(E2E_RUN) tests/e2e/scenarios/06_pty_attach.sh

e2e-07:
	$(E2E_RUN) tests/e2e/scenarios/07_pty_bidir.sh

# CI variant: absolute cleanup (§7.2). Same scripts, different env.
e2e-ci:
	ESR_E2E_CI=1 $(MAKE) e2e
