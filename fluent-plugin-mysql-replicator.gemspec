# -*- encoding: utf-8 -*-
Gem::Specification.new do |s|
  s.name        = "fluent-plugin-mysql-replicator"
  s.version     = "1.4.0"
  s.authors     = ["Kentaro Yoshida"]
  s.email       = ["y.ken.studio@gmail.com"]
  s.homepage    = "https://github.com/y-ken/fluent-plugin-mysql-replicator"
  s.summary     = %q{Fluentd input plugin that tracks insert/update/delete events on a MySQL database and replicates one or many tables into Elasticsearch or Solr, with support for nested documents.}
  s.license     = "Apache-2.0"

  s.files         = `git ls-files`.split("\n")
  s.test_files    = `git ls-files -- {test,spec,features}/*`.split("\n")
  s.executables   = `git ls-files -- bin/*`.split("\n").map{ |f| File.basename(f) }
  s.require_paths = ["lib"]

  s.required_ruby_version = "> 2.1"

  s.add_development_dependency "rake"
  s.add_development_dependency "webmock", "~> 1.24.0"
  s.add_development_dependency "test-unit", ">= 3.1.0"

  s.add_runtime_dependency "fluentd", [">= 0.14.15", "< 2"]
  s.add_runtime_dependency "mysql2"
  s.add_runtime_dependency "rsolr"
end
