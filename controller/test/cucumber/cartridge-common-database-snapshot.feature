@v2
Feature: Database Sub-Cartridge Snapshot/Restore
  Background:
    Given a v2 default node
    Given a new client created mock-0.1 application

  Scenario Outline: Snapshot/Restore an application with an embedded database
    When the embedded <type> cartridge is added

    When I create a test table in <db>
    And I insert test data into <db>
    Then the test data will be present in <db>

    When I snapshot the application
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

  Scenario Outline: Snapshot/Restore a scalable application with a database
    Given the minimum scaling parameter is set to 2
    Given the embedded <type> cartridge is added

    When I create a test table in <db>
    And I insert test data into <db>
    Then the test data will be present in <db>

    When I snapshot the application
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

  Scenario Outline: Snapshot/Restore after removing/adding database
    Given the embedded <type> cartridge is added

    When I create a test table in <db>
    When I insert test data into <db>
    Then the test data will be present in <db>

    When I snapshot the application
    And I insert additional test data into <db>
    Then the additional test data will be present in <db>

    Given the embedded <type> cartridge is removed

    When the embedded <type> cartridge is added
    And I create a test table in <db> without dropping
    Then the test data will not be present in <db>
    And the additional test data will not be present in <db>

    When I insert additional test data into <db>
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

  Scenario Outline: Snapshot/Restore after removing/adding application
    Given the embedded <type> cartridge is added

    When I create a test table in <db>
    When I insert test data into <db>
    Then the test data will be present in <db>

    When I snapshot the application
    And I insert additional test data into <db>
    Then the additional test data will be present in <db>

    Given I preserve the current snapshot
    Given the application is destroyed
    Given a new client created mock-0.1 application

    When the embedded <type> cartridge is added
    And I create a test table in <db> without dropping
    Then the test data will not be present in <db>
    And the additional test data will not be present in <db>

    When I insert additional test data into <db>
    Then the additional test data will be present in <db>

    When I restore the application from a preserved snapshot
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
