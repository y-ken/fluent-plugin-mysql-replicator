require 'helper'
require 'fluent/test/driver/output'
require 'webmock/test_unit'
require 'tempfile'
require 'tmpdir'

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
  def stub_elastic_version(url, version="6.8.23", basic_auth: nil)
    stub = stub_request(:get, url)
    stub = stub.with(basic_auth: basic_auth) if basic_auth
    stub.to_return(
      :status => 200,
      :headers => {"Content-Type" => "application/json"},
      :body => %({"version":{"number":"#{version}"}})
    )
  end

  # webmock 3 matches the credentials with basic_auth, not with the user information in the URL.
  def stub_elastic(url="http://localhost:9200/_bulk", basic_auth: nil)
    stub_elastic_version(url.sub('/_bulk', '/'), basic_auth: basic_auth)
    stub = stub_request(:post, url)
    stub = stub.with(basic_auth: basic_auth) if basic_auth
    stub.with do |req|
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

  # A record whose tag does not match tag_format makes the chunk unrecoverable, so that Fluentd moves it to the backup
  # directory at once, instead of retrying it. Nothing of the chunk is sent, and the error names the tag, not the
  # contents of the records. (The test buffer throws the chunk away instead of writing a backup file.)
  def test_chunk_with_a_tag_not_matching_tag_format_is_unrecoverable
    bulk = stub_elastic
    driver("<buffer>\n disable_chunk_backup true\n</buffer>\n")
    driver.run(default_tag: @tag) do
      driver.feed('nomatch', Fluent::EventTime.now, {'id' => 1, 'secret' => 'xyzzy'})
      driver.feed('nomatch', Fluent::EventTime.now, {'id' => 2, 'secret' => 'xyzzy'})
      driver.feed(@tag, Fluent::EventTime.now, sample_record)
    end
    assert_not_requested(bulk)
    error = driver.logs.grep(/got unrecoverable error/)
    assert_equal(1, error.size)
    assert_match(/error_class=Fluent::UnrecoverableError error="mysql_replicator_elasticsearch: 2 records .* tag_format .*: nomatch \(2\)"/, error.first)
    assert_empty(driver.logs.grep(/xyzzy/))
  end

  # The tags are checked before GET / and the template, so that such a chunk goes to the backup at once while they
  # fail with a 5xx, instead of being retried.
  def test_chunk_with_a_tag_not_matching_tag_format_is_unrecoverable_while_get_root_fails
    get_root = stub_request(:get, "http://localhost:9200/").to_return(:status => 503, :body => "unavailable")
    bulk = stub_request(:post, "http://localhost:9200/_bulk")
    driver("<buffer>\n disable_chunk_backup true\n</buffer>\n")
    driver.run(default_tag: @tag) do
      driver.feed('nomatch', Fluent::EventTime.now, {'id' => 1})
      driver.feed(@tag, Fluent::EventTime.now, sample_record)
    end
    assert_not_requested(get_root)
    assert_not_requested(bulk)
    assert_equal(1, driver.logs.grep(/got unrecoverable error.*nomatch \(1\)/).size)
  end

  def test_chunk_with_a_tag_not_matching_tag_format_is_unrecoverable_while_the_template_fails
    get_root = stub_elastic_version("http://localhost:9200/", "8.18.0")
    get_tmpl = stub_request(:get, "http://localhost:9200/_index_template/my_tmpl").to_return(:status => 503)
    put_tmpl = stub_request(:put, "http://localhost:9200/_index_template/my_tmpl").to_return(:status => 503)
    bulk = stub_request(:post, "http://localhost:9200/_bulk")
    driver("template_name my_tmpl\ntemplate_file #{write_template_file}\n<buffer>\n disable_chunk_backup true\n</buffer>\n")
    driver.run(default_tag: @tag) do
      driver.feed('nomatch', Fluent::EventTime.now, {'id' => 1})
      driver.feed(@tag, Fluent::EventTime.now, sample_record)
    end
    assert_not_requested(get_root)
    assert_not_requested(get_tmpl)
    assert_not_requested(put_tmpl)
    assert_not_requested(bulk)
    assert_equal(1, driver.logs.grep(/got unrecoverable error.*nomatch \(1\)/).size)
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

  # Records the bulk requests of a run, one array of parsed lines per request.
  def stub_bulk_requests(url="http://localhost:9200/_bulk")
    bulks = []
    stub_request(:post, url).with {|req| bulks << req.body.split("\n").map {|r| JSON.parse(r) } }
    bulks
  end

  def version_response(version)
    {:status => 200, :headers => {"Content-Type" => "application/json"}, :body => %({"version":{"number":"#{version}"}})}
  end

  # Fluentd retries a chunk whose write raised. These settings make it retry soon.
  RETRY_SOON = "<buffer>\nretry_wait 0.1\nretry_randomize false\nflush_thread_interval 0.1\n</buffer>\n"

  # One chunk, which Fluentd retries while its write raises.
  def write_with_retries
    driver.run(default_tag: @tag, force_flush_retry: true) do
      driver.feed(sample_record)
      driver.flush
    end
  end

  # Elasticsearch may not answer yet on the first write, for example when both start together. The bulk request is
  # then not sent with a guessed "_type", which Elasticsearch 8 rejects, and the version is detected again when Fluentd
  # retries the chunk.
  def test_detects_the_version_again_after_a_failed_detection
    bulks = stub_bulk_requests
    get_root = stub_request(:get, "http://localhost:9200/").to_return({:status => 503, :body => "unavailable"}, version_response("8.18.0"))
    driver.configure(RETRY_SOON)
    write_with_retries
    assert_requested(get_root, :times => 2)
    assert_equal(1, bulks.size)
    assert_false(bulks[0][0]['index'].has_key?('_type'))
  end

  # The bulk request is not sent before the template is in, as it could create the index with dynamic mapping, which
  # a template installed later does not change.
  def test_installs_the_template_again_after_a_failed_install
    requests = []
    stub_request(:post, "http://localhost:9200/_bulk").to_return {|req| requests << :bulk; {:status => 200} }
    stub_elastic_version("http://localhost:9200/", "8.18.0")
    stub_request(:get, "http://localhost:9200/_index_template/my_tmpl").to_return(:status => 404)
    put_tmpl = stub_request(:put, "http://localhost:9200/_index_template/my_tmpl").to_return({:status => 500, :body => "{}"}, {:status => 200, :body => "{}"})
    driver.configure("template_name my_tmpl\ntemplate_file #{write_template_file}\n" + RETRY_SOON)
    write_with_retries
    assert_requested(put_tmpl, :times => 2)
    assert_equal([:bulk], requests)
  end

  # The composable template needs the version. It is installed once the version is detected, before the bulk request.
  def test_installs_the_composable_template_once_the_version_is_known
    bulks = stub_bulk_requests
    stub_request(:get, "http://localhost:9200/").to_return({:status => 503, :body => "unavailable"}, version_response("8.18.0"))
    stub_request(:get, "http://localhost:9200/_index_template/my_tmpl").to_return(:status => 404)
    put_tmpl = stub_request(:put, "http://localhost:9200/_index_template/my_tmpl").to_return(:status => 200, :body => "{}")
    driver.configure("template_name my_tmpl\ntemplate_file #{write_template_file}\n" + RETRY_SOON)
    write_with_retries
    assert_requested(put_tmpl, :times => 1)
    assert_equal(1, bulks.size)
  end

  def three_writes
    driver.run(default_tag: @tag) do
      3.times do
        driver.feed(sample_record)
        driver.flush
      end
    end
  end

  def log_lines(level)
    driver.logs.grep(/\[#{level}\]: mysql_replicator_elasticsearch/)
  end

  # A connection error, like a 5xx, may go away, so the chunk is retried and the version is detected again.
  def test_detects_the_version_again_after_a_connection_error
    bulks = stub_bulk_requests
    stub_request(:get, "http://localhost:9200/").to_raise(Errno::ECONNREFUSED).then.to_return(version_response("8.18.0"))
    driver.configure(RETRY_SOON)
    write_with_retries
    assert_equal([nil], bulks.map {|lines| lines[0]['index']['_type'] })
  end

  # 429, such as circuit_breaking_exception while the node is busy, can succeed later, like a 5xx.
  def test_detects_the_version_again_after_a_429
    bulks = stub_bulk_requests
    stub_request(:get, "http://localhost:9200/").to_return(:status => 429, :body => '{"error":"circuit_breaking_exception"}').then.to_return(version_response("8.18.0"))
    driver.configure(RETRY_SOON)
    write_with_retries
    assert_equal([nil], bulks.map {|lines| lines[0]['index']['_type'] })
    assert_equal(1, log_lines('warn').size)
    assert_empty(log_lines('error'))
  end

  # A connection error on the template, like a 5xx, may go away, so the chunk is retried, and the bulk request is
  # sent once the template is in.
  def test_installs_the_template_again_after_a_connection_error
    requests = []
    stub_request(:post, "http://localhost:9200/_bulk").to_return {|req| requests << :bulk; {:status => 200} }
    stub_elastic_version("http://localhost:9200/", "8.18.0")
    get_tmpl = stub_request(:get, "http://localhost:9200/_index_template/my_tmpl").to_raise(Errno::ECONNRESET).then.to_return(:status => 404)
    stub_request(:put, "http://localhost:9200/_index_template/my_tmpl").to_return {|req| requests << :put; {:status => 200} }
    driver.configure("template_name my_tmpl\ntemplate_file #{write_template_file}\n" + RETRY_SOON)
    write_with_retries
    assert_requested(get_tmpl, :times => 2)
    assert_equal([:put, :bulk], requests)
  end

  # A 4xx on GET /, such as 403 for a user without the monitor privilege, fails the same way on every write. It is
  # logged once, and "_type" is sent (assuming 6.x) until a restart, as before.
  def test_does_not_detect_the_version_again_after_a_4xx
    bulks = stub_bulk_requests
    get_root = stub_request(:get, "http://localhost:9200/").to_return(:status => 403, :body => '{"error":"unauthorized"}')
    three_writes
    assert_requested(get_root, :times => 1)
    assert_equal(['mytype'] * 3, bulks.map {|lines| lines[0]['index']['_type'] })
    assert_equal(1, log_lines('error').size)
    assert_empty(log_lines('warn'))
  end

  # A 4xx on the template, such as 400 for a broken template file, fails the same way on every write. The bulk
  # requests are still sent.
  def test_does_not_install_the_template_again_after_a_4xx
    bulks = stub_bulk_requests
    stub_elastic_version("http://localhost:9200/", "8.18.0")
    get_tmpl = stub_request(:get, "http://localhost:9200/_index_template/my_tmpl").to_return(:status => 404)
    put_tmpl = stub_request(:put, "http://localhost:9200/_index_template/my_tmpl").to_return(:status => 400, :body => '{"error":"bad template"}')
    driver.configure("template_name my_tmpl\ntemplate_file #{write_template_file}\n")
    three_writes
    assert_requested(get_tmpl, :times => 1)
    assert_requested(put_tmpl, :times => 1)
    assert_equal(1, log_lines('error').size)
    assert_empty(log_lines('warn'))
    assert_equal(3, bulks.size)
  end

  def test_does_not_install_the_template_again_after_a_4xx_on_its_check
    bulks = stub_bulk_requests
    stub_elastic_version("http://localhost:9200/", "8.18.0")
    get_tmpl = stub_request(:get, "http://localhost:9200/_index_template/my_tmpl").to_return(:status => 403)
    put_tmpl = stub_request(:put, "http://localhost:9200/_index_template/my_tmpl")
    driver.configure("template_name my_tmpl\ntemplate_file #{write_template_file}\n")
    three_writes
    assert_requested(get_tmpl, :times => 1)
    assert_not_requested(put_tmpl)
    assert_equal(1, log_lines('error').size)
    assert_equal(3, bulks.size)
  end

  # A template_file that cannot be read, such as a directory, fails the same way on every write. The bulk requests
  # are still sent.
  def test_does_not_install_the_template_again_when_its_file_cannot_be_read
    bulks = stub_bulk_requests
    stub_elastic_version("http://localhost:9200/", "8.18.0")
    get_tmpl = stub_request(:get, "http://localhost:9200/_index_template/my_tmpl").to_return(:status => 404)
    put_tmpl = stub_request(:put, "http://localhost:9200/_index_template/my_tmpl")
    Dir.mktmpdir do |dir|
      driver.configure("template_name my_tmpl\ntemplate_file #{dir}\n")
      three_writes
    end
    assert_requested(get_tmpl, :times => 1)
    assert_not_requested(put_tmpl)
    assert_equal(1, log_lines('error').size)
    assert_empty(log_lines('warn'))
    assert_equal(3, bulks.size)
  end

  # The composable template needs the version. When it cannot be detected for good, the template is given up too.
  def test_gives_up_the_composable_template_when_the_version_cannot_be_detected
    bulks = stub_bulk_requests
    get_root = stub_request(:get, "http://localhost:9200/").to_return(:status => 403)
    put_tmpl = stub_request(:put, "http://localhost:9200/_index_template/my_tmpl")
    driver.configure("template_name my_tmpl\ntemplate_file #{write_template_file}\n")
    three_writes
    assert_requested(get_root, :times => 1)
    assert_not_requested(put_tmpl)
    assert_equal(2, log_lines('error').size)
    assert_empty(log_lines('warn'))
    assert_equal(3, bulks.size)
  end

  # A chunk with the records, as a flush passes it to write.
  def chunk_of(*records)
    chunk = Fluent::Plugin::Buffer::MemoryChunk.new(Fluent::Plugin::Buffer::Metadata.new(nil, nil, nil))
    chunk.concat(records.map {|r| [@tag, Fluent::EventTime.now, r].to_msgpack }.join, records.size)
    chunk.commit
    chunk.extend(Fluent::ChunkMessagePackEventStreamer)
  end

  # With flush_thread_count 2 or more, two flushes can write at the same time. The template is installed by one of
  # them, and the other one waits for it before it sends its bulk request.
  def test_installs_the_template_once_when_two_flushes_write_at_the_same_time
    requests = []
    # Recorded in to_return, which runs once for each request, unlike the block of with, which assert_requested runs too.
    stub_request(:post, "http://localhost:9200/_bulk").to_return {|req| requests << :bulk; {:status => 200} }
    get_root = stub_elastic_version("http://localhost:9200/", "8.18.0")
    # A slow check, so that the second flush starts while the first one installs the template.
    stub_request(:get, "http://localhost:9200/_index_template/my_tmpl").to_return {|req| sleep 0.5; {:status => 404} }
    put_tmpl = stub_request(:put, "http://localhost:9200/_index_template/my_tmpl").to_return {|req| requests << :put; {:status => 200} }
    driver.configure("template_name my_tmpl\ntemplate_file #{write_template_file}\n")
    driver.run do
      2.times.map { Thread.new { driver.instance.write(chunk_of(sample_record)) } }.each(&:join)
    end
    assert_requested(get_root, :times => 1)
    assert_requested(put_tmpl, :times => 1)
    assert_equal([:put, :bulk, :bulk], requests)
  end

  # Elasticsearch answers 200 to a bulk request even when some of its documents fail, and reports them in "items".
  # The reason of an error can contain a part of the value of the field, so it is not logged.
  def test_logs_documents_that_failed_in_a_bulk_request
    stub_elastic_version("http://localhost:9200/", "8.18.0")
    body = {
      'errors' => true,
      'items' => [
        {'index' => {'_index' => 'myindex', '_id' => '1', 'status' => 201}},
        {'index' => {'_index' => 'myindex', '_id' => '2', 'status' => 400,
                     'error' => {'type' => 'document_parsing_exception',
                                 'reason' => "[1:8] failed to parse field [age] of type [integer] in document with id '2'. Preview of field's value: 'xyzzy'"}}},
      ],
    }
    stub_request(:post, "http://localhost:9200/_bulk").to_return(:status => 200, :headers => {"Content-Type" => "application/json"}, :body => JSON.generate(body))
    driver.run(default_tag: @tag) do
      driver.feed(sample_record)
      driver.feed(sample_record)
    end
    errors = driver.logs.grep(/\[error\]/)
    assert_equal(1, errors.size, driver.logs.inspect)
    assert_match(/1 of 2 documents failed in a bulk request: index=myindex status=400 type=document_parsing_exception$/, errors.first)
    assert_empty(driver.logs.grep(/xyzzy|Preview/))
  end

  # A delete to an index that is not created yet answers 404 index_not_found_exception, and leaves nothing to delete.
  def test_does_not_log_a_delete_that_found_no_index
    stub_elastic_version("http://localhost:9200/", "8.18.0")
    stub_request(:post, "http://localhost:9200/_bulk").to_return(:status => 200, :headers => {'Content-Type' => 'application/json'},
      :body => '{"took":1,"errors":true,"items":[{"delete":{"_index":"users-20261104","_id":"1","status":404,"error":{"type":"index_not_found_exception","reason":"no such index [users-20261104]"}}}]}')
    driver.run(default_tag: 'myindex.mytype.delete.id') { driver.feed(sample_record) }
    assert_empty(log_lines('error'))
  end

  # Elasticsearch does not answer like this, but a malformed response is only logged, and the write succeeds, as its
  # documents may have been written.
  def test_warns_once_for_a_bulk_response_that_cannot_be_read
    stub_elastic_version("http://localhost:9200/", "8.18.0")
    stub_request(:post, "http://localhost:9200/_bulk").to_return(:status => 200, :headers => {'Content-Type' => 'application/json'},
      :body => '{"took":1,"errors":true,"items":[{"delete":{"_index":"myindex","_id":"1","status":false}}]}')
    driver.run(default_tag: 'myindex.mytype.delete.id') { driver.feed(sample_record) }
    assert_equal(["could not read the bulk response: NoMethodError"], log_lines('warn').map {|l| l[/could not read.*/] }, driver.logs.inspect)
    assert_empty(driver.logs.grep(/unrecoverable error|failed to flush|bad chunk/))
  end

  def test_does_not_log_errors_for_a_bulk_request_without_errors
    stub_elastic_version("http://localhost:9200/", "8.18.0")
    stub_request(:post, "http://localhost:9200/_bulk").to_return(:status => 200, :headers => {"Content-Type" => "application/json"}, :body => '{"errors":false,"items":[{"index":{"status":201}}]}')
    driver.run(default_tag: @tag) do
      driver.feed(sample_record)
    end
    assert_empty(driver.logs.grep(/\[error\]/))
  end

  def bulk_response(*statuses)
    items = statuses.each_with_index.map do |status, i|
      item = {'_index' => 'myindex', '_id' => (i + 1).to_s, 'status' => status}
      item['error'] = {'type' => status == 429 ? 'es_rejected_execution_exception' : 'some_exception', 'reason' => 'xyzzy'} if status >= 300
      {'index' => item}
    end
    {:status => 200, :headers => {"Content-Type" => "application/json"}, :body => JSON.generate({'errors' => statuses.any? {|s| s >= 300 }, 'items' => items})}
  end

  # A document that failed with 429 or 5xx can succeed later, so the chunk is written again by Fluentd's retry.
  def test_retries_the_chunk_when_a_document_failed_with_429_or_5xx
    stub_elastic_version("http://localhost:9200/", "8.18.0")
    bulk = stub_request(:post, "http://localhost:9200/_bulk").to_return(bulk_response(201, 429, 400, 503))
    error = assert_raise(Fluent::Plugin::MysqlReplicatorElasticsearchOutput::RetriableBulkError) do
      driver.run(default_tag: @tag) do
        4.times {|i| driver.feed(sample_record.merge('id' => i + 1)) }
      end
    end
    assert_match(/2 documents failed with a status that can succeed later \(429 x1, 503 x1\); writing the chunk again/, error.message)
    assert_not_match(/xyzzy/, error.message)
    assert_requested(bulk, :times => 1)
  end

  # A document without an _id gets a new one each time it is written, so writing its chunk again would add a copy.
  def test_does_not_retry_a_chunk_with_a_document_without_an_id
    stub_elastic_version("http://localhost:9200/", "8.18.0")
    bulk = stub_request(:post, "http://localhost:9200/_bulk").to_return(bulk_response(201, 429))
    assert_nothing_raised do
      driver.run(default_tag: @tag) do
        driver.feed(sample_record)
        driver.feed(sample_record.merge('id' => 2))
      end
    end
    assert_requested(bulk, :times => 1)
    assert_equal(1, log_lines('warn').grep(/1 documents failed with a status that can succeed later \(429 x1\), but the chunk is not written again, as 1 documents in it have no _id/).size)
  end

  # A document that failed with another 4xx, such as a mapping error, would fail the same way again.
  def test_does_not_retry_the_chunk_for_documents_that_failed_with_4xx
    stub_elastic_version("http://localhost:9200/", "8.18.0")
    stub_request(:post, "http://localhost:9200/_bulk").to_return(bulk_response(201, 400, 409))
    assert_nothing_raised do
      driver.run(default_tag: @tag) do
        3.times { driver.feed(sample_record) }
      end
    end
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
    elastic_request = stub_elastic("http://localhost:9200/_bulk", basic_auth: ['foo', 'bar'])
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
    elastic_request = stub_elastic("http://localhost:9200/_bulk", basic_auth: ['foo', 'bar'])
    assert_raise(WebMock::NetConnectNotAllowedError) {
      driver.run(default_tag: @tag) do
        driver.feed(sample_record)
      end
    }
  end
end
