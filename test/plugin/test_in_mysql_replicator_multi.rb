require 'helper'
require 'fluent/test/driver/input'

class MysqlReplicatorMultiInputTest < Test::Unit::TestCase
  def setup
    Fluent::Test.setup
  end

  CONFIG = %[
    manager_host      localhost
    manager_port      3306
    manager_username  foo
    manager_password  bar
    tag               replicator.${name}.${event}.${primary_key}
  ]

  def create_driver(conf=CONFIG)
    Fluent::Test::Driver::Input.new(Fluent::Plugin::MysqlReplicatorMultiInput).configure(conf)
  end

  def test_configure
    assert_raise(Fluent::ConfigError) {
      d = create_driver('')
    }
    d = create_driver(CONFIG)
    assert_equal 'localhost', d.instance.manager_host
    assert_equal 3306, d.instance.manager_port
    assert_equal 'replicator_manager', d.instance.manager_database
  end

  # The message of a MySQL error can hold values of the rows.
  def prepared_error
    Mysql2::Error.new("Duplicate entry 'secret-value' for key 'PRIMARY'", nil, 1062, '23000')
  end

  # Runs poll(config) for one poll per failure of prepared_query: nil (it does not fail), :statement (its statement
  # fails) or :after_rows (a CALL fails after the rows it returned). Returns the events of each poll, the connections it
  # opened as [client, reconnect], and the seconds it slept.
  def run_prepared_polls(*failures)
    instance = create_driver.instance
    config = {
      'name' => 'users', 'query' => 'SELECT id, name FROM users', 'prepared_query' => 'CALL p_prepare()',
      'primary_key' => 'id', 'interval' => 60, 'retry_interval' => 30, 'json_columns' => nil,
      'enable_delete' => 1, 'enable_loose_insert' => 1, 'enable_loose_delete' => 0, 'enable_retry' => 0,
    }
    instance.instance_variable_set(:@mutex, Mutex.new)
    instance.instance_variable_set(:@running, true)
    polls = [[]]
    connections = []
    slept = []
    test = self
    instance.define_singleton_method(:emit_record) {|tag, record| polls.last << [tag, record] }
    instance.define_singleton_method(:update_hashtable) {|_opts| }
    instance.define_singleton_method(:get_origin_connection) do |_config, reconnect = true|
      failure = failures[polls.size - 1]
      client = FakeMysqlClient.new do |sql|
        raise test.prepared_error if sql.start_with?('CALL') && failure == :statement
        sql.start_with?('CALL') ? [{'ok' => 1}] : [{'id' => 1, 'name' => 'a'}, {'id' => 2, 'name' => 'b'}]
      end
      client.define_singleton_method(:next_result) do
        raise test.prepared_error if failure == :after_rows && queries.last.start_with?('CALL')
        super()
      end
      connections << [client, reconnect]
      client
    end
    instance.define_singleton_method(:sleep) do |seconds|
      slept << seconds
      polls.size >= failures.size ? @running = false : polls << []
    end
    @polled_instance = instance
    Timeout.timeout(10) { instance.poll(config) }
    [polls, connections, slept]
  end

  # A failed prepared_query skips the poll, whether enable_retry is set or not: nothing is sent, one line is logged with
  # the error number and the SQLSTATE but not the message, and the next poll runs it again on a new connection after
  # the interval, without waiting for retry_interval too.
  def test_failed_prepared_query_skips_the_poll_and_is_run_again
    polls, connections, slept = run_prepared_polls(:statement, :after_rows, nil)
    assert_equal([[], [], [1, 2]], polls.map {|events| events.map {|_, record| record['id'] } })
    assert_equal([60, 60, 60], slept)
    logs = @polled_instance.log.out.logs.grep(/\[(warn|error)\]/)
    assert_equal(2, logs.size, logs.inspect)
    logs.each do |line|
      assert_match(/\[error\]: mysql_replicator_multi: prepared_query failed; skipped this poll\. :setting_name=>users :errno=>1062 :sql_state=>23000$/, line)
    end
    # The connection of prepared_query is not connected again by the client, which would lose the session.
    assert_equal([false, false, false, true], connections.map {|_, reconnect| reconnect })
    assert_true(connections.all? {|client, _| client.closed? })
  end
end
