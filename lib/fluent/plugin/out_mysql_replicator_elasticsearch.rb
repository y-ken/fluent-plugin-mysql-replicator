require 'net/http'
require 'date'
require 'yajl'
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
  # Parameter names and defaults mirror fluent-plugin-elasticsearch:
  #   use_legacy_template true  (default) -> PUT /_template/<name>        (ES 6.x+)
  #   use_legacy_template false           -> PUT /_index_template/<name>  (ES >= 7.8)
  config_param :template_name, :string, :default => nil
  config_param :template_file, :string, :default => nil
  config_param :template_overwrite, :bool, :default => false
  config_param :use_legacy_template, :bool, :default => true

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
    # nil means "not yet detected"; resolved on the first write.
    @suppress_type = nil
    @es_version = nil
    @template_installed = false
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
    detect_type_suppression if @suppress_type.nil?
    install_template_once if @template_name

    bulk_message = []

    chunk.msgpack_each do |tag, time, record|
      tag_parts = tag.match(@tag_format)
      target_index = resolve_index_name(tag_parts['index_name'], time)
      target_type = tag_parts['type_name']
      id_keys = tag_parts['primary_key'].to_s.split(',')

      if tag_parts['event'] == 'delete'
        action = {"_index" => target_index, "_id" => join_id(record, id_keys)}
        action['_type'] = target_type unless @suppress_type
        meta = { "delete" => action }
        bulk_message << Yajl::Encoder.encode(meta)
      else
        action = {"_index" => target_index}
        action['_type'] = target_type unless @suppress_type
        if !id_keys.empty? && id_keys.all? {|k| !record[k].nil? }
          action['_id'] = join_id(record, id_keys)
        end
        meta = { "index" => action }
        bulk_message << Yajl::Encoder.encode(meta)
        bulk_message << Yajl::Encoder.encode(record)
      end
    end
    bulk_message << ""

    request = Net::HTTP::Post.new('/_bulk', {'content-type' => 'application/json; charset=utf-8'})
    if @username && @password
      request.basic_auth(@username, @password)
    end

    request.body = bulk_message.join("\n")
    new_http.request(request).value
  end

  private

  def new_http
    http = Net::HTTP.new(@host, @port.to_i)
    http.use_ssl = @ssl
    http
  end

  # Build the document _id from one or more primary-key columns. A single key
  # yields its value; a composite key yields the values joined by ",".
  def join_id(record, id_keys)
    id_keys.map {|k| record[k] }.join(',')
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
  # Detect the version once and omit "_type" for 7.x and later.
  def detect_type_suppression
    @es_version = elasticsearch_version
    major = @es_version&.first
    @suppress_type = !major.nil? && major >= 7
    if major
      log.info "mysql_replicator_elasticsearch: detected Elasticsearch #{@es_version.join('.')}, suppress_type=#{@suppress_type}"
    else
      log.warn "mysql_replicator_elasticsearch: could not detect Elasticsearch version, sending '_type' (assuming 6.x)"
    end
  end

  # Returns the Elasticsearch version as [major, minor], or nil if undetectable.
  def elasticsearch_version
    request = Net::HTTP::Get.new('/')
    request.basic_auth(@username, @password) if @username && @password
    response = new_http.request(request)
    number = Yajl::Parser.parse(response.body).dig('version', 'number')
    return nil if number.nil?
    number.to_s.split('.').first(2).map(&:to_i)
  rescue => e
    log.warn "mysql_replicator_elasticsearch: version detection failed: #{e.message}"
    nil
  end

  # Install the configured index template once, on the first write. The template
  # is a server-side rule, so Elasticsearch applies it to every new index whose
  # name matches its index_patterns -- including future date-rolled indices --
  # without any further action here. Failures are logged but never abort indexing.
  def install_template_once
    return if @template_installed
    @template_installed = true
    install_template
  rescue => e
    log.warn "mysql_replicator_elasticsearch: failed to install index template '#{@template_name}': #{e.message}"
  end

  def install_template
    if !@use_legacy_template && !composable_templates_supported?
      log.warn "mysql_replicator_elasticsearch: composable index templates require Elasticsearch >= 7.8; skipping template '#{@template_name}' (detected #{@es_version&.join('.') || 'unknown'})"
      return
    end
    if !@template_overwrite && template_exists?
      log.info "mysql_replicator_elasticsearch: index template '#{@template_name}' already exists; skipping (set 'template_overwrite true' to replace)"
      return
    end
    put_template(File.read(@template_file))
    log.info "mysql_replicator_elasticsearch: installed index template '#{@template_name}' (#{@use_legacy_template ? 'legacy' : 'composable'})"
  end

  def composable_templates_supported?
    return false if @es_version.nil?
    major, minor = @es_version
    major > 7 || (major == 7 && minor >= 8)
  end

  def template_path
    @use_legacy_template ? "/_template/#{@template_name}" : "/_index_template/#{@template_name}"
  end

  def template_exists?
    request = Net::HTTP::Get.new(template_path)
    request.basic_auth(@username, @password) if @username && @password
    new_http.request(request).code.to_i == 200
  end

  def put_template(body)
    request = Net::HTTP::Put.new(template_path, {'content-type' => 'application/json; charset=utf-8'})
    request.basic_auth(@username, @password) if @username && @password
    request.body = body
    new_http.request(request).value
  end
end
