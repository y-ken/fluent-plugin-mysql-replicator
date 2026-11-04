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
      @index_cmds = req.body.split("\n").map {|r| JSON.parse(r, max_nesting: false) }
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

  # Runs the block and returns the Ruby warnings of the json gem that it printed. json 2.10 to 2.x warns for each
  # binary string ("UTF-8 string passed as BINARY").
  def json_warnings
    original_stderr = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string.lines.grep(/json|BINARY/i)
  ensure
    $stderr = original_stderr
  end

  # mysql2 gives BLOB and BINARY columns as ASCII-8BIT strings. yajl wrote their bytes as they were. The json gem
  # raises for them, or writes them with a warning (json 2.10 to 2.x), so they are converted to UTF-8 before.
  def test_writes_binary_string_as_utf8
    stub_elastic
    warnings = json_warnings do
      driver.run(default_tag: @tag) do
        driver.feed({'id' => 1, 'blob' => "caf\u00e9".b, 'emoji' => "\u{1F600}".b})
      end
    end
    assert_equal(["caf\u00e9", "\u{1F600}"], index_cmds[1].values_at('blob', 'emoji'))
    assert_empty(warnings)
    assert_empty(driver.logs.grep(/U\+FFFD/))
  end

  # Bytes that are not valid UTF-8 are replaced, with one warning for the chunk that gives the number of values.
  def test_replaces_bytes_that_are_not_utf8
    stub_elastic
    warnings = json_warnings do
      driver.run(default_tag: @tag) do
        driver.feed({'id' => 1, 'blob' => "a\xFFb".b})
        driver.feed({'id' => 2, 'blob' => "c\xFEd".b, 'text' => "e\xFFf".dup.force_encoding('UTF-8')})
      end
    end
    assert_equal(["a\uFFFDb", "c\uFFFDd", "e\uFFFDf"], [index_cmds[1]['blob'], index_cmds[3]['blob'], index_cmds[3]['text']])
    assert_empty(warnings)
    replaced = driver.logs.grep(/U\+FFFD/)
    assert_equal(1, replaced.size)
    assert_match(/\[warn\]: mysql_replicator_elasticsearch: replaced the bytes that are not valid UTF-8 with U\+FFFD in 3 values$/, replaced.first)
  end

  # A primary key that is a BINARY column becomes the document _id.
  def test_writes_binary_primary_key_as_utf8
    stub_elastic
    warnings = json_warnings do
      driver.run(default_tag: 'myindex.mytype.delete.id') do
        driver.feed({'id' => "k\u00e9y".b})
      end
    end
    assert_equal("k\u00e9y", index_cmds[0]['delete']['_id'])
    assert_empty(warnings)
  end

  # A primary key whose bytes are not valid UTF-8 would become U+FFFD, the same _id for "\x80", "\x81" and the valid
  # "\xEF\xBF\xBD". Such a row is skipped, for an index and for a delete, with one warning for the chunk that gives
  # the number of rows and the indices, and the other rows of the chunk are sent.
  data(index: 'insert', delete: 'delete')
  def test_skips_rows_whose_primary_key_is_not_utf8(event)
    stub_elastic
    driver.run(default_tag: "myindex.mytype.#{event}.id") do
      driver.feed({'id' => "\x80".b, 'name' => 'a'})
      driver.feed({'id' => "\x81".b, 'name' => 'b'})
      driver.feed({'id' => "\xEF\xBF\xBD".b, 'name' => 'c'})
      driver.feed({'id' => 4, 'name' => 'd'})
    end
    actions = index_cmds.map {|cmd| cmd[event == 'delete' ? 'delete' : 'index'] }.compact
    assert_equal(["\uFFFD", '4'], actions.map {|action| action['_id'] })
    assert_equal(%w[c d], index_cmds.map {|cmd| cmd['name'] }.compact) unless event == 'delete'
    skipped = driver.logs.grep(/skipped/)
    assert_equal(1, skipped.size)
    assert_match(/\[warn\]: mysql_replicator_elasticsearch: skipped 2 rows whose primary key is not valid UTF-8, as replacing its bytes would give different rows the same _id\. :index=>myindex$/, skipped.first)
    assert_empty(driver.logs.grep(/U\+FFFD/))
  end

  # The key of a composite primary key too.
  def test_skips_rows_whose_composite_primary_key_is_not_utf8
    stub_elastic
    driver.run(default_tag: 'myindex.mytype.insert.tenant_id,id') do
      driver.feed({'tenant_id' => 1, 'id' => "\x80".b})
      driver.feed({'tenant_id' => 1, 'id' => "k\u00e9y".b})
    end
    assert_equal(["1,k\u00e9y"], index_cmds.map {|cmd| cmd['index'] }.compact.map {|action| action['_id'] })
  end

  # A key that is an array, as a value of json_columns can be, is checked as well.
  def test_skips_rows_whose_array_primary_key_is_not_utf8
    stub_elastic
    driver.run(default_tag: @tag) do
      driver.feed({'id' => ["\x80".b], 'name' => 'a'})
      driver.feed({'id' => ["\x81".b], 'name' => 'b'})
      driver.feed({'id' => ["\uFFFD"], 'name' => 'c'})
    end
    assert_equal(["\uFFFD"], index_cmds.map {|cmd| cmd['index'] }.compact.map {|action| action['_id'] })
    assert_equal(1, driver.logs.grep(/skipped 2 rows/).size)
  end

  # A composite key with a UTF-8 part and a binary part that are both not ASCII. Joining them raised
  # Encoding::CompatibilityError, and Fluentd threw the chunk away.
  def test_composite_primary_key_with_utf8_and_binary_parts
    stub_elastic
    driver.run(default_tag: 'myindex.mytype.insert.a,b') do
      driver.feed({'a' => "caf\u00e9", 'b' => "\xC3\xA9".b})
      driver.feed({'a' => 'plain', 'b' => 'x'})
    end
    assert_equal(["caf\u00e9,\u00e9", 'plain,x'], index_cmds.map {|cmd| cmd['index'] }.compact.map {|action| action['_id'] })
  end

  # A key that is valid UTF-8 keeps its _id: a binary string, a number and a composite key.
  def test_primary_key_that_is_utf8_keeps_its_id
    stub_elastic
    driver.run(default_tag: 'myindex.mytype.insert.tenant_id,id') do
      driver.feed({'tenant_id' => "t\u00e9".b, 'id' => 7})
      driver.feed({'tenant_id' => 10, 'id' => "\u{1F600}"})
    end
    assert_equal(["t\u00e9,7", "10,\u{1F600}"], index_cmds.map {|cmd| cmd['index'] }.compact.map {|action| action['_id'] })
    assert_empty(driver.logs.grep(/skipped/))
  end

  # A chunk with only such rows sends nothing, and does not raise (Elasticsearch answers an empty bulk request with 400).
  def test_chunk_with_only_rows_whose_primary_key_is_not_utf8
    stub_elastic
    assert_nothing_raised do
      driver.run(default_tag: 'myindex.mytype.delete.id') do
        driver.feed({'id' => "\x80".b})
      end
    end
    assert_nil(index_cmds)
    assert_not_requested(:post, 'http://localhost:9200/_bulk')
    assert_equal(1, driver.logs.grep(/skipped 1 rows/).size)
  end

  # A value from json_columns can be nested deeper than the default limit of JSON.generate, which raised for the whole
  # chunk, so the other records of it were not sent either.
  def test_writes_a_deeply_nested_value
    stub_elastic
    deep = JSON.parse('[' * 100 + '1' + ']' * 100)
    driver.run(default_tag: @tag) do
      driver.feed({'id' => 1, 'doc' => deep})
      driver.feed({'id' => 2, 'name' => 'plain'})
    end
    assert_equal([{'id' => 1, 'doc' => deep}, {'id' => 2, 'name' => 'plain'}], [index_cmds[1], index_cmds[3]])
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

  def test_installs_composable_template_by_default
    stub_elastic
    stub_elastic_version("http://localhost:9200/", "8.18.0")
    stub_request(:get, "http://localhost:9200/_index_template/my_tmpl").to_return(:status => 404)
    put_tmpl = stub_request(:put, "http://localhost:9200/_index_template/my_tmpl").to_return(:status => 200, :body => "{}")
    driver.configure("template_name my_tmpl\ntemplate_file #{write_template_file}\n")
    driver.run(default_tag: @tag) { driver.feed(sample_record) }
    assert_requested(put_tmpl)
  end

  def test_installs_legacy_template_when_enabled
    stub_elastic # version 6.8.23
    stub_request(:get, "http://localhost:9200/_template/my_tmpl").to_return(:status => 404)
    put_tmpl = stub_request(:put, "http://localhost:9200/_template/my_tmpl").to_return(:status => 200, :body => "{}")
    driver.configure("template_name my_tmpl\ntemplate_file #{write_template_file}\nuse_legacy_template true\n")
    driver.run(default_tag: @tag) { driver.feed(sample_record) }
    assert_requested(put_tmpl)
  end

  def test_skips_composable_template_on_old_elasticsearch
    stub_elastic # version 6.8.23 (< 7.8), default composable
    put_tmpl = stub_request(:put, "http://localhost:9200/_index_template/my_tmpl")
    driver.configure("template_name my_tmpl\ntemplate_file #{write_template_file}\n")
    driver.run(default_tag: @tag) { driver.feed(sample_record) }
    assert_not_requested(put_tmpl)
  end

  def test_skips_template_when_it_exists_and_no_overwrite
    stub_elastic
    stub_elastic_version("http://localhost:9200/", "8.18.0")
    stub_request(:get, "http://localhost:9200/_index_template/my_tmpl").to_return(:status => 200, :body => "{}")
    put_tmpl = stub_request(:put, "http://localhost:9200/_index_template/my_tmpl")
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
