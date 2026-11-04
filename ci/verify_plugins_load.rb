# Loads the plugins to confirm they (and the mysql2 native extension) are
# usable at runtime after a fresh install. Shared by both install-smoke jobs.
# The outputs are loaded too, so that a library that Fluentd stops bundling
# (such as yajl-ruby in Fluentd 1.20.1) is caught here.
require "fluent/plugin/in_mysql_replicator"
require "fluent/plugin/in_mysql_replicator_multi"
require "fluent/plugin/out_mysql_replicator_elasticsearch"
require "fluent/plugin/out_mysql_replicator_solr"
puts "input and output plugins loaded; mysql2 native extension OK"
