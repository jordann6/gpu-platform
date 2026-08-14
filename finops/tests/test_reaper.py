from unittest.mock import MagicMock, patch

import pytest
from collector.reaper import Reaper


@pytest.fixture
def reaper():
    with patch("collector.reaper.config"), patch("collector.reaper.client"):
        r = Reaper(samples_required=3, dry_run=True)
    r.core = MagicMock()
    r.custom = MagicMock()
    return r


def test_idle_streak_accumulates(reaper):
    assert reaper.record("node-a", True) == 1
    assert reaper.record("node-a", True) == 2
    assert reaper.record("node-a", True) == 3


def test_any_busy_sample_resets_the_streak(reaper):
    reaper.record("node-a", True)
    reaper.record("node-a", True)
    assert reaper.record("node-a", False) == 0


def test_streaks_are_tracked_per_node(reaper):
    reaper.record("node-a", True)
    reaper.record("node-b", True)
    reaper.record("node-b", True)
    assert reaper.streak("node-a") == 1
    assert reaper.streak("node-b") == 2


def test_short_streak_is_not_eligible(reaper):
    reaper.record("node-a", True)
    ok, reason = reaper.eligible("node-a")
    assert ok is False
    assert "1/3" in reason


def _make_eligible(reaper, node="node-a"):
    for _ in range(3):
        reaper.record(node, True)
    reaper.is_gpu_node = MagicMock(return_value=True)
    reaper.has_admitted_kueue_workload = MagicMock(return_value=False)
    reaper.has_running_workload = MagicMock(return_value=False)


def test_system_node_is_never_eligible(reaper):
    _make_eligible(reaper)
    reaper.is_gpu_node = MagicMock(return_value=False)
    ok, reason = reaper.eligible("node-a")
    assert ok is False
    assert "not a GPU node" in reason


def test_admitted_kueue_workload_blocks_reaping(reaper):
    # A checkpointing job reads as idle on SM occupancy. Killing it would
    # discard work the queue already admitted and paid for.
    _make_eligible(reaper)
    reaper.has_admitted_kueue_workload = MagicMock(return_value=True)
    ok, reason = reaper.eligible("node-a")
    assert ok is False
    assert "Kueue" in reason


def test_running_pods_block_reaping(reaper):
    _make_eligible(reaper)
    reaper.has_running_workload = MagicMock(return_value=True)
    ok, _ = reaper.eligible("node-a")
    assert ok is False


def test_fully_idle_node_is_eligible(reaper):
    _make_eligible(reaper)
    ok, _ = reaper.eligible("node-a")
    assert ok is True


def test_dry_run_deletes_nothing(reaper):
    _make_eligible(reaper)
    reaper.find_node_claim = MagicMock(return_value="claim-xyz")

    acted = reaper.reap("node-a")

    assert acted is False
    reaper.core.patch_node.assert_not_called()
    reaper.custom.delete_cluster_custom_object.assert_not_called()


def test_live_run_cordons_then_deletes_the_nodeclaim(reaper):
    reaper.dry_run = False
    _make_eligible(reaper)
    reaper.find_node_claim = MagicMock(return_value="claim-xyz")

    acted = reaper.reap("node-a")

    assert acted is True
    reaper.core.patch_node.assert_called_once_with("node-a", {"spec": {"unschedulable": True}})
    reaper.custom.delete_cluster_custom_object.assert_called_once()
    assert reaper.custom.delete_cluster_custom_object.call_args.kwargs["name"] == "claim-xyz"


def test_missing_nodeclaim_cordons_but_does_not_claim_success(reaper):
    # Deleting the Node object alone would accomplish nothing: Karpenter
    # reconciles the NodeClaim and a replacement appears in seconds.
    reaper.dry_run = False
    _make_eligible(reaper)
    reaper.find_node_claim = MagicMock(return_value=None)

    acted = reaper.reap("node-a")

    assert acted is False
    reaper.core.patch_node.assert_called_once()
    reaper.custom.delete_cluster_custom_object.assert_not_called()


def test_kueue_api_failure_fails_safe(reaper):
    from kubernetes.client.rest import ApiException

    reaper.custom.list_cluster_custom_object.side_effect = ApiException(status=503)
    # Unable to prove the node is free, so it must be treated as busy.
    assert reaper.has_admitted_kueue_workload("node-a") is True
