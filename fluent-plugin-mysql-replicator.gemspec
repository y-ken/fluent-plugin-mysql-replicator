# -*- encoding: utf-8 -*-
Gem::Specification.new do |s|
  s.name        = "fluent-plugin-mysql-replicator"
  s.version     = "0.1.1"
  s.authors     = ["Kentaro Yoshida"]
  s.email       = ["y.ken.studio@gmail.com"]
  s.homepage    = "https://github.com/y-ken/fluent-plugin-mysql-replicator"
  s.summary     = %q{Fluentd input plugin to track insert/update/delete event from MySQL databases. It's comming support multiple table replication to another RDB/noSQL like Elasticsearch.}

  s.files         = `git ls-files`.split("\n")
  s.test_files    = `git ls-files -- {test,spec,features}/*`.split("\n")
  s.executables   = `git ls-files -- bin/*`.split("\n").map{ |f| File.basename(f) }
  s.require_paths = ["lib"]

  s.add_development_dependency "rake"
  s.add_development_dependency "webmock"
  
  s.add_runtime_dependency "fluentd"
  s.add_runtime_dependency "mysql2"
end
