# Loads the plugins to confirm they (and the mysql2 native extension) are
# usable at runtime after a fresh install. Shared by both install-smoke jobs.
require "fluent/plugin/in_mysql_replicator"
require "fluent/plugin/in_mysql_replicator_multi"
puts "input plugins loaded; mysql2 native extension OK"
