@acct
Feature: Demo

  Background:
    Given a shop

  Scenario: plain passes
    Given a shop

  Rule: subscriptions
    Example: inside rule undefined
      Given nothing defined here

  Scenario Outline: outline <n>
    Given count <n>

    Examples: first
      | n |
      | 1 |
      | 2 |

    Examples: second
      | n |
      | 3 |

  Scenario: ambiguous one
    Given dup step

  Scenario: pending one
    Given pend
