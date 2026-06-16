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
  end

  def start
    super
    # nil means "not yet detected"; resolved on the first write.
    @suppress_type = nil
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

    bulk_message = []

    chunk.msgpack_each do |tag, time, record|
      tag_parts = tag.match(@tag_format)
      target_index = resolve_index_name(tag_parts['index_name'], time)
      target_type = tag_parts['type_name']
      id_key = tag_parts['primary_key']

      if tag_parts['event'] == 'delete'
        action = {"_index" => target_index, "_id" => record[id_key]}
        action['_type'] = target_type unless @suppress_type
        meta = { "delete" => action }
        bulk_message << Yajl::Encoder.encode(meta)
      else
        action = {"_index" => target_index}
        action['_type'] = target_type unless @suppress_type
        if id_key && record[id_key]
          action['_id'] = record[id_key]
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
  # Detect the major version once and omit "_type" for 7.x and later.
  def detect_type_suppression
    major = elasticsearch_major_version
    @suppress_type = !major.nil? && major >= 7
    if major
      log.info "mysql_replicator_elasticsearch: detected Elasticsearch #{major}.x, suppress_type=#{@suppress_type}"
    else
      log.warn "mysql_replicator_elasticsearch: could not detect Elasticsearch version, sending '_type' (assuming 6.x)"
    end
  end

  def elasticsearch_major_version
    request = Net::HTTP::Get.new('/')
    request.basic_auth(@username, @password) if @username && @password
    response = new_http.request(request)
    number = Yajl::Parser.parse(response.body).dig('version', 'number')
    number.to_s.split('.').first.to_i
  rescue => e
    log.warn "mysql_replicator_elasticsearch: version detection failed: #{e.message}"
    nil
  end
end
