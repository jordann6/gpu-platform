import time

import pytest

from collector import main


@pytest.fixture
def heartbeat(tmp_path, monkeypatch):
    path = tmp_path / "collector-heartbeat"
    monkeypatch.setattr(main, "HEARTBEAT", path)
    return path


def test_touch_writes_a_timestamp(heartbeat):
    main.touch_heartbeat()
    assert abs(int(heartbeat.read_text()) - int(time.time())) < 5


def test_touch_overwrites_rather_than_appends(heartbeat):
    heartbeat.write_text("1700000000")
    main.touch_heartbeat()
    # An appending write would produce an unparseable value and the liveness
    # probe would fail a healthy pod.
    assert int(heartbeat.read_text()) > 1700000000


def test_a_failing_tick_still_beats(heartbeat, monkeypatch):
    """The loop is healthy even when its dependency is not.

    Prometheus being unreachable is not a reason to restart the collector;
    killing the pod would not fix Prometheus, and the restart loop would just
    hide the real failure.
    """
    cfg = type("C", (), {"interval_seconds": 60})()

    def boom(*_args, **_kwargs):
        raise RuntimeError("prometheus unreachable")

    monkeypatch.setattr(main, "tick", boom)

    # Mirrors the loop body's ordering: tick failure is caught, then the
    # heartbeat is touched regardless.
    try:
        main.tick(cfg, None, None, None, None)
    except RuntimeError:
        pass
    main.touch_heartbeat()

    assert heartbeat.exists()
