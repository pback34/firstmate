# Step definitions for demo.feature under behave 1.3.0, mirroring cucumber-js-steps.js.
# behave-1.3.json was captured from a root holding features/demo.feature and these as features/steps/steps.py:
#   behave -f behave_cucumber_formatter:PrettyCucumberJSONFormatter -o behave-1.3.json -f plain
# with behave==1.3.0 and behave-cucumber-formatter==1.0.1.
# behave refuses to load a second definition of the same step text, so "dup step" is defined once.
from behave import given
from behave.api.pending_step import StepNotImplementedError


@given("a shop")
def a_shop(context):
    pass


@given("count {n:d}")
def count(context, n):
    if n == 2:
        raise AssertionError("boom")


@given("dup step")
def dup_one(context):
    pass


@given("pend")
def pend(context):
    raise StepNotImplementedError("pend")
