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
    rows = (@responder.call(sql) || []).map(&:dup)
    return rows unless sql =~ /\A\s*SELECT/i
    @unread = FakeResult.new(rows) { @unread = nil }
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
