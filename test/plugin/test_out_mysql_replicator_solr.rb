require 'helper'
require 'fluent/test/driver/output'
require 'webmock/test_unit'

WebMock.disable_net_connect!

class MysqlReplicatorSolrOutput < Test::Unit::TestCase

  def setup
    Fluent::Test.setup
  end

  def teardown
    WebMock.reset!
  end

  CONFIG = %[
    host       localhost
    port       8983
    tag_format (?<core_name>[^\.]+)\.(?<event>[^\.]+)\.(?<primary_key>[^\.]+)$
  ]

  def create_driver(conf=CONFIG)
    Fluent::Test::Driver::Output.new(Fluent::Plugin::MysqlReplicatorSolrOutput).configure(conf)
  end

  def test_configure
    d = create_driver(%[])
    assert_equal 'localhost', d.instance.host
    assert_equal 8983, d.instance.port
  end

  # Collects the bodies posted to the update handler of each core.
  def stub_solr
    @updates = Hash.new {|h, k| h[k] = [] }
    stub_request(:any, %r{\Ahttp://localhost:8983/solr/}).to_return do |req|
      @updates[req.uri.path.split('/')[2]] << req.body
      {:status => 200, :headers => {'Content-Type' => 'application/json'}, :body => '{"responseHeader":{"status":0}}'}
    end
  end

  def test_adds_and_commits_documents
    stub_solr
    d = create_driver
    d.run(default_tag: 'mycore.insert.id') do
      d.feed({'id' => 1, 'name' => 'a'})
    end
    assert_equal([[{'id' => 1, 'name' => 'a'}], {'commit' => {}}], @updates['mycore'].map {|body| JSON.parse(body) })
  end

  def test_deletes_by_id
    stub_solr
    d = create_driver
    d.run(default_tag: 'mycore.delete.id') do
      d.feed({'id' => 7})
    end
    assert_equal([{'delete' => 7}, {'commit' => {}}], @updates['mycore'].map {|body| JSON.parse(body) })
  end

  def test_escapes_the_core_name
    stub_solr
    d = create_driver(%[
      tag_format (?<core_name>[^.]+)\\.(?<event>[^.]+)\\.(?<primary_key>[^.]+)$
    ])
    d.run(default_tag: 'my core.insert.id') do
      d.feed({'id' => 1})
    end
    assert_requested(:post, %r{\Ahttp://localhost:8983/solr/my%20core/update}, :at_least_times => 1)
  end
end
