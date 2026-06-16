#!/usr/bin/env ruby
# End-to-end test for the single-table input plugin (in_mysql_replicator).
#
# It seeds a source table in MySQL, boots a real Fluentd process wiring
# in_mysql_replicator -> out_mysql_replicator_elasticsearch (fluent_single.conf),
# and asserts that INSERT / UPDATE / DELETE on MySQL are replicated to
# Elasticsearch.
require_relative 'e2e_helper'
include E2E

CONF     = File.join(ROOT, 'test', 'e2e', 'fluent_single.conf')
LOG_PATH = File.join(ROOT, 'test', 'e2e', 'fluentd_single.log')

DB    = ENV['MYSQL_DATABASE'] || 'e2e_source'
INDEX = 'myindex'
TYPE  = 'mytype'

# --- 1. Seed the source database --------------------------------------------
step "seeding MySQL source database '#{DB}'"
es_delete_index(INDEX)
client = Mysql2::Client.new(mysql_config)
client.query("DROP DATABASE IF EXISTS `#{DB}`")
client.query("CREATE DATABASE `#{DB}`")
client.query("USE `#{DB}`")
client.query(<<~SQL)
  CREATE TABLE users (
    id      INT NOT NULL AUTO_INCREMENT,
    name    VARCHAR(255) NOT NULL,
    age     INT NOT NULL,
    profile JSON,
    PRIMARY KEY (id)
  ) ENGINE=InnoDB DEFAULT CHARSET=utf8
SQL
client.query(<<~SQL)
  INSERT INTO users (name, age, profile) VALUES
    ('alice', 20, '{"city":"Tokyo","tags":["a","b"]}'),
    ('bob',   30, '{"city":"Osaka","tags":["c"]}')
SQL

# --- 2. Boot Fluentd --------------------------------------------------------
step "starting Fluentd (#{CONF})"
fluentd_pid = spawn_fluentd(CONF, LOG_PATH)

begin
  # --- 3. INSERT is replicated ----------------------------------------------
  step "asserting INSERT replication"
  wait_until("user 1 (alice) indexed in Elasticsearch", log_path: LOG_PATH) do
    code, body = es_get(INDEX, TYPE, 1)
    code == 200 && body.dig('_source', 'name') == 'alice'
  end
  wait_until("user 2 (bob) indexed in Elasticsearch", log_path: LOG_PATH) do
    code, body = es_get(INDEX, TYPE, 2)
    code == 200 && body.dig('_source', 'name') == 'bob'
  end
  step "  INSERT OK"

  # --- 3b. JSON column is indexed as a nested object (not an escaped string) -
  step "asserting JSON column is replicated as a nested object"
  wait_until("user 1 profile.city == Tokyo in Elasticsearch", log_path: LOG_PATH) do
    code, body = es_get(INDEX, TYPE, 1)
    code == 200 && body.dig('_source', 'profile', 'city') == 'Tokyo'
  end
  _, body = es_get(INDEX, TYPE, 1)
  unless body.dig('_source', 'profile', 'tags') == ['a', 'b']
    fail_with("profile was not indexed as a nested object: #{body.dig('_source', 'profile').inspect}", LOG_PATH)
  end
  step "  JSON OK"

  # --- 4. UPDATE is replicated ----------------------------------------------
  step "asserting UPDATE replication"
  client.query("UPDATE users SET age = 21 WHERE id = 1")
  wait_until("user 1 age updated to 21 in Elasticsearch", log_path: LOG_PATH) do
    code, body = es_get(INDEX, TYPE, 1)
    code == 200 && body.dig('_source', 'age') == 21
  end
  step "  UPDATE OK"

  # --- 5. DELETE is replicated ----------------------------------------------
  step "asserting DELETE replication"
  client.query("DELETE FROM users WHERE id = 2")
  wait_until("user 2 removed from Elasticsearch", log_path: LOG_PATH) do
    code, _ = es_get(INDEX, TYPE, 2)
    code == 404
  end
  step "  DELETE OK"

  puts "\n[E2E] PASSED (single): insert/update/delete replicated MySQL -> Elasticsearch"
ensure
  step "stopping Fluentd"
  stop_fluentd(fluentd_pid)
end
