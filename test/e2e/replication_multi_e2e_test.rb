#!/usr/bin/env ruby
# End-to-end test for the multi-table input plugin (in_mysql_replicator_multi).
#
# Unlike the single plugin, this one is driven by a management database:
#   - replicator_manager.settings   : one row per replication job
#   - replicator_manager.hash_tables: persisted per-row hashes (delete detection)
#
# This test builds that management DB from setup_mysql_replicator_multi.sql,
# registers a settings row pointing at a source table, boots Fluentd wiring
# in_mysql_replicator_multi -> out_mysql_replicator_elasticsearch, and asserts
# that INSERT / UPDATE / DELETE propagate to Elasticsearch AND that the
# hash_tables state is maintained.
#
# Delete detection in the multi plugin is gap-based against hash_tables, so the
# test seeds three rows and deletes the *middle* one (id=2) to exercise it.
require_relative 'e2e_helper'
include E2E

CONF      = File.join(ROOT, 'test', 'e2e', 'fluent_multi.conf')
LOG_PATH  = File.join(ROOT, 'test', 'e2e', 'fluentd_multi.log')
SETUP_SQL = File.join(ROOT, 'setup_mysql_replicator_multi.sql')

SOURCE_DB    = ENV['MYSQL_DATABASE'] || 'e2e_source'
MANAGER_DB   = ENV['MYSQL_MANAGER_DATABASE'] || 'replicator_manager'
SETTING_NAME = 'users_to_es'
INDEX = 'multiindex'
TYPE  = 'multitype'

def hash_table_count(client, pk: nil)
  where = "setting_name = '#{SETTING_NAME}'"
  where += " AND setting_query_pk = #{pk}" if pk
  client.query("SELECT COUNT(*) AS c FROM `#{MANAGER_DB}`.hash_tables WHERE #{where}").first['c']
end

# --- 1. Seed the source database --------------------------------------------
step "seeding MySQL source database '#{SOURCE_DB}'"
es_delete_index(INDEX)
client = Mysql2::Client.new(mysql_config)
client.query("DROP DATABASE IF EXISTS `#{SOURCE_DB}`")
client.query("CREATE DATABASE `#{SOURCE_DB}`")
client.query("USE `#{SOURCE_DB}`")
client.query(<<~SQL)
  CREATE TABLE users (
    id   INT NOT NULL AUTO_INCREMENT,
    name VARCHAR(255) NOT NULL,
    age  INT NOT NULL,
    PRIMARY KEY (id)
  ) ENGINE=InnoDB DEFAULT CHARSET=utf8
SQL
client.query("INSERT INTO users (name, age) VALUES ('alice', 20), ('bob', 30), ('carol', 40)")

# --- 2. Build the management database and register a replication setting ----
step "building management database '#{MANAGER_DB}' from setup SQL"
client.query("DROP DATABASE IF EXISTS `#{MANAGER_DB}`")
File.read(SETUP_SQL).split(/;\s*$/).map(&:strip).reject(&:empty?).each do |stmt|
  client.query(stmt)
end

step "registering settings row '#{SETTING_NAME}'"
cfg = mysql_config
client.query(<<~SQL)
  INSERT INTO `#{MANAGER_DB}`.settings
    (is_active, name, host, port, username, password, `database`,
     query, prepared_query, `interval`, primary_key, enable_delete)
  VALUES
    (1, '#{SETTING_NAME}', '#{cfg[:host]}', #{cfg[:port]},
     '#{cfg[:username]}', '#{client.escape(cfg[:password].to_s)}', '#{SOURCE_DB}',
     'SELECT id, name, age FROM users ORDER BY id', '', 2, 'id', 1)
SQL

# --- 3. Boot Fluentd --------------------------------------------------------
step "starting Fluentd (#{CONF})"
fluentd_pid = spawn_fluentd(CONF, LOG_PATH)

begin
  # --- 4. INSERT is replicated to Elasticsearch -----------------------------
  step "asserting INSERT replication"
  {1 => 'alice', 2 => 'bob', 3 => 'carol'}.each do |id, name|
    wait_until("user #{id} (#{name}) indexed in Elasticsearch", log_path: LOG_PATH) do
      code, body = es_get(INDEX, TYPE, id)
      code == 200 && body.dig('_source', 'name') == name
    end
  end
  step "  INSERT OK"

  # --- 5. hash_tables state is persisted ------------------------------------
  step "asserting hash_tables persistence"
  wait_until("3 rows recorded in hash_tables for '#{SETTING_NAME}'", log_path: LOG_PATH) do
    hash_table_count(client) == 3
  end
  step "  hash_tables OK"

  # --- 6. UPDATE is replicated ----------------------------------------------
  step "asserting UPDATE replication"
  client.query("UPDATE `#{SOURCE_DB}`.users SET age = 21 WHERE id = 1")
  wait_until("user 1 age updated to 21 in Elasticsearch", log_path: LOG_PATH) do
    code, body = es_get(INDEX, TYPE, 1)
    code == 200 && body.dig('_source', 'age') == 21
  end
  step "  UPDATE OK"

  # --- 7. DELETE (middle id) is replicated ----------------------------------
  step "asserting DELETE replication (middle id=2)"
  client.query("DELETE FROM `#{SOURCE_DB}`.users WHERE id = 2")
  wait_until("user 2 removed from Elasticsearch", log_path: LOG_PATH) do
    code, _ = es_get(INDEX, TYPE, 2)
    code == 404
  end
  wait_until("hash_tables entry for id=2 removed", log_path: LOG_PATH) do
    hash_table_count(client, pk: 2) == 0
  end
  # Surviving rows must remain.
  code1, = es_get(INDEX, TYPE, 1)
  code3, = es_get(INDEX, TYPE, 3)
  fail_with("surviving rows were unexpectedly removed (id1=#{code1}, id3=#{code3})", LOG_PATH) unless code1 == 200 && code3 == 200
  step "  DELETE OK"

  puts "\n[E2E] PASSED (multi): insert/update/delete replicated and hash_tables maintained"
ensure
  step "stopping Fluentd"
  stop_fluentd(fluentd_pid)
end
