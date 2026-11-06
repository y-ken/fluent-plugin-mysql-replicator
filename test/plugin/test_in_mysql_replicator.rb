require 'helper'
require 'fluent/test/driver/input'
require 'fake_mysql_client'
require 'timeout'

class MysqlReplicatorInputTest < Test::Unit::TestCase
  def setup
    Fluent::Test.setup
  end

  CONFIG = %[
    host            localhost
    port            3306
    interval        30
    tag             input.mysql
    query           SELECT id, text from search_text
    record_hostname yes
  ]

  def create_driver(conf=CONFIG)
    Fluent::Test::Driver::Input.new(Fluent::Plugin::MysqlReplicatorInput).configure(conf)
  end

  def test_configure
    assert_raise(Fluent::ConfigError) {
      d = create_driver('')
    }
    d = create_driver %[
      host            localhost
      port            3306
      interval        30
      tag             input.mysql
      query           SELECT id, text from search_text
      enable_delete   no
      json_columns    geometry,attrs
    ]
    assert_equal 'localhost', d.instance.host
    assert_equal 3306, d.instance.port
    assert_equal 30, d.instance.interval
    assert_equal 'input.mysql', d.instance.tag
    assert_equal false, d.instance.enable_delete
    assert_equal ['geometry', 'attrs'], d.instance.json_columns
  end

  def test_json_columns_defaults_to_empty
    d = create_driver
    assert_equal [], d.instance.json_columns
  end

  def test_parse_json_columns
    d = create_driver
    row = {
      'id'       => 1,
      'geometry' => '{"type":"Polygon","coordinates":[[136.8,35.1]]}',
      'tags'     => '[1,2,3]',
      'broken'   => 'not json {',
      'plain'    => 'hello',
      'number'   => 5,
    }
    d.instance.parse_json_columns!(row, ['geometry', 'tags', 'broken', 'number', 'missing'])

    assert_equal({'type' => 'Polygon', 'coordinates' => [[136.8, 35.1]]}, row['geometry'])
    assert_equal([1, 2, 3], row['tags'])
    assert_equal('not json {', row['broken'])  # malformed JSON stays as the original string
    assert_equal(5, row['number'])             # non-string values are untouched
    assert_equal('hello', row['plain'])        # columns not listed are untouched
  end

  def test_parse_json_columns_noop_when_empty
    d = create_driver
    row = {'geometry' => '{"a":1}'}
    d.instance.parse_json_columns!(row, [])
    assert_equal('{"a":1}', row['geometry'])
  end

  # --- #42: delete detection must not build an integer Range from primary keys ---

  def deleted_ids(previous_ids, current_ids)
    conf = %[
      tag   input.mysql
      query SELECT id, text from search_test
    ]
    create_driver(conf).instance.detect_deleted_ids(previous_ids, current_ids)
  end

  def test_detect_deleted_ids_first_poll_reports_no_deletes
    assert_equal [], deleted_ids([], [1, 2, 3])
  end

  def test_detect_deleted_ids_first_poll_with_string_keys_does_not_raise
    # Regression for #42: the old `[*1...'c']` raised "bad value for range".
    assert_nothing_raised do
      assert_equal [], deleted_ids([], %w[a b c])
    end
  end

  def test_detect_deleted_ids_first_poll_with_sparse_ids_has_no_phantom_deletes
    # The old code returned `[*1...99] - [1, 50, 99]`, emitting deletes for ids
    # that never existed. The first poll must only establish a baseline.
    assert_equal [], deleted_ids([], [1, 50, 99])
  end

  def test_detect_deleted_ids_diffs_against_previous_snapshot
    assert_equal [2], deleted_ids([1, 2, 3], [1, 3])
  end

  def test_detect_deleted_ids_empty_current_does_not_mass_delete
    assert_equal [], deleted_ids([1, 2, 3], [])
  end

  # --- #4: a nested sub-query fires only for a SELECT template with ${...} ---

  def nested?(value)
    conf = %[
      tag   input.mysql
      query SELECT id, text from search_test
    ]
    create_driver(conf).instance.nested_query_value?(value)
  end

  def test_nested_query_value_true_for_select_with_placeholder
    assert_true nested?("SELECT * FROM child WHERE parent_id = ${id}")
  end

  def test_nested_query_value_false_for_plain_text_starting_with_select
    # Regression for #4: a data value beginning with "SELECT" must not run as SQL.
    assert_false nested?("SELECT YOUR PLAN")
  end

  def test_nested_query_value_false_for_word_select
    assert_false nested?("Selecting the best option")
  end

  def test_nested_query_value_false_for_select_without_placeholder
    assert_false nested?("select count(*) from search_test")
  end

  def test_nested_query_value_false_for_non_string_values
    assert_false nested?(12345)
    assert_false nested?(nil)
  end

  # --- #7: composite primary key support ---

  def composite_driver
    create_driver(%[
      tag         input.mysql
      query       SELECT tenant_id, id, text from t
      primary_key tenant_id,id
    ])
  end

  def test_primary_key_defaults_to_id_array
    assert_equal ['id'], create_driver.instance.primary_key
  end

  def test_primary_key_parses_composite_list
    assert_equal ['tenant_id', 'id'], composite_driver.instance.primary_key
  end

  def test_extract_id_single_key_is_one_element_array
    assert_equal [7], create_driver.instance.extract_id({'id' => 7, 'text' => 'x'})
  end

  def test_extract_id_returns_composite_values
    assert_equal [10, 7], composite_driver.instance.extract_id({'tenant_id' => 10, 'id' => 7, 'text' => 'x'})
  end

  # --- polling, with fake MySQL connections ---

  # Returns the plugin instance, the events it emits as [tag, record], and the fake connections it opens. Each
  # connection answers a query with the block, which receives the SQL.
  def polling_instance(conf, &responder)
    instance = create_driver(conf).instance
    events = []
    clients = []
    instance.define_singleton_method(:get_connection) {|_session = false| FakeMysqlClient.new(&responder).tap {|c| clients << c } }
    instance.define_singleton_method(:emit_record) {|tag, record| events << [tag, record] }
    instance.instance_variable_set(:@table_hash, {})
    instance.instance_variable_set(:@ids, [])
    [instance, events, clients]
  end

  # query() retries a failed SQL forever, so a poll that goes wrong would hang the test.
  def poll_once(instance)
    Timeout.timeout(10) { instance.poll_once }
  end

  NESTED_CONFIG = %[
    tag   input.mysql.${event}.${primary_key}
    query SELECT id, "SELECT name FROM item WHERE parent_id = ${id}" AS items FROM parent
  ]

  def test_nested_query_gets_the_value_of_its_placeholder
    instance, events, clients = polling_instance(NESTED_CONFIG) do |sql|
      case sql
      when /FROM parent/ then [{'id' => 7, 'items' => 'SELECT name FROM item WHERE parent_id = ${id}'}]
      when /FROM item WHERE parent_id = 7\z/ then [{'name' => 'a'}, {'name' => 'b'}]
      else raise Mysql2::Error, "unexpected query: #{sql}"
      end
    end
    poll_once(instance)
    assert_equal([['input.mysql.insert.id', {'id' => 7, 'items' => [{'name' => 'a'}, {'name' => 'b'}]}]], events)
    assert_equal(['SELECT name FROM item WHERE parent_id = 7'], clients.flat_map(&:queries).grep(/\ASELECT name/))
  end

  # prepared_query sets up the session that the nested queries run in, such as a temporary table.
  def test_nested_queries_run_in_the_session_of_prepared_query_on_every_poll
    conf = %[
      tag            input.mysql.${event}.${primary_key}
      prepared_query CREATE TEMPORARY TABLE tmp_item AS SELECT * FROM item
      query          SELECT id, "SELECT name FROM tmp_item WHERE parent_id = ${id}" AS items FROM parent
    ]
    instance, events, clients = polling_instance(conf) do |sql|
      case sql
      when /FROM parent/ then [{'id' => 1, 'items' => 'SELECT name FROM tmp_item WHERE parent_id = ${id}'},
                               {'id' => 2, 'items' => 'SELECT name FROM tmp_item WHERE parent_id = ${id}'}]
      when /\ASELECT name/ then [{'name' => 'n'}]
      end
    end
    2.times { poll_once(instance) }
    # A new session for each poll, as a session cannot create the same temporary table again.
    sessions = clients.select {|c| c.queries.any? {|q| q.start_with?('CREATE') } }
    assert_equal(2, sessions.size, clients.map(&:queries).inspect)
    sessions.each do |session|
      assert_equal(['CREATE', 'SELECT', 'SELECT'], session.queries.map {|q| q[/\A\w+/] })
      assert_true(session.closed?)
    end
    assert_equal(2, events.size)
  end

  # A SELECT in prepared_query, such as one that sets a user variable, leaves its rows to be read on a connection that
  # streams its results. They were not read, so the connection was out of sync, and each nested query ran on a new
  # connection without the session (and the old one was not closed).
  def test_prepared_query_with_a_select_keeps_its_session
    conf = %[
      tag            input.mysql.${event}.${primary_key}
      prepared_query SELECT @flag := 1
      query          SELECT id, "SELECT name, @flag AS flag FROM item WHERE parent_id = ${id}" AS items FROM parent
    ]
    instance, events, clients = polling_instance(conf) do |sql|
      case sql
      when /FROM parent/ then [{'id' => 1, 'items' => 'SELECT name, @flag AS flag FROM item WHERE parent_id = ${id}'}]
      when /\ASELECT @flag/ then [{'@flag := 1' => 1}]
      when /\ASELECT name/ then [{'name' => 'n', 'flag' => 1}]
      end
    end
    poll_once(instance)
    session = clients.find {|c| c.queries.first.start_with?('SELECT @flag') }
    assert_equal(['SELECT @flag := 1', 'SELECT name, @flag AS flag FROM item WHERE parent_id = 1'], session.queries)
    assert_equal(2, clients.size)
    assert_equal(1, events.size)
  end

  # A CALL of a procedure that returns rows gives more than one result, all of which must be read before the next
  # query on the connection.
  def test_prepared_query_with_a_call_that_returns_rows_keeps_its_session
    conf = %[
      tag            input.mysql.${event}.${primary_key}
      prepared_query CALL p_sel()
      query          SELECT id, "SELECT name FROM item WHERE parent_id = ${id}" AS items FROM parent
    ]
    instance, events, clients = polling_instance(conf) do |sql|
      case sql
      when /FROM parent/ then [{'id' => 1, 'items' => 'SELECT name FROM item WHERE parent_id = ${id}'}]
      when /\ASELECT name/ then [{'name' => 'n'}]
      end
    end
    open_client = instance.method(:get_connection)
    instance.define_singleton_method(:get_connection) do |*args|
      open_client.call(*args).tap do |c|
        # The rows of the procedure, then its status, after the result of CALL itself.
        c.define_singleton_method(:query) do |sql|
          raise Mysql2::Error, "Commands out of sync; you can't run this command now" unless more_results.empty?
          super(sql).tap { more_results.push([{'ok' => 1}], []) if sql.start_with?('CALL') }
        end
        c.define_singleton_method(:ping) { super() && more_results.empty? }
      end
    end
    poll_once(instance)
    session = clients.find {|c| c.queries.first.start_with?('CALL') }
    assert_equal(['CALL p_sel()', 'SELECT name FROM item WHERE parent_id = 1'], session.queries)
    assert_equal(2, clients.size)
    assert_equal(1, events.size)
  end

  # A connection for the nested queries that is lost in the middle of a poll is opened again with prepared_query, and
  # the lost one is closed.
  def test_lost_connection_of_prepared_query_is_opened_again_with_its_session
    conf = %[
      tag            input.mysql.${event}.${primary_key}
      prepared_query CREATE TEMPORARY TABLE tmp_item AS SELECT * FROM item
      query          SELECT id, "SELECT name FROM tmp_item WHERE parent_id = ${id}" AS items FROM parent
    ]
    clients = nil
    lost = false
    instance, events, clients = polling_instance(conf) do |sql|
      case sql
      when /FROM parent/ then [{'id' => 1, 'items' => 'SELECT name FROM tmp_item WHERE parent_id = ${id}'},
                               {'id' => 2, 'items' => 'SELECT name FROM tmp_item WHERE parent_id = ${id}'}]
      when /\ASELECT name/
        unless lost
          lost = true
          clients.find {|c| c.queries.last == sql }.close
        end
        [{'name' => 'n'}]
      end
    end
    poll_once(instance)
    sessions = clients.select {|c| c.queries.first.start_with?('CREATE') }
    assert_equal([['CREATE', 'SELECT'], ['CREATE', 'SELECT']], sessions.map {|c| c.queries.map {|q| q[/\A\w+/] } })
    assert_true(sessions.all?(&:closed?))
    assert_equal(2, events.size)
  end

  def test_prepared_query_ending_with_a_semicolon_and_a_newline
    conf = %[
      tag            input.mysql.${event}.${primary_key}
      prepared_query SET @a = 1
      query          SELECT id FROM t
    ]
    instance, events, _ = polling_instance(conf) {|sql| sql.start_with?('SELECT') ? [{'id' => 1}] : [] }
    # A config value cannot end with a newline, but a value from a multi-line config or a script can.
    instance.instance_variable_set(:@prepared_query, "SET @a = 1;\n")
    poll_once(instance)
    assert_equal(1, events.size)
  end

  SIMPLE_CONFIG = %[
    tag   input.mysql.${event}.${primary_key}
    query SELECT id, name FROM t
  ]

  # Runs one poll per table state, and returns the events of each poll.
  def poll_tables(conf, *tables)
    table = nil
    instance, events, _ = polling_instance(conf) {|_sql| table }
    @polled_instance = instance
    tables.map do |rows|
      table = rows
      events.clear
      poll_once(instance)
      events.dup
    end
  end

  # A LEFT JOIN, for example, can give a row whose primary key is NULL. The rows after it are still in the table.
  def test_row_with_null_primary_key_does_not_make_the_rows_after_it_deleted
    rows = [{'id' => 1, 'name' => 'a'}, {'id' => 2, 'name' => 'b'}, {'id' => 3, 'name' => 'c'}]
    _, second = poll_tables(SIMPLE_CONFIG, rows, [rows[0], {'id' => nil, 'name' => 'x'}, rows[1], rows[2]])
    assert_equal([], second)
  end

  def test_change_between_null_and_empty_string_is_an_update
    conf = %[
      tag   input.mysql.${event}.${primary_key}
      query SELECT id, note FROM t
    ]
    _, second = poll_tables(conf, [{'id' => 1, 'note' => nil}], [{'id' => 1, 'note' => ''}])
    assert_equal([['input.mysql.update.id', {'id' => 1, 'note' => ''}]], second)
  end

  # The values were joined without a separator, so "xb" + "" and "x" + "b" looked the same.
  def test_change_that_moves_characters_between_columns_is_an_update
    conf = %[
      tag   input.mysql.${event}.${primary_key}
      query SELECT id, a, b FROM t
    ]
    _, second = poll_tables(conf, [{'id' => 1, 'a' => 'xb', 'b' => ''}], [{'id' => 1, 'a' => 'x', 'b' => 'b'}])
    assert_equal([['input.mysql.update.id', {'id' => 1, 'a' => 'x', 'b' => 'b'}]], second)
  end

  def test_change_in_the_rows_of_a_nested_query_is_an_update
    names = ['a']
    instance, events, _ = polling_instance(NESTED_CONFIG) do |sql|
      if sql.include?('FROM parent')
        [{'id' => 7, 'items' => 'SELECT name FROM item WHERE parent_id = ${id}'}]
      else
        names.map {|n| {'name' => n} }
      end
    end
    poll_once(instance)
    events.clear
    names = ['a', 'b']
    poll_once(instance)
    assert_equal([['input.mysql.update.id', {'id' => 7, 'items' => [{'name' => 'a'}, {'name' => 'b'}]}]], events)
  end

  def test_rows_after_a_null_primary_key_are_emitted
    rows = [{'id' => nil, 'name' => 'x'}, {'id' => 1, 'name' => 'a'}]
    first, = poll_tables(SIMPLE_CONFIG, rows)
    assert_equal([['input.mysql.insert.id', {'id' => 1, 'name' => 'a'}]], first)
  end

  # One line for each poll, not for each row, as a LEFT JOIN can give many such rows on every poll.
  def test_rows_without_the_primary_key_are_logged_once_for_each_poll
    rows = [{'id' => nil, 'name' => 'x'}, {'id' => 1, 'name' => 'a'}, {'id' => nil, 'name' => 'y'}]
    poll_tables(SIMPLE_CONFIG, rows, rows)
    skipped = @polled_instance.log.out.logs.grep(/skipped/)
    assert_equal(2, skipped.size)
    assert_match(/\[error\]: mysql_replicator: skipped 2 rows without the primary key\. :tag=>input\.mysql\.\$\{event\}\.\$\{primary_key\} :primary_key=>id$/, skipped.first)
  end

  PREPARED_CONFIG = %[
    tag            input.mysql.${event}.${primary_key}
    prepared_query CALL p_prepare()
    query          SELECT id, name FROM t
  ]

  # The message of a MySQL error can hold values of the rows.
  def prepared_error
    Mysql2::Error.new("Duplicate entry 'secret-value' for key 'PRIMARY'", nil, 1062, '23000')
  end

  # Runs one poll for each [rows, failure], and returns the events of each poll. failure is how prepared_query fails in
  # that poll: nil (it does not), :statement (its statement fails), :after_rows (a CALL fails after the rows it returned)
  # or :connect (its connection cannot be opened).
  def prepared_polls(*polls)
    table = failure = nil
    instance, events, clients = polling_instance(PREPARED_CONFIG) do |sql|
      if sql.start_with?('CALL')
        raise prepared_error if failure == :statement
        [{'ok' => 1}]
      else
        table
      end
    end
    open_client = instance.method(:get_connection)
    test = self
    instance.define_singleton_method(:get_connection) do |session = false|
      raise test.prepared_error if session && failure == :connect
      open_client.call(session).tap do |c|
        c.define_singleton_method(:next_result) do
          raise test.prepared_error if failure == :after_rows && queries.last.start_with?('CALL')
          super()
        end
      end
    end
    @polled_instance = instance
    @polled_clients = clients
    polls.map do |rows, fails|
      table, failure = rows, fails
      events.clear
      poll_once(instance)
      events.dup
    end
  end

  # A poll whose prepared_query fails sends nothing, not even deletes, and keeps the ids and hashes of the previous poll,
  # so the next poll sends what changed since then.
  data(statement: :statement, after_rows: :after_rows, connect: :connect)
  def test_poll_after_a_failed_prepared_query_sends_what_changed(failure)
    before = [{'id' => 1, 'name' => 'a'}, {'id' => 2, 'name' => 'b'}]
    after = [{'id' => 2, 'name' => 'b2'}, {'id' => 3, 'name' => 'c'}]
    first, failed, recovered = prepared_polls([before, nil], [after, failure], [after, nil])
    assert_equal(2, first.size)
    assert_equal([], failed)
    assert_equal([['input.mysql.update.id', {'id' => 2, 'name' => 'b2'}],
                  ['input.mysql.insert.id', {'id' => 3, 'name' => 'c'}],
                  ['input.mysql.delete.id', {'id' => 1}]], recovered)
    assert_true(@polled_clients.all?(&:closed?))
  end

  # One line for each poll, with the error number and the SQLSTATE but not the message, and the poll does not wait: the
  # interval (1m by default) would make it time out.
  data(statement: :statement, after_rows: :after_rows, connect: :connect)
  def test_failing_prepared_query_logs_one_line_for_each_poll(failure)
    rows = [{'id' => 1, 'name' => 'a'}]
    polls = prepared_polls([rows, nil], [rows, failure], [rows, failure], [rows, failure])
    assert_equal([[], [], []], polls.drop(1))
    logs = @polled_instance.log.out.logs.grep(/\[(warn|error)\]/)
    assert_equal(3, logs.size, logs.inspect)
    logs.each do |line|
      assert_match(/\[error\]: mysql_replicator: prepared_query failed; skipped this poll\. :tag=>input\.mysql\.\$\{event\}\.\$\{primary_key\} :errno=>1062 :sql_state=>23000$/, line)
    end
    assert_true(@polled_clients.all?(&:closed?))
  end

  # prepared_query that fails again on a connection opened again in the middle of a poll skips the rest of the poll. The
  # rows sent before it are sent again by the next poll, which compares with the poll before the failed one.
  def test_prepared_query_failing_in_the_middle_of_a_poll_keeps_the_previous_poll
    conf = %[
      tag            input.mysql.${event}.${primary_key}
      prepared_query CREATE TEMPORARY TABLE tmp_item AS SELECT * FROM item
      query          SELECT id, name, "SELECT name FROM tmp_item WHERE parent_id = ${id}" AS items FROM parent
    ]
    table = nil
    lose = false
    instance, events, clients = polling_instance(conf) do |sql|
      case sql
      when /\ACREATE/ then raise prepared_error if lose && clients.size > 4
      when /FROM parent/ then table.map {|id, name| {'id' => id, 'name' => name, 'items' => 'SELECT name FROM tmp_item WHERE parent_id = ${id}'} }
      when /\ASELECT name/
        clients.find {|c| c.queries.last == sql }.close if lose
        [{'name' => 'n'}]
      end
    end
    table = [[1, 'a'], [2, 'b']]
    poll_once(instance)
    events.clear
    table = [[1, 'a2'], [2, 'b2']]
    lose = true
    poll_once(instance)
    assert_equal([1], events.map {|_, record| record['id'] })
    assert_equal(1, instance.log.out.logs.grep(/prepared_query failed/).size)
    events.clear
    lose = false
    poll_once(instance)
    assert_equal([['input.mysql.update.id', 1], ['input.mysql.update.id', 2]], events.map {|tag, record| [tag, record['id']] })
    assert_true(clients.all?(&:closed?))
  end

  # A nested query that fails as the connection of prepared_query was lost opens it again at once, and prepared_query
  # failing there skips the poll with one line, without waiting for the interval in query() too (it would time out).
  def test_prepared_query_failing_after_a_lost_connection_waits_once
    conf = %[
      tag            input.mysql.${event}.${primary_key}
      prepared_query CREATE TEMPORARY TABLE tmp_item AS SELECT * FROM item
      query          SELECT id, "SELECT name FROM tmp_item WHERE parent_id = ${id}" AS items FROM parent
    ]
    lost = false
    instance, events, clients = polling_instance(conf) do |sql|
      case sql
      when /\ACREATE/ then raise prepared_error if lost
      when /FROM parent/ then [{'id' => 1, 'items' => 'SELECT name FROM tmp_item WHERE parent_id = ${id}'},
                               {'id' => 2, 'items' => 'SELECT name FROM tmp_item WHERE parent_id = ${id}'}]
      when /parent_id = 2/
        lost = true
        clients.find {|c| c.queries.last == sql }.close
        raise Mysql2::Error.new('Lost connection to server during query', nil, 2013, 'HY000')
      else [{'name' => 'n'}]
      end
    end
    poll_once(instance)
    assert_equal([1], events.map {|_, record| record['id'] })
    logs = instance.log.out.logs.grep(/\[(warn|error)\]/)
    assert_equal(1, logs.size, logs.inspect)
    assert_match(/prepared_query failed; skipped this poll\. .* :errno=>1062 :sql_state=>23000$/, logs.first)
    assert_true(clients.all?(&:closed?))
  end

  # Replaces Mysql2::Client.new with the block while the test runs.
  def with_client_new(impl)
    Mysql2::Client.define_singleton_method(:new, &impl)
    yield
  ensure
    Mysql2::Client.singleton_class.send(:remove_method, :new)
  end

  # The connection of prepared_query is not connected again by the client, which would lose the session, and a failure
  # to connect is raised at once instead of logged and tried again after the interval. Other connections keep both.
  def test_connection_of_prepared_query_does_not_reconnect_and_does_not_wait
    instance = create_driver(PREPARED_CONFIG).instance
    slept = []
    instance.define_singleton_method(:sleep) {|seconds| slept << seconds }
    options = []
    with_client_new(lambda {|opts| options << opts; :client }) do
      assert_equal(:client, instance.get_connection(true))
      assert_equal(:client, instance.get_connection)
    end
    assert_equal([false, true], options.map {|opts| opts[:reconnect] })
    error = Mysql2::Error.new("Access denied for user 'secret'", nil, 1045, '28000')
    with_client_new(lambda {|_opts| raise error }) do
      assert_raise(Mysql2::Error) { instance.get_connection(true) }
    end
    assert_equal([], slept)
  end
end
