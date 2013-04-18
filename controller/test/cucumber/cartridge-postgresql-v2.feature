@runtime_other
Feature: Postgres Application Sub-Cartridge
  Background:
    Given a v2 default node

  Scenario: Create/Delete one application with a Postgres database
    Given a new mock-0.1 type application

    When I embed a postgresql-8.4 cartridge into the application
    Then a postgres process will be running
    And the postgresql-8.4 cartridge instance directory will exist

    When I stop the postgresql-8.4 cartridge
    Then a postgres process will not be running

    When I start the postgresql-8.4 cartridge
    Then a postgres process will be running

    When I destroy the application
    Then a postgres process will not be running

  Scenario: Database connections
    Given a new client created mock-0.1 application
    Given the embedded postgresql-8.4 cartridge is added

    # using psql wrapper
    # VALID
    When I use the helper to select from the postgresql database
    Then the result from the postgresql database should be valid

    # postgres, socket
    # VALID
    When I use socket to select from the postgresql database as postgres
    Then the result from the postgresql database should be valid

    # postgres, TCP
    # INVALID
    When I use host to select from the postgresql database as postgres
    Then the result from the postgresql database should be invalid

    # ENV user, socket
    # VALID
    When I use socket to select from the postgresql database as env
    Then the result from the postgresql database should be valid

    # ENV user, tcp without credentials
    # INVALID
    When I use host to select from the postgresql database as env
    Then the result from the postgresql database should be invalid

    # ENV user, tcp with PGPASSFILE
    # VALID
    When I use host to select from the postgresql database as env with passfile
    Then the result from the postgresql database should be valid
