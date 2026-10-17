# Step definitions for behave-edge.feature under behave 1.3.0.
# behave-edge.json was captured from a root holding behave-edge.feature as features/edge.feature,
# these as features/steps/steps.py, and behave-edge-environment.py as features/environment.py:
#   behave --tags=-wip -f behave_cucumber_formatter:PrettyCucumberJSONFormatter -o behave-edge.json -f plain
# with behave==1.3.0 and behave-cucumber-formatter==1.0.1.
from behave import given


@given("a shop")
def a_shop(context):
    pass


@given("it fails")
def it_fails(context):
    raise AssertionError("boom")
