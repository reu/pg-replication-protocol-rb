# frozen_string_literal: true

require_relative "lib/pg/replication/version"

Gem::Specification.new do |spec|
  spec.name = "pg-replication-protocol"
  spec.version = PG::Replication::VERSION
  spec.authors = ["Rodrigo Navarro"]
  spec.email = ["rnavarro@rnavarro.com.br"]

  spec.summary = "Postgres replication protocol"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 2.6.0"

  spec.metadata["homepage_uri"] = "https://github.com/reu/pg-replication-protocol-rb"
  spec.metadata["source_code_uri"] = "https://github.com/reu/pg-replication-protocol-rb"

  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").reject do |f|
      (f == __FILE__) || f.match(%r{\A(?:(?:bin|test|spec|features)/|\.(?:git|circleci)|appveyor)})
    end
  end

  spec.require_paths = ["lib"]

  spec.add_dependency "pg", "~> 1.0"
end
