# frozen_string_literal: true

require_relative "buffer"
require_relative "protocol"

module PG
  module Replication
    class Stream
      include Enumerable

      def initialize(connection)
        @connection = connection
      end

      def each
        loop do
          @connection.consume_input

          next if @connection.is_busy

          case @connection.get_copy_data(async: true)
          in nil
            return @connection.get_last_result
          in false
            IO.select([@connection.socket_io], nil, nil)
            next
          in data
            buffer = Buffer.new(StringIO.new(data))
            yield Protocol.read_message(buffer)
          end
        end
      end
    end
  end
end
