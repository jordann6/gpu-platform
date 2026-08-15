from unittest.mock import MagicMock

import pytest

from collector.prom import GpuSample, Prometheus, PrometheusError, idle_nodes


def _series(labels, value):
    return {"metric": labels, "value": [1731000000, str(value)]}


@pytest.fixture
def prom():
    return Prometheus("http://prom:9090")


def test_detects_the_node_label_that_is_present(prom):
    prom.query = MagicMock(return_value=[_series({"Hostname": "ip-10-42-1-5", "gpu": "0"}, 0.4)])
    assert prom.detect_node_label() == "Hostname"


def test_prefers_kubernetes_node_when_both_exist(prom):
    prom.query = MagicMock(
        return_value=[_series({"kubernetes_node": "ip-10-42-1-5", "Hostname": "other"}, 0.4)]
    )
    assert prom.detect_node_label() == "kubernetes_node"


def test_detected_label_is_cached(prom):
    prom.query = MagicMock(return_value=[_series({"Hostname": "n1"}, 0.1)])
    prom.detect_node_label()
    prom.detect_node_label()
    prom.query.assert_called_once()


def test_no_series_is_an_explicit_error_not_silence(prom):
    # Silently collecting nothing is the failure mode worth guarding against:
    # a dashboard of zeros looks like an idle fleet, not a broken scrape.
    prom.query = MagicMock(return_value=[])
    with pytest.raises(PrometheusError, match="no series"):
        prom.detect_node_label()


def test_unrecognised_labels_raise(prom):
    prom.query = MagicMock(return_value=[_series({"weird": "x"}, 0.1)])
    with pytest.raises(PrometheusError, match="none of"):
        prom.detect_node_label()


def test_sample_converts_sm_ratio_to_percent(prom):
    def fake_query(expr):
        if expr.startswith("count"):
            return [_series({"Hostname": "n1"}, 1)]
        if "SM_ACTIVE" in expr:
            return [_series({"Hostname": "n1"}, 0.42)]
        if "GPU_UTIL" in expr:
            return [_series({"Hostname": "n1"}, 100)]
        return [_series({"Hostname": "n1"}, 512)]

    prom._node_label = "Hostname"
    prom.query = MagicMock(side_effect=fake_query)

    (sample,) = prom.sample()

    # The gap between these two numbers is the entire argument for the project:
    # the card reports 100% "utilization" while 58% of its SMs sit empty.
    assert sample.sm_active_pct == 42.0
    assert sample.gpu_util_pct == 100.0


def test_idle_nodes_filters_on_sm_active():
    samples = [
        GpuSample("busy", 87.0, 100.0, 8000, 1),
        GpuSample("idle", 1.2, 100.0, 300, 1),
        GpuSample("borderline", 5.0, 100.0, 400, 1),
    ]
    # A card at exactly the threshold is not idle; the comparison is strict.
    assert idle_nodes(samples, 5.0) == ["idle"]
