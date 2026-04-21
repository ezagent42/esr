import os
from pathlib import Path
import pytest
from esr.cli import paths


def test_esrd_home_default(monkeypatch):
    monkeypatch.delenv("ESRD_HOME", raising=False)
    assert paths.esrd_home() == Path(os.path.expanduser("~/.esrd"))


def test_esrd_home_env(monkeypatch, tmp_path):
    monkeypatch.setenv("ESRD_HOME", str(tmp_path))
    assert paths.esrd_home() == tmp_path


def test_current_instance_default(monkeypatch):
    monkeypatch.delenv("ESR_INSTANCE", raising=False)
    assert paths.current_instance() == "default"


def test_current_instance_env(monkeypatch):
    monkeypatch.setenv("ESR_INSTANCE", "dev")
    assert paths.current_instance() == "dev"


def test_runtime_home_composes(monkeypatch, tmp_path):
    monkeypatch.setenv("ESRD_HOME", str(tmp_path))
    monkeypatch.setenv("ESR_INSTANCE", "dev")
    assert paths.runtime_home() == tmp_path / "dev"


def test_capabilities_yaml_path_respects_env(monkeypatch, tmp_path):
    monkeypatch.setenv("ESRD_HOME", str(tmp_path))
    monkeypatch.setenv("ESR_INSTANCE", "staging")
    assert paths.capabilities_yaml_path() == str(tmp_path / "staging" / "capabilities.yaml")


def test_admin_queue_dir(monkeypatch, tmp_path):
    monkeypatch.setenv("ESRD_HOME", str(tmp_path))
    monkeypatch.delenv("ESR_INSTANCE", raising=False)
    assert paths.admin_queue_dir() == tmp_path / "default" / "admin_queue"


def test_all_helpers_exist():
    # guard against name drift
    for name in ["esrd_home", "current_instance", "runtime_home",
                 "capabilities_yaml_path", "adapters_yaml_path",
                 "workspaces_yaml_path", "commands_compiled_dir",
                 "admin_queue_dir"]:
        assert callable(getattr(paths, name))
