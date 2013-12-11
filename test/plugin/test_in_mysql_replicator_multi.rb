require 'helper'

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

  def create_driver(conf=CONFIG,tag='test')
    Fluent::Test::OutputTestDriver.new(Fluent::MysqlReplicatorMultiInput, tag).configure(conf)
  end

  def test_configure
    assert_raise(Fluent::ConfigError) {
      d = create_driver('')
    }
    d = create_driver(CONFIG)
    d.instance.inspect
    assert_equal 'localhost', d.instance.manager_host
    assert_equal 3306, d.instance.manager_port
    assert_equal 'replicator_manager', d.instance.manager_database
  end
end
