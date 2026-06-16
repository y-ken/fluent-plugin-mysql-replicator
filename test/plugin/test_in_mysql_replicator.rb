require 'helper'
require 'fluent/test/driver/input'

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
    ]
    assert_equal 'localhost', d.instance.host
    assert_equal 3306, d.instance.port
    assert_equal 30, d.instance.interval
    assert_equal 'input.mysql', d.instance.tag
    assert_equal false, d.instance.enable_delete
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
end
