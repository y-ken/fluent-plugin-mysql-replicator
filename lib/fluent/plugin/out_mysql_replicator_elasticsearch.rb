require 'net/http'
require 'date'
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
    bulk_message = []

    chunk.msgpack_each do |tag, time, record|
      tag_parts = tag.match(@tag_format)
      target_index = tag_parts['index_name']
      target_type = tag_parts['type_name']
      id_key = tag_parts['primary_key']

      if tag_parts['event'] == 'delete'
        meta = { "delete" => {"_index" => target_index, "_type" => target_type, "_id" => record[id_key]} }
        bulk_message << Yajl::Encoder.encode(meta)
      else
        meta = { "index" => {"_index" => target_index, "_type" => target_type} }
        if id_key && record[id_key]
          meta['index']['_id'] = record[id_key]
        end
        bulk_message << Yajl::Encoder.encode(meta)
        bulk_message << Yajl::Encoder.encode(record)
      end
    end
    bulk_message << ""

    http = Net::HTTP.new(@host, @port.to_i)
    http.use_ssl = @ssl

    request = Net::HTTP::Post.new('/_bulk', {'content-type' => 'application/json; charset=utf-8'})
    if @username && @password
      request.basic_auth(@username, @password)
    end

    request.body = bulk_message.join("\n")

    request.body.gsub!(/\\"/, '"')
    request.body.gsub!(/\"{/, '{')
    request.body.gsub!(/}\"/, '}')

    http.request(request).value
  end
end
