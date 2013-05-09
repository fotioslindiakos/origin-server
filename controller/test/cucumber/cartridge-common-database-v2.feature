@runtime_other4
@v2
Feature: Database Application Sub-Cartridge
  Background:
    Given a v2 default node
    Given a new mock-0.1 type application

  Scenario Outline: Create Delete one application with an embedded database
    When I embed a <type> cartridge into the application
    Then a <process> process will be running
    And the <type> cartridge instance directory will exist

    When I stop the <type> cartridge
    Then a <process> process will not be running

    When I start the <type> cartridge
    Then a <process> process will be running

    When I destroy the application
    Then a <process> process will not be running

  @mysql
  Examples:
    | type           | process  |
    | mysql-5.1      | mysqld   |

  @postgres
  Examples:
    | type           | process  |
    | postgresql-8.4 | postgres |

  @mongo
  @not-enterprise
  Examples:
    | type           | process  |
    | mongodb-2.2    | mongod   |
