.PHONY: test test-py test-ex lint fmt run-runtime clean

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
