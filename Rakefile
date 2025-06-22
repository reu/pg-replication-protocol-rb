# frozen_string_literal: true

require "bundler/gem_tasks"
task default: %i[]

task :test do
  sh "bundle exec rbs test --target PG::Replication::* bundle exec rspec"
end
