from collector.pricing import interval_cost, wasted_cost


def test_interval_cost_prorates_by_the_second():
    # g4dn.xlarge on-demand, one 60s collection interval.
    assert round(interval_cost(0.526, 60), 6) == round(0.526 / 60, 6)


def test_interval_cost_is_zero_for_zero_interval():
    assert interval_cost(1.006, 0) == 0.0


def test_wasted_cost_counts_a_fully_idle_card_as_total_loss():
    spend = interval_cost(0.526, 60)
    assert wasted_cost(spend, 0.0) == round(spend, 8)


def test_wasted_cost_counts_a_saturated_card_as_no_loss():
    spend = interval_cost(0.526, 60)
    assert wasted_cost(spend, 100.0) == 0.0


def test_wasted_cost_is_linear_between():
    spend = interval_cost(1.0, 3600)  # exactly $1.00
    assert wasted_cost(spend, 25.0) == 0.75


def test_wasted_cost_clamps_above_full_occupancy():
    # DCGM profiling counters can read fractionally over 1.0 on some driver
    # versions; that must never produce a negative waste figure.
    spend = interval_cost(1.0, 3600)
    assert wasted_cost(spend, 104.0) == 0.0
