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
    instance.define_singleton_method(:get_connection) { FakeMysqlClient.new(&responder).tap {|c| clients << c } }
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
end
