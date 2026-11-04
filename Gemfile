source 'https://rubygems.org'

# Specify your gem's dependencies in fluent-plugin-mysql-replicator.gemspec
gemspec

# CI runs the unit tests with json 2.x too, which handles a binary string differently from json 3.
gem 'json', ENV['JSON_VERSION'] unless ENV['JSON_VERSION'].to_s.empty?
