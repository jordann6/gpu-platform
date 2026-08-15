import pytest

from collector.config import Config


@pytest.fixture
def env(monkeypatch):
    monkeypatch.setenv("PROMETHEUS_URL", "http://prom:9090")
    monkeypatch.setenv("TABLE_NAME", "gpu-platform-dev-costs")
    return monkeypatch


def test_defaults_are_the_safe_ones(env):
    cfg = Config.from_env()
    assert cfg.dry_run is True
    assert cfg.idle_threshold_pct == 5.0
    assert cfg.idle_minutes == 30


def test_samples_required_covers_the_full_window(env):
    env.setenv("INTERVAL_SECONDS", "60")
    env.setenv("IDLE_MINUTES", "30")
    assert Config.from_env().samples_required == 30


def test_samples_required_never_drops_below_one(env):
    # A collection interval longer than the idle window must still demand at
    # least one confirming sample rather than reaping on zero evidence.
    env.setenv("INTERVAL_SECONDS", "3600")
    env.setenv("IDLE_MINUTES", "5")
    assert Config.from_env().samples_required == 1


@pytest.mark.parametrize("raw,expected", [("true", True), ("false", False), ("1", True), ("0", False), ("TRUE", True)])
def test_dry_run_parsing(env, raw, expected):
    env.setenv("DRY_RUN", raw)
    assert Config.from_env().dry_run is expected


def test_unset_dry_run_defaults_to_true(env):
    env.delenv("DRY_RUN", raising=False)
    assert Config.from_env().dry_run is True
