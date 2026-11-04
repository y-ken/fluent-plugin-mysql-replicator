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

  # The connection of prepared_query lost in the middle of a poll, which does not connect again: the rest of the poll is
  # skipped with one line, whether enable_retry is set or not, and the next poll compares its first row with the last row
  # of the poll before the skipped one, not with the last row seen, which would make the rows after it look deleted.
  def test_lost_connection_of_prepared_query_skips_the_rest_of_the_poll
    instance = create_driver.instance
    config = {
      'name' => 'users', 'query' => 'SELECT id, items FROM users', 'prepared_query' => 'SET @a = 1',
      'primary_key' => 'id', 'interval' => 60, 'retry_interval' => 30, 'json_columns' => nil,
      'enable_delete' => 1, 'enable_loose_insert' => 1, 'enable_loose_delete' => 0, 'enable_retry' => 0,
    }
    instance.instance_variable_set(:@mutex, Mutex.new)
    instance.instance_variable_set(:@running, true)
    polls = [[]]
    compared = []
    clients = []
    instance.define_singleton_method(:emit_record) {|tag, record| polls.last << record['id'] }
    instance.define_singleton_method(:update_hashtable) {|_opts| }
    instance.define_singleton_method(:detect_delete) {|_config, current_id, previous_id| compared << [current_id, previous_id] }
    instance.define_singleton_method(:get_origin_connection) do |_config, _reconnect = true|
      poll = polls.size
      client = FakeMysqlClient.new do |sql|
        case sql
        when /FROM users/ then (1..3).map {|id| {'id' => id, 'items' => 'SELECT name FROM item WHERE id = ${id}'} }
        when /WHERE id = 2/
          if poll == 2
            clients.find {|c| c.queries.last == sql }.close
            raise Mysql2::Error.new('Lost connection to server during query', nil, 2013, 'HY000')
          end
          [{'name' => 'n'}]
        when /FROM item/ then [{'name' => 'n'}]
        end
      end
      clients << client
      client
    end
    instance.define_singleton_method(:sleep) do |seconds|
      polls.size >= 3 ? @running = false : polls << []
    end
    @polled_instance = instance
    Timeout.timeout(10) { instance.poll(config) }
    assert_equal([[1, 2, 3], [1], [1, 2, 3]], polls)
    assert_equal([[1, nil], [2, 1], [3, 2], [1, 3], [1, 3], [2, 1], [3, 2]], compared)
    logs = @polled_instance.log.out.logs.grep(/\[(warn|error)\]/)
    assert_equal(1, logs.size, logs.inspect)
    assert_match(/\[error\]: mysql_replicator_multi: lost the connection of prepared_query; skipped the rest of this poll\. :setting_name=>users :errno=>2013 :sql_state=>HY000$/, logs.first)
  end

  # The connection of prepared_query is opened with reconnect off.
  def test_get_origin_connection_passes_reconnect
    instance = create_driver.instance
    options = []
    Mysql2::Client.define_singleton_method(:new) {|opts| options << opts; :client }
    begin
      instance.get_origin_connection({'host' => 'h'}, false)
      instance.get_origin_connection({'host' => 'h'})
    ensure
      Mysql2::Client.singleton_class.send(:remove_method, :new)
    end
    assert_equal([false, true], options.map {|opts| opts[:reconnect] })
  end
end
