require 'net/http'
require 'date'

class Fluent::MysqlReplicatorElasticsearchOutput < Fluent::BufferedOutput
  Fluent::Plugin.register_output('mysql_replicator_elasticsearch', self)

  config_param :host, :string,  :default => 'localhost'
  config_param :port, :integer, :default => 9200
  config_param :tag_format, :string, :default => nil

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

  def id_val(record, id_key)
    id_key.map { |col| record[col] }.join(",")
  end

  def write(chunk)
    bulk_message = []

    chunk.msgpack_each do |tag, time, record|
      tag_parts = tag.match(@tag_format)
      target_index = tag_parts['index_name']
      target_type = tag_parts['type_name']
      id_key = tag_parts['primary_key'].split(",")
      id_val = id_val(record, id_key)

      if tag_parts['event'] == 'delete'
        meta = { "delete" => {"_index" => target_index, "_type" => target_type, "_id" => id_val} }
        bulk_message << Yajl::Encoder.encode(meta)
      else
        meta = { "index" => {"_index" => target_index, "_type" => target_type} }
        if id_key && id_val
          meta['index']['_id'] = id_val
        end
        bulk_message << Yajl::Encoder.encode(meta)
        bulk_message << Yajl::Encoder.encode(record)
      end
    end
    bulk_message << ""

    http = Net::HTTP.new(@host, @port.to_i)
    request = Net::HTTP::Post.new('/_bulk', {'content-type' => 'application/json; charset=utf-8'})
    request.body = bulk_message.join("\n")
    http.request(request).value
  end
end
