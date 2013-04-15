include SQLHelper

When /^I use the helper to select from the postgresql database$/ do
  @query_result = run_psql('select 1234')
end

When /^I use (.*) to select from the postgresql database as (\w+)(.*)$/ do |type,user,options|
  opts = {}
  env = {}

  case type
  when 'socket'
    opts['-h'] = '$OPENSHIFT_POSTGRESQL_DB_SOCKET'
  when 'host'
    opts['-h'] = '$OPENSHIFT_POSTGRESQL_DB_HOST'
    opts['-p'] = '$OPENSHIFT_POSTGRESQL_DB_PORT'
  end

  opts['-U'] = case user
               when 'env'
                 '$OPENSHIFT_POSTGRESQL_DB_USERNAME'
               else
                 user
               end
  case options
  when /with password/
    env['PGPASSWORD'] = '$OPENSHIFT_POSTGRESQL_DB_PASSWORD'
  when /with passfile/
    env['PGPASSFILE'] = nil
  end

  @query_result = run_psql('select 1234', opts, env, false)
end

When /^the result from the postgresql database should be (.*)$/ do |expected|
  case expected
  when "valid"
    @query_result.should eq "1234"
  when "invalid"
    @query_result.should_not eq "1234"
  end
end

When /^I create a test table in postgres( without dropping)?$/ do |drop|
  sql = <<-sql
    CREATE TABLE cuke_test (
      id integer PRIMARY KEY,
      msg text
    );
  sql

  without = !!!drop
  if without
    drop_sql = <<-sql
      DROP TABLE IF EXISTS cuke_test;
    sql

    sql = "#{drop_sql} #{sql}"
  end

  @query_result = run_psql(sql)
end

When /^I insert (additional )?test data into postgres$/ do |additional|
  run_sql = <<-sql
    INSERT INTO cuke_test VALUES (1,'initial data');
  sql

  additional_sql = <<-sql
    INSERT INTO cuke_test VALUES (2,'additional data');
  sql

  run_sql = additional_sql if additional

  @query_result = run_psql(run_sql)
end

Then /^the (additional )?test data will (not )?be present in postgres$/ do |additional, negate|
  @query_result = run_psql('select msg from cuke_test;')

  desired_state = !!!negate
  desired_out = additional ? "additional" : "initial"

  if (desired_state)
    @query_result.should include(desired_out)
  else
    @query_result.should_not include(desired_out)
  end
end
