require 'helper'
require 'fluent/test/driver/output'
require 'webmock/test_unit'
require 'tempfile'

WebMock.disable_net_connect!

class MysqlReplicatorElasticsearchOutput < Test::Unit::TestCase
  attr_accessor :index_cmds, :content_type

  def setup
    Fluent::Test.setup
    @driver = nil
    @tag = 'myindex.mytype.insert.id'
  end

  def teardown
    WebMock.reset!
    (@tmpfiles || []).each {|f| f.close! rescue nil }
  end

  def write_template_file(body = '{"index_patterns":["myindex-*"],"mappings":{"properties":{"loc":{"type":"geo_point"}}}}')
    file = Tempfile.new(['tmpl', '.json'])
    file.write(body)
    file.flush
    (@tmpfiles ||= []) << file
    file.path
  end

  def driver(conf='')
    @driver ||= Fluent::Test::Driver::Output.new(Fluent::Plugin::MysqlReplicatorElasticsearchOutput).configure(conf)
  end

  def sample_record
    {'age' => 26, 'request_id' => '42'}
  end

  # The plugin detects the Elasticsearch version on the first write via GET /,
  # so stub that endpoint (defaulting to 6.x, which keeps "_type").
  def stub_elastic_version(url, version="6.8.23")
    stub_request(:get, url).to_return(
      :status => 200,
      :headers => {"Content-Type" => "application/json"},
      :body => %({"version":{"number":"#{version}"}})
    )
  end

  def stub_elastic(url="http://localhost:9200/_bulk")
    stub_elastic_version(url.sub('/_bulk', '/'))
    stub_request(:post, url).with do |req|
      @content_type = req.headers["Content-Type"]
      @index_cmds = req.body.split("\n").map {|r| JSON.parse(r) }
    end
  end

  def stub_elastic_unavailable(url="http://localhost:9200/_bulk")
    stub_elastic_version(url.sub('/_bulk', '/'))
    stub_request(:post, url).to_return(:status => [503, "Service Unavailable"])
  end

  def test_wrties_with_proper_content_type
    stub_elastic
    driver.run(default_tag: @tag) do
      driver.feed(sample_record)
    end
    assert_equal("application/json; charset=utf-8", @content_type)
  end

  def test_writes_to_speficied_index
    driver.configure("index_name myindex\n")
    stub_elastic
    driver.run(default_tag: @tag) do
      driver.feed(sample_record)
    end
    assert_equal('myindex', index_cmds.first['index']['_index'])
  end

  def test_expands_strftime_tokens_in_index_name
    stub_elastic
    time = Time.utc(2018, 8, 31, 12, 0, 0).to_i
    driver.run(default_tag: 'myindex-%Y%m%d.mytype.insert.id') do
      driver.feed(time, sample_record)
    end
    expected = "myindex-#{Time.at(time).strftime('%Y%m%d')}"
    assert_equal(expected, index_cmds.first['index']['_index'])
  end

  def test_index_name_without_token_is_unchanged
    stub_elastic
    driver.run(default_tag: 'plainindex.mytype.insert.id') do
      driver.feed(sample_record)
    end
    assert_equal('plainindex', index_cmds.first['index']['_index'])
  end

  def test_composite_primary_key_builds_joined_id
    stub_elastic
    driver.run(default_tag: 'myindex.mytype.insert.tenant_id,id') do
      driver.feed({'tenant_id' => 10, 'id' => 7, 'text' => 'x'})
    end
    assert_equal('10,7', index_cmds.first['index']['_id'])
  end

  def test_writes_to_speficied_type
    driver.configure("type_name mytype\n")
    stub_elastic
    driver.run(default_tag: @tag) do
      driver.feed(sample_record)
    end
    assert_equal('mytype', index_cmds.first['index']['_type'])
  end

  def test_auto_detects_es8_and_omits_type
    stub_elastic
    # Override the version endpoint to report Elasticsearch 8.x.
    stub_elastic_version("http://localhost:9200/", "8.18.0")
    driver.run(default_tag: @tag) do
      driver.feed(sample_record)
    end
    assert(!index_cmds.first['index'].has_key?('_type'))
  end

  def test_writes_to_speficied_host
    driver.configure("host 192.168.33.50\n")
    elastic_request = stub_elastic("http://192.168.33.50:9200/_bulk")
    driver.run(default_tag: @tag) do
      driver.feed(sample_record)
    end
    assert_requested(elastic_request)
  end

  def test_writes_to_speficied_port
    driver.configure("port 9201\n")
    elastic_request = stub_elastic("http://localhost:9201/_bulk")
    driver.run(default_tag: @tag) do
      driver.feed(sample_record)
    end
    assert_requested(elastic_request)
  end

  def test_makes_bulk_request
    stub_elastic
    driver.run(default_tag: @tag) do
      driver.feed(sample_record)
      driver.feed(sample_record.merge('age' => 27))
    end
    assert_equal(4, index_cmds.count)
  end

  def test_all_records_are_preserved_in_bulk
    stub_elastic
    driver.run(default_tag: @tag) do
      driver.feed(sample_record)
      driver.feed(sample_record.merge('age' => 27))
    end
    assert_equal(26, index_cmds[1]['age'])
    assert_equal(27, index_cmds[3]['age'])
  end


  def test_doesnt_add_logstash_timestamp_by_default
    stub_elastic
    driver.run(default_tag: @tag) do
      driver.feed(sample_record)
    end
    assert_nil(index_cmds[1]['@timestamp'])
  end


  def test_doesnt_add_tag_key_by_default
    stub_elastic
    driver.run(default_tag: @tag) do
      driver.feed(sample_record)
    end
    assert_nil(index_cmds[1]['tag'])
  end

  def test_doesnt_add_id_key_if_missing_when_configured
    driver.configure("id_key another_request_id\n")
    stub_elastic
    driver.run(default_tag: @tag) do
      driver.feed(sample_record)
    end
    assert(!index_cmds[0]['index'].has_key?('_id'))
  end

  def test_adds_id_key_when_not_configured
    stub_elastic
    driver.run(default_tag: @tag) do
      driver.feed(sample_record)
    end
    assert(!index_cmds[0]['index'].has_key?('_id'))
  end

  def test_request_error
    stub_elastic_unavailable
    assert_raise(Net::HTTPFatalError) {
      driver.run(default_tag: @tag) do
        driver.feed(sample_record)
      end
    }
  end

  def test_installs_legacy_template_by_default
    stub_elastic # version 6.8.23
    stub_request(:get, "http://localhost:9200/_template/my_tmpl").to_return(:status => 404)
    put_tmpl = stub_request(:put, "http://localhost:9200/_template/my_tmpl").to_return(:status => 200, :body => "{}")
    driver.configure("template_name my_tmpl\ntemplate_file #{write_template_file}\n")
    driver.run(default_tag: @tag) { driver.feed(sample_record) }
    assert_requested(put_tmpl)
  end

  def test_installs_composable_template_when_legacy_disabled
    stub_elastic
    stub_elastic_version("http://localhost:9200/", "8.18.0")
    stub_request(:get, "http://localhost:9200/_index_template/my_tmpl").to_return(:status => 404)
    put_tmpl = stub_request(:put, "http://localhost:9200/_index_template/my_tmpl").to_return(:status => 200, :body => "{}")
    driver.configure("template_name my_tmpl\ntemplate_file #{write_template_file}\nuse_legacy_template false\n")
    driver.run(default_tag: @tag) { driver.feed(sample_record) }
    assert_requested(put_tmpl)
  end

  def test_skips_composable_template_on_old_elasticsearch
    stub_elastic # version 6.8.23 (< 7.8)
    put_tmpl = stub_request(:put, "http://localhost:9200/_index_template/my_tmpl")
    driver.configure("template_name my_tmpl\ntemplate_file #{write_template_file}\nuse_legacy_template false\n")
    driver.run(default_tag: @tag) { driver.feed(sample_record) }
    assert_not_requested(put_tmpl)
  end

  def test_skips_template_when_it_exists_and_no_overwrite
    stub_elastic
    stub_request(:get, "http://localhost:9200/_template/my_tmpl").to_return(:status => 200, :body => "{}")
    put_tmpl = stub_request(:put, "http://localhost:9200/_template/my_tmpl")
    driver.configure("template_name my_tmpl\ntemplate_file #{write_template_file}\n")
    driver.run(default_tag: @tag) { driver.feed(sample_record) }
    assert_not_requested(put_tmpl)
  end

  def test_template_name_without_file_raises
    assert_raise(Fluent::ConfigError) do
      driver.configure("template_name my_tmpl\n")
    end
  end

  def test_writes_to_https_host
    driver.configure("ssl true\n")
    elastic_request = stub_elastic("https://localhost:9200/_bulk")
    driver.run(default_tag: @tag) do
      driver.feed(sample_record)
    end
    assert_requested(elastic_request)
  end

  def test_writes_to_http_basic_auth
    driver.configure(%[
      username foo\n
      password bar\n
    ])
    elastic_request = stub_elastic("http://foo:bar@localhost:9200/_bulk")
    driver.run(default_tag: @tag) do
      driver.feed(sample_record)
    end
    assert_requested(elastic_request)
  end

  def test_writes_to_http_basic_auth_failed
    driver.configure(%[
      username wront_user\n
      password bar\n
    ])
    elastic_request = stub_elastic("http://foo:bar@localhost:9200/_bulk")
    assert_raise(WebMock::NetConnectNotAllowedError) {
      driver.run(default_tag: @tag) do
        driver.feed(sample_record)
      end
    }
  end
end
