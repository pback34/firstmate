# Hooks for behave-edge.feature: @skip skips from inside the code, and @boom crashes the setup hook.
def before_scenario(context, scenario):
    if "skip" in scenario.effective_tags:
        scenario.skip("marked @skip")
    if "boom" in scenario.effective_tags:
        raise RuntimeError("setup hook crashed")
