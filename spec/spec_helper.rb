require "testcontainers/postgres"

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  RSpec::Matchers.matcher :match_pattern do |expected|
    match do |actual|
      eval("actual in #{expected.inspect}", binding, __FILE__, __LINE__ + 1)
    end

    failure_message do |actual|
      "expected #{actual.inspect} to match pattern #{expected.inspect}"
    end
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups

  config.add_setting :postgres_container, default: nil

  config.before(:suite) do
    config.postgres_container = Testcontainers::PostgresContainer
      .new
      .with_command("-cwal_level=logical")
      .start
  end

  config.after(:suite) do
    config.postgres_container&.stop
    config.postgres_container&.remove
  end
end
