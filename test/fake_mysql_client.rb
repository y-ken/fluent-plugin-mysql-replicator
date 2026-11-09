require 'mysql2'

# A stand-in for Mysql2::Client in unit tests. Each query is recorded and answered by the given block, which returns
# the rows as an Array of Hashes. Like a real client, a closed client raises, an empty query raises, and a session
# cannot create the same temporary table twice. Like a client with :stream => true, as the plugins use, the rows of a
# SELECT must be read before the next query on the client, which fails otherwise (and ping returns false).
class FakeMysqlClient
  attr_reader :queries

  def initialize(&responder)
    @responder = responder
    @queries = []
    @closed = false
    @unread = nil
  end

  def query(sql)
    raise Mysql2::Error, 'MySQL client is not connected' if @closed
    raise Mysql2::Error, "Commands out of sync; you can't run this command now" if @unread
    raise Mysql2::Error, 'Query was empty' if sql.strip.empty?
    if (table = sql[/\ACREATE TEMPORARY TABLE (\w+)/i, 1])
      raise Mysql2::Error, "Table '#{table}' already exists" if @queries.any? {|q| q =~ /\ACREATE TEMPORARY TABLE #{table}\b/i }
    end
    @queries << sql
    rows = @responder.call(sql) || []
    # An Enumerator is passed as it is, so that a test can fail in the middle of a streamed result.
    return rows unless rows.is_a?(Array)
    rows = rows.map(&:dup)
    return rows unless sql =~ /\A\s*SELECT/i
    @unread = FakeResult.new(rows) { @unread = nil }
  end

  # The escape of a real client, which only doubles the quotes once the session has NO_BACKSLASH_ESCAPES. The values
  # escaped by this client are recorded.
  def escape(value)
    raise Mysql2::Error, 'MySQL client is not connected' if @closed
    escaped << value
    @queries.any? {|q| q.include?('NO_BACKSLASH_ESCAPES') } ? value.gsub("'", "''") : Mysql2::Client.escape(value)
  end

  def escaped
    @escaped ||= []
  end

  def ping
    !@closed && @unread.nil?
  end

  # A CALL of a procedure gives a result for each SELECT in it, and a status result at the end. The test gives the
  # results after the first as more_results.
  def next_result
    return false if more_results.empty?
    @next = more_results.shift
    true
  end

  def store_result
    @next.nil? ? nil : FakeResult.new(@next) { }
  end

  def more_results
    @more_results ||= []
  end

  def close
    @closed = true
  end

  def closed?
    @closed
  end
end

# The hash_tables of the manager database of mysql_replicator_multi, for the queries that the plugin sends.
class FakeHashTables
  # {[setting_name, pk] => hash}
  attr_reader :rows

  def initialize
    @rows = {}
  end

  def call(sql)
    case sql.gsub(/\s+/, ' ').strip
    when /\ASELECT SQL_NO_CACHE setting_query_hash FROM hash_tables WHERE setting_query_pk = (-?\d+) AND setting_name = '([^']*)'\z/
      hash = @rows[[$2, $1.to_i]]
      hash ? [{'setting_query_hash' => hash}] : []
    when /\ASELECT SQL_NO_CACHE setting_query_pk FROM hash_tables WHERE setting_name = '([^']*)' AND (.+)\z/
      name, condition = $1, $2
      comparisons = condition.scan(/setting_query_pk ([<>]) (-?\d+)/).map {|op, n| [op, n.to_i] }
      combine = condition.include?(' OR ') ? :any? : :all?
      @rows.keys.select {|s, pk| s == name && comparisons.public_send(combine) {|op, n| pk.public_send(op, n) } }
           .map(&:last).sort.map {|pk| {'setting_query_pk' => pk} }
    when /\AUPDATE hash_tables SET setting_query_hash = '([^']*)' WHERE setting_name = '([^']*)' AND setting_query_pk = '(-?\d+)'\z/
      @rows[[$2, $3.to_i]] = $1
      []
    when /\ADELETE FROM hash_tables WHERE setting_name = '([^']*)' AND setting_query_pk IN\(([^)]*)\)\z/
      name = $1
      $2.split(',').each {|pk| @rows.delete([name, pk.to_i]) }
      []
    when /\AINSERT INTO hash_tables \(setting_name,setting_query_pk,setting_query_hash\) VALUES (.+) ON DUPLICATE KEY UPDATE/
      $1.scan(/\('([^']*)','(-?\d+)','([^']*)'\)/) {|name, pk, hash| @rows[[name, pk.to_i]] = hash }
      []
    else
      raise "FakeHashTables: unexpected query: #{sql}"
    end
  end
end

# The result of a SELECT on a client that streams its results: the client is busy until its rows are read.
class FakeResult
  include Enumerable

  def initialize(rows, &on_read)
    @rows = rows
    @on_read = on_read
  end

  def each(&block)
    @on_read.call
    @rows.each(&block)
  end
end
