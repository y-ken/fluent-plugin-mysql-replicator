require 'net/http'
require 'date'
require 'json'
require 'fluent/plugin/output'

class Fluent::Plugin::MysqlReplicatorElasticsearchOutput < Fluent::Plugin::Output
  Fluent::Plugin.register_output('mysql_replicator_elasticsearch', self)

  DEFAULT_BUFFER_TYPE = "memory"

  helpers :compat_parameters

  config_param :host, :string,  :default => 'localhost'
  config_param :port, :integer, :default => 9200
  config_param :tag_format, :string, :default => nil
  config_param :ssl, :bool, :default => false
  config_param :username, :string, :default => nil
  config_param :password, :string, :default => nil, :secret => true

  # Optional: install an Elasticsearch index template on startup so that newly
  # created indices (including future date-rolled ones) get the desired mapping
  # (e.g. geo_point or keyword fields) before the first document locks in
  # dynamic mapping. template_name and template_file must be set together.
  #
  # Parameter names mirror fluent-plugin-elasticsearch. The default uses the
  # modern composable API (fluent-plugin-elasticsearch defaults to legacy):
  #   use_legacy_template false (default) -> PUT /_index_template/<name>  (composable, ES >= 7.8)
  #   use_legacy_template true            -> PUT /_template/<name>        (legacy, ES 6.x+)
  config_param :template_name, :string, :default => nil
  config_param :template_file, :string, :default => nil
  config_param :template_overwrite, :bool, :default => false
  config_param :use_legacy_template, :bool, :default => false

  config_section :buffer do
    config_set_default :@type, DEFAULT_BUFFER_TYPE
  end

  DEFAULT_TAG_FORMAT = /(?<index_name>[^\.]+)\.(?<type_name>[^\.]+)\.(?<event>[^\.]+)\.(?<primary_key>[^\.]+)$/

  def initialize
    super
  end

  def configure(conf)
    super

    if @tag_format.nil? || @tag_format == DEFAULT_TAG_FORMAT
      @tag_format = DEFAULT_TAG_FORMAT
    else
      @tag_format = Regexp.new(conf['tag_format'])
    end

    if @template_name.nil? != @template_file.nil?
      raise Fluent::ConfigError, "mysql_replicator_elasticsearch: 'template_name' and 'template_file' must be set together"
    end
    if @template_file && !File.exist?(@template_file)
      raise Fluent::ConfigError, "mysql_replicator_elasticsearch: template_file not found: #{@template_file}"
    end
  end

  def start
    super
    # nil means "not yet detected"; resolved on a write, and detected again on the next write while it fails.
    @suppress_type = nil
    @es_version = nil
    @template_installed = false
    @prepare_mutex = Mutex.new
  end

  def format(tag, time, record)
    [tag, time, record].to_msgpack
  end

  def shutdown
    super
  end

  def multi_workers_ready?
    true
  end

  def formatted_to_msgpack_binary?
    true
  end

  def write(chunk)
    unmatched_tags = Hash.new(0)
    chunk.msgpack_each {|tag, _time, _record| unmatched_tags[tag] += 1 unless tag.match?(@tag_format) }
    raise_unmatched_tags(unmatched_tags) unless unmatched_tags.empty?

    suppress_type = prepare_elasticsearch

    bulk_message = []
    utf8 = Utf8Converter.new
    without_id = 0
    # The number of rows skipped for a primary key that is not valid UTF-8, by index.
    skipped = Hash.new(0)

    chunk.msgpack_each do |tag, time, record|
      tag_parts = tag.match(@tag_format)
      unless tag_parts
        unmatched_tags[tag] += 1
        next
      end
      target_index = resolve_index_name(tag_parts['index_name'], time)
      target_type = tag_parts['type_name']
      id_keys = tag_parts['primary_key'].to_s.split(',')

      if tag_parts['event'] == 'delete'
        id = join_id(record, id_keys, utf8)
        if id.nil?
          skipped[target_index] += 1
          next
        end
        action = {"_index" => target_index, "_id" => id}
        action['_type'] = target_type unless suppress_type
        meta = { "delete" => utf8.convert(action) }
        bulk_message << JSON.generate(meta)
      else
        action = {"_index" => target_index}
        action['_type'] = target_type unless suppress_type
        if !id_keys.empty? && id_keys.all? {|k| !record[k].nil? }
          id = join_id(record, id_keys, utf8)
          if id.nil?
            skipped[target_index] += 1
            next
          end
          action['_id'] = id
        else
          without_id += 1
        end
        meta = { "index" => utf8.convert(action) }
        bulk_message << JSON.generate(meta)
        # A value from json_columns can be nested deeper than the default limit of JSON.generate (100), as MySQL allows.
        bulk_message << JSON.generate(utf8.convert(record), max_nesting: false)
      end
    end
    raise_unmatched_tags(unmatched_tags) unless unmatched_tags.empty?
    if utf8.replaced > 0
      log.warn "mysql_replicator_elasticsearch: replaced the bytes that are not valid UTF-8 with U+FFFD in #{utf8.replaced} values"
    end
    unless skipped.empty?
      # Without the keys or the records, which can hold values of the rows.
      log.warn "mysql_replicator_elasticsearch: skipped #{skipped.values.sum} rows whose primary key is not valid UTF-8, as replacing its bytes would give different rows the same _id. :index=>#{skipped.keys.join(',')}"
    end
    # Elasticsearch answers a bulk request without actions with 400.
    return if bulk_message.empty?
    bulk_message << ""

    request = Net::HTTP::Post.new('/_bulk', {'content-type' => 'application/json; charset=utf-8'})
    if @username && @password
      request.basic_auth(@username, @password)
    end

    request.body = bulk_message.join("\n")
    response = new_http.request(request)
    response.value
    failed = log_bulk_errors(response.body)
    raise_retriable_bulk_errors(failed, without_id)
  end

  # Raised when documents of a bulk request failed with 429 or 5xx, so that Fluentd writes the chunk again.
  class RetriableBulkError < StandardError; end

  private

  # A record whose tag does not match tag_format cannot be written. The whole chunk, with its other records, is not
  # sent, and Fluent::UnrecoverableError makes Fluentd move it to the backup directory (or to <secondary>) at once,
  # instead of retrying it. The message gives the tags and the number of records, not their contents.
  def raise_unmatched_tags(unmatched_tags)
    count = unmatched_tags.values.sum
    tags = unmatched_tags.first(10).map {|tag, n| "#{tag} (#{n})" }.join(', ')
    raise Fluent::UnrecoverableError, "mysql_replicator_elasticsearch: #{count} records in the chunk have a tag that does not match tag_format #{@tag_format.inspect}, so the chunk is not written: #{tags}"
  end

  # Detects the version and installs the template in one flush at a time. With flush_thread_count 2 or more, they are
  # then done once, and the other flushes wait for them, so that their bulk requests are not sent before the template.
  # Returns whether to omit "_type" for this write.
  def prepare_elasticsearch
    @prepare_mutex.synchronize do
      suppress_type = @suppress_type.nil? ? detect_type_suppression : @suppress_type
      install_template_once if @template_name
      suppress_type
    end
  end

  def new_http
    http = Net::HTTP.new(@host, @port.to_i)
    http.use_ssl = @ssl
    http
  end

  # Elasticsearch answers 200 to a bulk request even when some of its documents fail, for example on a mapping
  # error, and reports them per document in "items". Log them, so that they are not lost silently. Only the index, the
  # status and the type of the error are logged: the reason of the error can contain a part of the value of a field
  # ("Preview of field's value"), and the _id can be built from the values of the primary key. Returns the failed items.
  def log_bulk_errors(body)
    # Most responses have no errors, and a response has an item per document, so it is parsed only when it has some.
    return [] unless body.to_s.include?('"errors":true')
    result = JSON.parse(body)
    return [] unless result.is_a?(Hash) && result['errors']
    items = Array(result['items']).select {|item| item.is_a?(Hash) && item.values.first.is_a?(Hash) }
    # A delete that answers 404 found nothing to delete, such as a delete to an index that is not created yet (an index
    # per day, for example), which leaves the same result as a delete that succeeded.
    failed = items.reject {|item| item.keys.first == 'delete' && item.values.first['status'].to_i == 404 }
                  .map {|item| item.values.first }.select {|item| item['error'] }
    return [] if failed.empty?
    examples = failed.first(5).map do |item|
      error = item['error']
      "index=#{item['_index']} status=#{item['status']} type=#{error.is_a?(Hash) ? error['type'] : 'unknown'}"
    end
    log.error "mysql_replicator_elasticsearch: #{failed.size} of #{items.size} documents failed in a bulk request: #{examples.join(', ')}"
    failed
  rescue StandardError => e
    log.warn "mysql_replicator_elasticsearch: could not read the bulk response: #{e.class}"
    []
  end

  # A document that failed with 429 (too many requests, such as a full write queue) or 5xx can succeed later, so the
  # whole chunk is written again, with Fluentd's retry and backoff. Writing the other documents again is safe: each
  # action has the same _id (index replaces the document, delete removes it again) and they are sent in the same
  # order, so the result is the same, and a later chunk is not written before this one, as Fluentd puts the chunk
  # back at the head of the queue and waits (with one flush thread, which is the default). A document that failed
  # with another 4xx, such as a mapping error, fails the same way again, so it alone does not make the chunk retried.
  # A document without an _id (its primary key is missing or NULL) gets a new one from Elasticsearch each time it is
  # written, so a chunk with one is not written again: that would add a copy of it for each try.
  def raise_retriable_bulk_errors(failed, without_id = 0)
    retriable = failed.map {|item| item['status'].to_i }.select {|status| status == 429 || status >= 500 }
    return if retriable.empty?
    statuses = retriable.tally.sort.map {|status, n| "#{status} x#{n}" }.join(', ')
    if without_id > 0
      log.warn "mysql_replicator_elasticsearch: #{retriable.size} documents failed with a status that can succeed later (#{statuses}), but the chunk is not written again, as #{without_id} documents in it have no _id and would be written again as new documents"
      return
    end
    raise RetriableBulkError, "mysql_replicator_elasticsearch: #{retriable.size} documents failed with a status that can succeed later (#{statuses}); writing the chunk again"
  end

  # Converts the strings of a record to UTF-8 before JSON.generate. mysql2 gives BLOB and BINARY columns as ASCII-8BIT
  # strings. yajl, which this plugin used before, wrote their bytes as they were. The json gem raises for them, or,
  # from 2.10 to 2.x, writes them with a warning for each value when their bytes are valid UTF-8. So a binary string
  # is read as UTF-8 here, and the bytes that are not valid UTF-8 are replaced with U+FFFD, and counted.
  class Utf8Converter
    attr_reader :replaced

    def initialize
      @replaced = 0
    end

    def convert(value)
      case value
      when Hash
        value.each_with_object({}) {|(k, v), h| h[convert(k)] = convert(v) }
      when Array
        value.map {|v| convert(v) }
      when String
        convert_string(value)
      else
        value
      end
    end

    # The string in UTF-8 with the same characters, or nil when its bytes are not valid UTF-8 (or it cannot be converted),
    # without replacing anything.
    def exact(value)
      if value.encoding == Encoding::UTF_8 || value.encoding == Encoding::BINARY || value.encoding == Encoding::US_ASCII
        utf8 = value.dup.force_encoding(Encoding::UTF_8)
        utf8.valid_encoding? ? utf8 : nil
      else
        value.encode(Encoding::UTF_8)
      end
    rescue EncodingError
      nil
    end

    private

    def convert_string(value)
      return value if value.encoding == Encoding::UTF_8 && value.valid_encoding?
      if value.encoding == Encoding::UTF_8 || value.encoding == Encoding::BINARY || value.encoding == Encoding::US_ASCII
        utf8 = value.dup.force_encoding(Encoding::UTF_8)
        return utf8 if utf8.valid_encoding?
        @replaced += 1
        return utf8.scrub
      end
      # Another character set, such as latin1, is converted as the json gem does.
      value.encode(Encoding::UTF_8)
    rescue EncodingError
      @replaced += 1
      value.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "\uFFFD")
    end
  end

  # Build the document _id from one or more primary-key columns. A single key
  # yields its value; a composite key yields the values joined by ",".
  #
  # Returns nil when the _id is not valid UTF-8, as for a BINARY(16) key from UUID_TO_BIN(UUID()). Replacing its bytes
  # with U+FFFD, as for the other values, would give different keys the same _id ("\x80" and "\x81" both become
  # "\uFFFD"), so that a row would overwrite or delete the document of another one. With yajl, which this plugin used
  # before, Elasticsearch rejected the whole bulk request for most such bytes (400), so the chunk was retried and its
  # other rows were not written either.
  def join_id(record, id_keys, utf8)
    values = id_keys.map do |k|
      value = record[k]
      next value unless value.is_a?(String)
      value = utf8.exact(value)
      return nil if value.nil?
      value
    end
    # A key that is not a string, such as an array, is checked once joined.
    utf8.exact(values.join(','))
  rescue Encoding::CompatibilityError
    nil
  end

  # Expand strftime tokens (e.g. "%Y%m%d") in the index name using the record's
  # event time, enabling date-based indices such as "myindex-20180831". Index
  # names without a "%" are returned unchanged.
  def resolve_index_name(index_name, time)
    return index_name unless index_name && index_name.include?('%')
    Time.at(time.to_i).strftime(index_name)
  rescue => e
    log.warn "mysql_replicator_elasticsearch: failed to expand index name '#{index_name}': #{e.message}"
    index_name
  end

  # Mapping types were removed in Elasticsearch 8.x and deprecated in 7.x.
  # Detect the version and omit "_type" for 7.x and later. Returns whether to omit "_type" for this write. After a
  # connection error, a 429 or a 5xx, such as while Elasticsearch is starting, the error is raised, so that the bulk
  # request is not sent with a guessed "_type" and Fluentd retries the chunk later, which detects the version again.
  # After any other failure, such as 403 for a user without the monitor privilege, "_type" is sent (assuming 6.x), and
  # the version is not detected again until a restart, as it would fail the same way on every write.
  def detect_type_suppression
    @es_version = elasticsearch_version
    @suppress_type = @es_version.first >= 7
    log.info "mysql_replicator_elasticsearch: detected Elasticsearch #{@es_version.join('.')}, suppress_type=#{@suppress_type}"
    @suppress_type
  rescue => e
    if retriable_error?(e)
      log.warn "mysql_replicator_elasticsearch: could not detect Elasticsearch version, not sending the bulk request, so that the chunk is retried: #{e.class}: #{e.message}"
      raise
    else
      @suppress_type = false
      log.error "mysql_replicator_elasticsearch: could not detect Elasticsearch version, sending '_type' (assuming 6.x) until a restart: #{e.class}: #{e.message}"
    end
    false
  end

  # Returns the Elasticsearch version as [major, minor].
  def elasticsearch_version
    request = Net::HTTP::Get.new('/')
    request.basic_auth(@username, @password) if @username && @password
    response = new_http.request(request)
    response.value
    number = JSON.parse(response.body).dig('version', 'number')
    raise "the response of GET / has no version number" if number.nil?
    number.to_s.split('.').first(2).map(&:to_i)
  end

  # Whether a failure may go away by trying again: a connection error, a 429 or a 5xx.
  def retriable_error?(error)
    case error
    when Net::HTTPFatalError then true
    # 429, such as a circuit breaker that trips while the node is busy, can succeed later too.
    when Net::HTTPExceptions then error.response.code.to_s == '429'

    when SystemCallError, IOError, SocketError, Timeout::Error then true
    else defined?(OpenSSL::SSL::SSLError) && error.is_a?(OpenSSL::SSL::SSLError)
    end
  end

  # Install the configured index template once, on the first write that succeeds in it. The template
  # is a server-side rule, so Elasticsearch applies it to every new index whose
  # name matches its index_patterns -- including future date-rolled indices --
  # without any further action here.
  # After a connection error, a 429 or a 5xx, the error is raised, so that the bulk request does not create an index
  # with dynamic mapping before the template is in, and Fluentd retries the chunk later, which tries the template
  # again. After any other failure, such as 400 for a broken template file or 403, the error is logged, the bulk
  # request is sent, and the template is not tried again until a restart, as it would fail the same way on every write.
  def install_template_once
    return if @template_installed
    install_template
    @template_installed = true
  rescue => e
    if retriable_error?(e)
      log.warn "mysql_replicator_elasticsearch: failed to install index template '#{@template_name}', not sending the bulk request, so that the chunk is retried: #{e.class}: #{e.message}"
      raise
    else
      @template_installed = true
      log.error "mysql_replicator_elasticsearch: failed to install index template '#{@template_name}', not trying again until a restart: #{e.class}: #{e.message}"
    end
  end

  def install_template
    # The version is known here, unless its detection failed for good.
    if !@use_legacy_template && @es_version.nil?
      raise "the composable template needs the Elasticsearch version, which could not be detected"
    end
    if !@use_legacy_template && !composable_templates_supported?
      log.warn "mysql_replicator_elasticsearch: composable index templates require Elasticsearch >= 7.8; skipping template '#{@template_name}' (detected #{@es_version&.join('.') || 'unknown'}). Set 'use_legacy_template true' for older Elasticsearch."
      return
    end
    if !@template_overwrite && template_exists?
      log.info "mysql_replicator_elasticsearch: index template '#{@template_name}' already exists; skipping (set 'template_overwrite true' to replace)"
      return
    end
    # A template_file that cannot be read, such as a directory, fails the same way on every write, so it is not
    # tried again, as for a 400.
    begin
      body = File.read(@template_file)
    rescue SystemCallError, IOError => e
      raise "could not read template_file #{@template_file}: #{e.class}: #{e.message}"
    end
    put_template(body)
    log.info "mysql_replicator_elasticsearch: installed index template '#{@template_name}' (#{@use_legacy_template ? 'legacy' : 'composable'})"
  end

  def composable_templates_supported?
    major, minor = @es_version
    major > 7 || (major == 7 && minor >= 8)
  end

  def template_path
    @use_legacy_template ? "/_template/#{@template_name}" : "/_index_template/#{@template_name}"
  end

  def template_exists?
    request = Net::HTTP::Get.new(template_path)
    request.basic_auth(@username, @password) if @username && @password
    response = new_http.request(request)
    return false if response.code.to_i == 404
    response.value
    true
  end

  def put_template(body)
    request = Net::HTTP::Put.new(template_path, {'content-type' => 'application/json; charset=utf-8'})
    request.basic_auth(@username, @password) if @username && @password
    request.body = body
    new_http.request(request).value
  end
end
