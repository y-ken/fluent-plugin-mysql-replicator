require 'strscan'
require 'mysql2'

module Fluent
  module Plugin
    # The nested queries of mysql_replicator and mysql_replicator_multi: a column value such as
    # "SELECT ... WHERE parent_id = ${id}" is run for each row, with the placeholders filled from the row.
    module MysqlReplicatorNestedQuery
      # Raised when a nested query fails with an error in its SQL, which running it again does not fix.
      class SqlError < StandardError
        attr_reader :column, :error_number, :sql_state

        def initialize(column, error)
          @column = column
          @error_number = error.error_number
          @sql_state = error.sql_state
          super("the nested query of column '#{column}' failed with MySQL error #{@error_number} (SQLSTATE #{@sql_state})")
        end
      end

      # Replaces each ${column} in a nested query with the value of that column in the row.
      #
      # A placeholder inside a quoted string, such as '${name}' or '%${name}%', is escaped for that string with the
      # escape of the connection that runs the query (mysql_real_escape_string, which follows its character set and
      # NO_BACKSLASH_ESCAPES), so that a quote in the value does not end the string. A placeholder outside quotes is
      # put in as it is, so that a column can hold a part of the SQL, such as a condition. Quotes in a comment
      # (/* */, "-- " or #) do not start a string, and the placeholders in a comment are put in as they are.
      def expand_nested_query(template, row, con)
        scanner = StringScanner.new(template)
        expanded = +''
        quote = nil
        backslash_escapes = nil
        until scanner.eos?
          if scanner.scan(PLACEHOLDER)
            value = row[scanner[1]].to_s
            expanded << (quote == "'" || quote == '"' ? con.escape(value) : value)
          elsif quote.nil? && scanner.scan(COMMENT)
            expanded << scanner.matched.gsub(PLACEHOLDER) { row[$1].to_s }
          elsif (quote == "'" || quote == '"') && scanner.check(/\\./m) &&
                (backslash_escapes = backslash_escapes?(con, backslash_escapes))
            expanded << scanner.scan(/\\./m)
          elsif scanner.scan(/['"`]/)
            if quote.nil?
              quote = scanner.matched
            elsif quote == scanner.matched
              quote = nil
            end
            expanded << scanner.matched
          else
            expanded << scanner.scan(%r{[^$'"`\\/#-]+|.}m)
          end
        end
        expanded
      end

      PLACEHOLDER = /\$\{([^\}]+)\}/
      # A comment of MySQL. "/*!" and "/*+" are run as SQL (a versioned statement, an optimizer hint), so they are not.
      COMMENT = %r{/\*(?![!+]).*?(?:\*/|\z)|--(?=[ \t\r\n]|\z)[^\n]*|\#[^\n]*}m

      # Whether a backslash in a string is an escape in the session of the connection, which it is not with
      # NO_BACKSLASH_ESCAPES. The escape of the connection tells: it doubles a backslash only without it.
      def backslash_escapes?(con, known)
        known.nil? ? con.escape('\\') != '\\' : known
      end

      # Whether a MySQL error is in the SQL or in the data, so that running the query again fails the same way:
      # SQLSTATE class 42 (such as a syntax error, an unknown column or table, or a denied command), 22 (a data
      # exception) or 21 (such as a subquery that returns more than one row). A lost connection and other errors
      # of the server or the client are not.
      def sql_error?(error)
        error.is_a?(Mysql2::Error) && error.sql_state.to_s.start_with?('42', '22', '21')
      end
    end
  end
end
