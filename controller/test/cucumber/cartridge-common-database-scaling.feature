@v2
Feature: Database Sub-Cartridge Scaling
  Background:
    Given a v2 default node
    Given a new client created mock-0.1 application

  Scenario Outline: Database in a scalable application
    When the embedded <type> cartridge is added

    When I create a test table in <db>
    And I insert test data into <db>
    Then the test data will be present in <db>

    When I snapshot the application
    And I insert additional test data into <db>
    Then the additional test data will be present in <db>

    When the embedded <type> cartridge is removed
    And the embedded <type> cartridge is added

    When I create a test table in <db> without dropping
    Then the additional test data will not be present in <db>
    And I insert additional test data into <db>
    Then the additional test data will be present in <db>

    When I restore the application
    Then the test data will be present in <db>
    And the additional test data will not be present in <db>

  @mysql
  @runtime_extended_other1
  Examples:
    | type           | db      |
    | mysql-5.1      | mysql   |

  @postgres
  @runtime_extended_other3
  Examples:
    | type           | db       |
    | postgresql-8.4 | postgres |
