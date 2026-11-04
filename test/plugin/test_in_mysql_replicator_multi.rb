require 'helper'
require 'fluent/test/driver/input'
require 'fake_mysql_client'
require 'timeout'

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

  # Returns the plugin instance with a fake manager database, whose queries are answered by the block.
  def instance_with_manager(conf=CONFIG, &responder)
    instance = create_driver(conf).instance
    manager = FakeMysqlClient.new(&responder)
    instance.define_singleton_method(:get_manager_connection) { manager }
    [instance, manager]
  end

  def setting(overrides = {})
    {
      'name' => 'users', 'query' => 'SELECT id, name FROM users ORDER BY id', 'prepared_query' => '',
      'primary_key' => 'id', 'interval' => 60, 'retry_interval' => 30, 'json_columns' => nil,
      'enable_delete' => 1, 'enable_loose_insert' => 0, 'enable_loose_delete' => 0, 'enable_retry' => 0,
    }.merge(overrides)
  end

  def users(*ids)
    ids.map {|id| {'id' => id, 'name' => "user#{id}"} }
  end

  # Runs poll(config) for one poll per table, and returns the events of each poll as [tag, record]. A table is the
  # rows of the query, or a Proc that returns them. The sleep after each poll moves on to the next table, and
  # hash_tables is a FakeHashTables that is written at once (bulk_insert_count 1).
  def run_polls(config, *tables, origin: nil, hash_tables: FakeHashTables.new)
    instance, manager = instance_with_manager(CONFIG + "bulk_insert_count 1\n") {|sql| hash_tables.call(sql) }
    instance.instance_variable_set(:@manager_db, manager)
    # The deletes are read on a connection of their own.
    instance.define_singleton_method(:get_manager_connection) { FakeMysqlClient.new {|sql| hash_tables.call(sql) } }
    instance.instance_variable_set(:@mutex, Mutex.new)
    instance.instance_variable_set(:@running, true)
    instance.instance_variable_set(:@hash_table_bulk_insert, [])
    instance.instance_variable_set(:@hash_table_bulk_insert_last_time, Time.now)
    polls = [[]]
    instance.define_singleton_method(:emit_record) {|tag, record| polls.last << [tag, record] }
    instance.define_singleton_method(:get_origin_connection) do |_config, _reconnect = true|
      FakeMysqlClient.new do |sql|
        next origin.call(sql) if origin && sql != config['query']
        next [] unless sql == config['query']
        table = tables[polls.size - 1]
        table.respond_to?(:call) ? table.call : table
      end
    end
    instance.define_singleton_method(:sleep) do |seconds|
      next unless seconds == config['interval']
      if polls.size >= tables.size
        @running = false
      else
        polls << []
      end
    end
    @polled_instance = instance
    Timeout.timeout(10) { instance.poll(config) }
    polls
  end

  def logs(level)
    @polled_instance.log.out.logs.grep(/\[#{level}\]/)
  end

  def deletes(events)
    events.select {|tag, _| tag.include?('.delete.') }.map {|_, record| record['id'] }
  end

  def test_run_polls_replicates_inserts_and_a_deleted_middle_row
    first, second = run_polls(setting, users(1, 2, 3), users(1, 3))
    assert_equal([1, 2, 3], first.map {|_, record| record['id'] })
    assert_equal(['replicator.users.insert.id'] * 3, first.map(&:first))
    assert_equal([2], deletes(second))
  end

  # previous_id was carried over from the last row of the previous poll, so the first row of a poll was compared with
  # it, and the rows before the first row were never looked at.
  def test_deleted_first_row_is_detected
    _, second, third = run_polls(setting, users(1, 2, 3), users(2, 3), users(2, 3))
    assert_equal([1], deletes(second))
    assert_equal([], third)
  end

  def test_deleted_first_row_is_detected_with_loose_delete
    _, second = run_polls(setting('enable_loose_delete' => 1), users(1, 2, 3), users(2, 3))
    assert_equal([1], deletes(second))
  end

  # The rows after the last row were looked at only at the first row of the next poll.
  def test_deleted_last_row_is_detected_in_the_same_poll
    _, second = run_polls(setting, users(1, 2, 3), users(1, 2))
    assert_equal([3], deletes(second))
  end

  # With enable_retry, a poll that fails after some rows must not make the next poll take the rows after them as
  # deleted.
  def test_poll_that_fails_in_the_middle_does_not_delete_the_rest
    failing = -> { Enumerator.new {|y| users(1, 2, 3).each {|row| y << row }; raise Mysql2::Error, 'Lost connection to MySQL server during query' } }
    _, second, third = run_polls(setting('enable_retry' => 1), users(1, 2, 3, 4, 5), failing, users(1, 2, 3, 4, 5))
    assert_equal([], second)
    assert_equal([], third)
  end

  # A JOIN can give the same primary key twice in a row. The first row of the pair was compared with the second as
  # "the same id", which took every other row of hash_tables as deleted.
  def test_duplicate_primary_keys_do_not_delete_the_other_rows
    _, second = run_polls(setting, users(1, 2, 3), users(1, 2, 2, 3))
    assert_equal([], second)
  end

  # Deletes were found from the gaps between consecutive rows, which needed the rows in ascending order of the
  # primary key. With rows in another order, rows that are still there were sent as deleted, and inserted again later
  # in the same poll. Deletes are now the ids of hash_tables that the poll did not return.
  def test_rows_out_of_order_are_not_deleted_and_a_deleted_row_is
    unordered = setting('query' => 'SELECT id, name FROM users')
    _, second, third, fourth = run_polls(unordered, users(1, 2, 3, 4, 5), users(1, 5, 3, 4, 2), users(4, 1, 5, 3), users(4, 1, 5, 3))
    assert_equal([], second)
    assert_equal([['replicator.users.delete.id', {'id' => 2}]], third)
    assert_equal([], fourth)
    assert_empty(logs('warn'))
  end

  # With enable_retry, a poll that fails after some rows must not delete the rows after them. When the rows came in
  # ascending order, the deletes before the failure are still sent, so that a setting that fails at the same row on
  # every poll still replicates them.
  def test_poll_that_fails_in_the_middle_sends_the_deletes_before_the_failure
    failing = -> { Enumerator.new {|y| users(1, 3).each {|row| y << row }; raise Mysql2::Error, 'Lost connection to MySQL server during query' } }
    _, second = run_polls(setting('enable_retry' => 1), users(1, 2, 3, 4, 5), failing)
    assert_equal([2], deletes(second))
  end

  # Rows that are not in order give no bound for the rows not seen yet, so a failed poll deletes nothing.
  def test_poll_with_rows_out_of_order_that_fails_deletes_nothing
    failing = -> { Enumerator.new {|y| users(3, 1).each {|row| y << row }; raise Mysql2::Error, 'Lost connection to MySQL server during query' } }
    _, second = run_polls(setting('enable_retry' => 1), users(1, 2, 3, 4, 5), failing)
    assert_equal([], second)
  end

  # One query on hash_tables for each poll finds the deletes, however sparse the ids are. The gaps between
  # consecutive ids each sent a query before.
  def test_deletes_are_found_with_one_query_for_each_poll
    hash_tables = FakeHashTables.new
    queries = []
    hash_tables.define_singleton_method(:call) do |sql|
      queries << sql if sql.include?('SELECT SQL_NO_CACHE setting_query_pk')
      super(sql)
    end
    _, second = run_polls(setting, users(1, 10, 20, 30, 40), users(1, 10, 30, 40), hash_tables: hash_tables)
    assert_equal([20], deletes(second))
    assert_equal(2, queries.size)
  end

  # enable_loose_delete sent the ids in each gap between consecutive rows as deleted, without looking at hash_tables,
  # including ids that never existed, on every poll. One query on hash_tables now finds the deletes, so it has no
  # effect.
  def test_loose_delete_sends_no_ids_that_are_not_in_hash_tables
    _, second = run_polls(setting('enable_loose_delete' => 1), users(1, 5), users(1, 5))
    assert_equal([], second)
  end

  # The ids of a poll are kept as ranges of consecutive ids, in any order, with duplicates.
  def test_seen_ids
    seen = Fluent::Plugin::MysqlReplicatorMultiInput::SeenIds.new
    [5, 6, 7, 7, 10, 2, 3, 4, 20, 1, 6, 15].each {|id| seen << id }
    seen.finish
    assert_equal([1, 2, 3, 4, 5, 6, 7, 10, 15, 20], (0..21).select {|id| seen.include?(id) })
    ascending = Fluent::Plugin::MysqlReplicatorMultiInput::SeenIds.new
    (1..1000).each {|id| ascending << id }
    ascending << 2000
    assert_equal([[1, 2000], [1000, 2000], []], %i[@starts @ends @others].map {|name| ascending.instance_variable_get(name) })
  end

  # A failure of the manager database while the deletes are found or written must not stop the poller.
  def test_failure_to_write_the_deletes_does_not_stop_polling
    hash_tables = FakeHashTables.new
    failing = false
    hash_tables.define_singleton_method(:call) do |sql|
      raise Mysql2::Error, 'Lost connection to MySQL server during query' if failing && sql.start_with?('DELETE')
      super(sql)
    end
    second = -> { failing = true; users(1, 3) }
    third = -> { failing = false; users(1, 3) }
    polls = run_polls(setting, users(1, 2, 3), second, third, hash_tables: hash_tables)
    assert_equal([[2], [2]], polls[1..2].map {|events| deletes(events) })
    assert_false(hash_tables.rows.has_key?(['users', 2]))
    assert_equal(1, logs('error').grep(/failed to detect or remove the deleted rows/).size)
  end

  # One DELETE for a large number of ids could be larger than max_allowed_packet.
  def test_many_deletes_are_written_in_batches
    hash_tables = FakeHashTables.new
    statements = []
    hash_tables.define_singleton_method(:call) do |sql|
      statements << sql if sql.start_with?('DELETE')
      super(sql)
    end
    ids = (1..1500).to_a
    _, second = run_polls(setting, users(*ids), users(1), hash_tables: hash_tables)
    assert_equal(1499, deletes(second).size)
    assert_equal([1000, 499], statements.map {|sql| sql[/IN\(([^)]*)\)/, 1].split(',').size })
    assert_equal([['users', 1]], hash_tables.rows.keys)
  end

  # The hash was taken from row.flatten.join, which writes nil and "" the same way and has no separator between the
  # columns, so these changes were not updates.
  def test_change_between_null_and_empty_string_is_an_update
    _, second = run_polls(setting, [{'id' => 1, 'name' => nil}], [{'id' => 1, 'name' => ''}])
    assert_equal([['replicator.users.update.id', {'id' => 1, 'name' => ''}]], second)
  end

  def test_change_that_moves_characters_between_columns_is_an_update
    _, second = run_polls(setting, [{'id' => 1, 'a' => 'xb', 'b' => ''}], [{'id' => 1, 'a' => 'x', 'b' => 'b'}])
    assert_equal([['replicator.users.update.id', {'id' => 1, 'a' => 'x', 'b' => 'b'}]], second)
  end

  # hash_tables keeps the hashes of 1.4.x after an upgrade. A row whose stored hash is its old hash did not change, so
  # the new hash is stored without sending it, instead of sending every row as an update once.
  def test_hash_stored_by_an_older_version_is_replaced_without_sending_the_row
    hash_tables = FakeHashTables.new
    hash_tables.rows[['users', 1]] = Digest::SHA1.hexdigest(users(1).first.flatten.join)
    hash_tables.rows[['users', 2]] = Digest::SHA1.hexdigest({'id' => 2, 'name' => 'old'}.flatten.join)
    first, second, third = run_polls(setting, users(1, 2), users(1, 2), [{'id' => 1, 'name' => 'new'}, users(2).first], hash_tables: hash_tables)
    assert_equal([['replicator.users.update.id', {'id' => 2, 'name' => 'user2'}]], first)
    assert_equal([], second)
    assert_equal([['replicator.users.update.id', {'id' => 1, 'name' => 'new'}]], third)
    assert_equal(Digest::SHA1.hexdigest(Marshal.dump({'id' => 1, 'name' => 'new'})), hash_tables.rows[['users', 1]])
  end

  # A LEFT JOIN, for example, can give a row whose primary key is NULL. It is skipped, and the rows around it are
  # still compared with each other, so a row deleted next to it is detected.
  def test_row_with_null_primary_key_is_skipped_and_deletes_around_it_are_detected
    _, second = run_polls(setting, users(1, 2, 3), users(1) + [{'id' => nil, 'name' => 'x'}] + users(3))
    assert_equal([['replicator.users.delete.id', {'id' => 2}]], second)
  end

  # One line for each poll, not for each row, as a LEFT JOIN can give many such rows on every poll.
  def test_rows_without_the_primary_key_are_logged_once_for_each_poll
    table = [{'id' => nil, 'name' => 'x'}] + users(1) + [{'id' => nil, 'name' => 'y'}]
    run_polls(setting, table, table)
    skipped = logs('error').grep(/skipped/)
    assert_equal(2, skipped.size)
    assert_match(/mysql_replicator_multi: skipped 2 rows without the primary key\. :setting_name=>users :primary_key=>id$/, skipped.first)
  end

  def nested_queries_for(template)
    queries = []
    row = {'id' => 1, 'name' => "O'Brien", 'cond' => "owner = 'alice'", 'items' => template}
    run_polls(setting, [row], origin: ->(sql) { queries << sql; [] })
    queries.grep(/FROM item/)
  end

  # A value with a quote broke a nested query, which ended the poller (or failed every poll with enable_retry).
  def test_value_in_a_quoted_placeholder_is_escaped
    assert_equal(["SELECT * FROM item WHERE owner = 'O\\'Brien'"], nested_queries_for("SELECT * FROM item WHERE owner = '${name}'"))
  end

  # A placeholder outside quotes is put in as it is, so that a column can hold a part of the SQL, as on master.
  def test_value_in_an_unquoted_placeholder_is_put_in_as_it_is
    assert_equal(["SELECT * FROM item WHERE owner = 'alice' AND parent_id = 1"], nested_queries_for('SELECT * FROM item WHERE ${cond} AND parent_id = ${id}'))
  end

  # A nested query with an error in its SQL ended the poller, or failed every poll at the same row with enable_retry.
  # The row is held back for the poll: it is neither sent nor taken as deleted, and the other rows go on.
  def test_nested_query_with_an_error_in_its_sql_holds_back_the_row
    template = 'SELECT title FROM item WHERE ${cond}'
    rows = ->(bad) { (1..3).map {|id| {'id' => id, 'cond' => id == bad ? "owner = 'O'Brien'" : "owner = 'u#{id}'", 'items' => template} } }
    origin = lambda do |sql|
      raise Mysql2::Error.new("You have an error in your SQL syntax; near 'Brien''", nil, 1064, '42000') if sql.include?("'O'Brien'")
      [{'title' => 't'}]
    end
    first, second = run_polls(setting, rows.call(nil), rows.call(2), origin: origin)
    assert_equal(['insert'] * 3, first.map {|tag, _| tag.split('.')[2] })
    assert_equal([], second)
    held_back = logs('error').grep(/held back/)
    assert_equal(1, held_back.size)
    assert_match(/mysql_replicator_multi: held back 1 rows in this poll, as the nested query of column 'items' failed with MySQL error 1064 \(SQLSTATE 42000\)\. :setting_name=>users$/, held_back.first)
    assert_empty(@polled_instance.log.out.logs.grep(/Brien/))
  end

  # Starts the plugin with real threads, a fake manager database with the given settings, and fake source databases.
  # Returns the instance, the manager connections it opened, and a queue that gets each poll's query.
  def start_with_settings(settings)
    instance = create_driver(CONFIG).instance
    hash_tables = FakeHashTables.new
    managers = []
    instance.define_singleton_method(:get_manager_connection) do
      FakeMysqlClient.new do |sql|
        case sql
        when /FROM settings/ then settings
        when /\ASET SESSION/ then []
        else hash_tables.call(sql)
        end
      end.tap {|c| managers << c }
    end
    polled = Queue.new
    instance.define_singleton_method(:get_origin_connection) do |config, _reconnect = true|
      FakeMysqlClient.new {|sql| polled << sql if sql == config['query']; users(1) }
    end
    instance.define_singleton_method(:emit_record) {|_tag, _record| }
    instance.start
    [instance, managers, polled]
  end

  def test_get_settings_closes_its_connection
    instance, managers, polled = start_with_settings([setting])
    begin
      Timeout.timeout(10) { polled.pop }
      settings_connection = managers.find {|c| c.queries.any? {|q| q.include?('FROM settings') } }
      assert_true(settings_connection.closed?)
      assert_false(instance.instance_variable_get(:@manager_db).closed?)
    ensure
      instance.stop
      instance.shutdown
    end
  end

  # A failed flush, such as a timeout of the manager database, is logged, and the buffer is flushed again later.
  def test_hash_table_flusher_survives_a_failed_flush
    inserts = 0
    instance = nil
    instance, manager = instance_with_manager(CONFIG + "bulk_insert_timeout 0\n") do |sql|
      next [] unless sql.start_with?('INSERT')
      inserts += 1
      raise Mysql2::Error, 'Lost connection to MySQL server during query' if inserts == 1
      instance.instance_variable_set(:@running, false)
      []
    end
    instance.instance_variable_set(:@manager_db, manager)
    instance.instance_variable_set(:@mutex, Mutex.new)
    instance.instance_variable_set(:@running, true)
    instance.instance_variable_set(:@hash_table_bulk_insert, ["('setting','1','hash')"])
    instance.instance_variable_set(:@hash_table_bulk_insert_last_time, Time.now - 60)
    assert_nothing_raised { Timeout.timeout(10) { instance.hash_table_flusher } }
    assert_equal(2, inserts)
    assert_empty(instance.instance_variable_get(:@hash_table_bulk_insert))
  end

  # A row that hash_tables cannot hold, such as a primary key out of the range of INT, failed every flush, so the rows
  # of every setting stayed out of hash_tables and were sent as inserts again on every poll. The other rows are
  # written, and that one is dropped.
  def test_row_that_hash_tables_cannot_hold_does_not_block_the_others
    written = []
    instance, manager = instance_with_manager(CONFIG) do |sql|
      next [] unless sql.start_with?('INSERT')
      values = sql.scan(/\('([^']*)','([^']*)','([^']*)'\)/)
      if values.any? {|_, pk, _| pk.to_i > 2147483647 }
        raise Mysql2::Error.new("Out of range value for column 'setting_query_pk' at row 1", nil, 1264, '22003')
      end
      written.concat(values.map {|name, pk, _| [name, pk] })
      []
    end
    instance.instance_variable_set(:@manager_db, manager)
    instance.instance_variable_set(:@hash_table_bulk_insert, ["('users','1','h')", "('big','3000000000','h')", "('users','2','h')"])
    instance.flush_hash_table
    assert_equal([['users', '1'], ['users', '2']], written)
    assert_empty(instance.instance_variable_get(:@hash_table_bulk_insert))
    errors = instance.log.out.logs.grep(/\[error\]/)
    assert_equal(1, errors.grep(/dropped 1 rows that hash_tables cannot hold, with MySQL error 1264 \(SQLSTATE 22003\)/).size)
    assert_empty(errors.grep(/3000000000/))
  end

  # A primary key such as a date or '12abc' in the INT column is "Data truncated" (1265) in strict mode.
  def test_primary_key_truncated_by_hash_tables_does_not_block_the_others
    written = []
    instance, manager = instance_with_manager(CONFIG) do |sql|
      next [] unless sql.start_with?('INSERT')
      values = sql.scan(/\('([^']*)','([^']*)','([^']*)'\)/)
      raise Mysql2::Error.new("Data truncated for column 'setting_query_pk' at row 1", nil, 1265, '01000') if values.any? {|_, pk, _| pk.include?('-') }
      written.concat(values.map {|name, pk, _| [name, pk] })
      []
    end
    instance.instance_variable_set(:@manager_db, manager)
    instance.instance_variable_set(:@hash_table_bulk_insert, ["('users','1','h')", "('days','2026-11-01','h')"])
    instance.flush_hash_table
    assert_equal([['users', '1']], written)
    assert_empty(instance.instance_variable_get(:@hash_table_bulk_insert))
  end

  # A failure of another kind, such as a lost connection while the rows are written one by one, keeps the buffer.
  def test_lost_connection_while_writing_rows_one_by_one_keeps_the_buffer
    inserts = 0
    instance, manager = instance_with_manager(CONFIG) do |sql|
      next [] unless sql.start_with?('INSERT')
      inserts += 1
      raise Mysql2::Error.new("Out of range value", nil, 1264, '22003') if inserts == 1
      raise Mysql2::Error.new("Lost connection to MySQL server during query", nil, 2013, 'HY000')
    end
    instance.instance_variable_set(:@manager_db, manager)
    instance.instance_variable_set(:@hash_table_bulk_insert, ["('users','1','h')"])
    assert_raise(Mysql2::Error) { instance.flush_hash_table }
    assert_equal(["('users','1','h')"], instance.instance_variable_get(:@hash_table_bulk_insert))
  end

  # A poller can add to the hash table buffer before the flusher thread has run at all.
  def test_hash_table_buffer_is_ready_before_any_thread_runs
    instance, _ = instance_with_manager { [] }
    instance.define_singleton_method(:thread_create) {|*_args, &_block| Thread.new {} }
    instance.start
    begin
      assert_nothing_raised { instance.add_hash_table_buffer('setting', 1, 'hash') }
    ensure
      instance.stop
      instance.shutdown
    end
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
    instance.define_singleton_method(:emit_deletes_safely) {|*_args| }
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
  # skipped with one line, whether enable_retry is set or not, without deletes.
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
    instance.define_singleton_method(:emit_deletes_safely) {|_config, seen_ids, _upto = nil| compared << (1..3).count {|id| seen_ids.include?(id) } }
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
    # The deletes of the first and the third poll, and none of the skipped one.
    assert_equal([3, 3], compared)
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
