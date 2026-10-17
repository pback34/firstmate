Feature: Edge cases

  Scenario: plain passes
    Given a shop

  @wip
  Scenario: excluded by tag filter
    Given a shop

  @skip
  Scenario: skipped by tag
    Given a shop

  @boom
  Scenario: setup hook crashes
    Given a shop

  Scenario: step after a failure
    Given it fails
    And a shop
