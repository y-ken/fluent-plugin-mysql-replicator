#!/usr/bin/env ruby
# End-to-end test for fluent-plugin-mysql-replicator.
#
# It seeds a source table in MySQL, boots a real Fluentd process wiring
# in_mysql_replicator -> out_mysql_replicator_elasticsearch (see fluent.conf),
# and asserts that INSERT / UPDATE / DELETE on MySQL are replicated to
# Elasticsearch.
#
# Connection settings come from environment variables (with local defaults):
#   MYSQL_HOST MYSQL_PORT MYSQL_USER MYSQL_PASSWORD MYSQL_DATABASE
#   ES_HOST ES_PORT
require 'mysql2'
require 'net/http'
require 'json'

ROOT      = File.expand_path('../..', __dir__)
CONF      = File.join(ROOT, 'test', 'e2e', 'fluent.conf')
LOG_PATH  = File.join(ROOT, 'test', 'e2e', 'fluentd.log')

DB        = ENV['MYSQL_DATABASE'] || 'e2e_source'
ES_BASE   = "http://#{ENV['ES_HOST'] || '127.0.0.1'}:#{ENV['ES_PORT'] || '9200'}"
INDEX     = 'myindex'
TYPE      = 'mytype'

def mysql_config
  {
    host:     ENV['MYSQL_HOST'] || '127.0.0.1',
    port:     (ENV['MYSQL_PORT'] || 3306).to_i,
    username: ENV['MYSQL_USER'] || 'root',
    password: ENV['MYSQL_PASSWORD'] || 'root',
  }
end

def es_get(id)
  res = Net::HTTP.get_response(URI("#{ES_BASE}/#{INDEX}/#{TYPE}/#{id}"))
  body = (JSON.parse(res.body) rescue {})
  [res.code.to_i, body]
end

# Poll a condition until it becomes truthy, otherwise fail with a timeout.
def wait_until(description, timeout: 90)
  deadline = Time.now + timeout
  loop do
    return if yield
    if Time.now > deadline
      fail_with("timeout (#{timeout}s) waiting for: #{description}")
    end
    sleep 1
  end
end

def fail_with(message)
  warn "\n[E2E] FAILED: #{message}"
  if File.exist?(LOG_PATH)
    warn "\n----- fluentd.log (tail) -----"
    warn File.readlines(LOG_PATH).last(60).join
    warn "------------------------------"
  end
  exit 1
end

def step(message)
  puts "[E2E] #{message}"
end

# --- 1. Seed the source database --------------------------------------------
step "seeding MySQL source database '#{DB}'"
client = Mysql2::Client.new(mysql_config)
client.query("DROP DATABASE IF EXISTS `#{DB}`")
client.query("CREATE DATABASE `#{DB}`")
client.query("USE `#{DB}`")
client.query(<<~SQL)
  CREATE TABLE users (
    id   INT NOT NULL AUTO_INCREMENT,
    name VARCHAR(255) NOT NULL,
    age  INT NOT NULL,
    PRIMARY KEY (id)
  ) ENGINE=InnoDB DEFAULT CHARSET=utf8
SQL
client.query("INSERT INTO users (name, age) VALUES ('alice', 20), ('bob', 30)")

# --- 2. Boot Fluentd --------------------------------------------------------
step "starting Fluentd (#{CONF})"
log = File.open(LOG_PATH, 'w')
fluentd_pid = Process.spawn(
  'bundle', 'exec', 'fluentd',
  '-c', CONF,
  '-p', File.join(ROOT, 'lib', 'fluent', 'plugin'),
  '--no-supervisor',
  out: log, err: log, chdir: ROOT
)

begin
  # --- 3. INSERT is replicated ----------------------------------------------
  step "asserting INSERT replication"
  wait_until("user 1 (alice) indexed in Elasticsearch") do
    code, body = es_get(1)
    code == 200 && body.dig('_source', 'name') == 'alice'
  end
  wait_until("user 2 (bob) indexed in Elasticsearch") do
    code, body = es_get(2)
    code == 200 && body.dig('_source', 'name') == 'bob'
  end
  step "  INSERT OK"

  # --- 4. UPDATE is replicated ----------------------------------------------
  step "asserting UPDATE replication"
  client.query("UPDATE users SET age = 21 WHERE id = 1")
  wait_until("user 1 age updated to 21 in Elasticsearch") do
    code, body = es_get(1)
    code == 200 && body.dig('_source', 'age') == 21
  end
  step "  UPDATE OK"

  # --- 5. DELETE is replicated ----------------------------------------------
  step "asserting DELETE replication"
  client.query("DELETE FROM users WHERE id = 2")
  wait_until("user 2 removed from Elasticsearch") do
    code, _ = es_get(2)
    code == 404
  end
  step "  DELETE OK"

  puts "\n[E2E] PASSED: insert/update/delete replicated MySQL -> Elasticsearch"
ensure
  step "stopping Fluentd"
  begin
    Process.kill('TERM', fluentd_pid)
    Process.wait(fluentd_pid)
  rescue Errno::ESRCH, Errno::ECHILD
    # already gone
  end
  log.close
end
