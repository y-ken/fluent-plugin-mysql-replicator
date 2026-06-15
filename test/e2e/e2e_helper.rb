# Shared helpers for the end-to-end replication tests.
#
# Connection settings come from environment variables (with local defaults):
#   MYSQL_HOST MYSQL_PORT MYSQL_USER MYSQL_PASSWORD
#   ES_HOST ES_PORT
require 'mysql2'
require 'net/http'
require 'json'

module E2E
  module_function

  ROOT = File.expand_path('../..', __dir__)

  def mysql_config(database: nil)
    cfg = {
      host:     ENV['MYSQL_HOST'] || '127.0.0.1',
      port:     (ENV['MYSQL_PORT'] || 3306).to_i,
      username: ENV['MYSQL_USER'] || 'root',
      password: ENV['MYSQL_PASSWORD'] || 'root',
    }
    cfg[:database] = database if database
    cfg
  end

  def es_base
    "http://#{ENV['ES_HOST'] || '127.0.0.1'}:#{ENV['ES_PORT'] || '9200'}"
  end

  # Major version of the Elasticsearch under test (defaults to 6).
  def es_major_version
    (ENV['ES_MAJOR_VERSION'] || '6').to_i
  end

  # Realtime GET by id. Returns [http_status, parsed_body].
  # Elasticsearch 7.x+ dropped custom mapping types, so documents are addressed
  # via the "_doc" endpoint instead of the original type name.
  def es_get(index, type, id)
    type_path = es_major_version >= 7 ? '_doc' : type
    res = Net::HTTP.get_response(URI("#{es_base}/#{index}/#{type_path}/#{id}"))
    [res.code.to_i, (JSON.parse(res.body) rescue {})]
  end

  # Drop an index so a test starts from a clean slate (ignores "not found").
  def es_delete_index(index)
    uri = URI("#{es_base}/#{index}")
    Net::HTTP.start(uri.host, uri.port) { |h| h.request(Net::HTTP::Delete.new(uri)) }
  rescue StandardError
    # ignore: the index may not exist yet
  end

  # Poll a condition until it becomes truthy, otherwise fail with a timeout.
  def wait_until(description, timeout: 90, log_path: nil)
    deadline = Time.now + timeout
    loop do
      return if yield
      fail_with("timeout (#{timeout}s) waiting for: #{description}", log_path) if Time.now > deadline
      sleep 1
    end
  end

  def fail_with(message, log_path = nil)
    warn "\n[E2E] FAILED: #{message}"
    if log_path && File.exist?(log_path)
      warn "\n----- fluentd.log (tail) -----"
      warn File.readlines(log_path).last(60).join
      warn "------------------------------"
    end
    exit 1
  end

  def step(message)
    puts "[E2E] #{message}"
  end

  # Boot fluentd as a child process. Returns the pid; logs go to log_path.
  def spawn_fluentd(conf, log_path)
    log = File.open(log_path, 'w')
    Process.spawn(
      'bundle', 'exec', 'fluentd',
      '-c', conf,
      '-p', File.join(ROOT, 'lib', 'fluent', 'plugin'),
      '--no-supervisor',
      out: log, err: log, chdir: ROOT
    )
  end

  def stop_fluentd(pid)
    Process.kill('TERM', pid)
    Process.wait(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    # already gone
  end
end
