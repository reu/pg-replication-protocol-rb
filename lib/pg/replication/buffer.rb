# frozen_string_literal: true

module PG
  module Replication
    POSTGRES_EPOCH = Time.utc(2000, 1, 1).freeze
    POSTGRES_EPOCH_USECS = (POSTGRES_EPOCH.to_r * 1_000_000).to_i

    class Buffer
      def initialize(data)
        @data = data
        @pos = 0
      end

      def self.from_string(str)
        new(str.b)
      end

      def eof?
        @pos >= @data.bytesize
      end

      def read(n = nil)
        return nil if @pos >= @data.bytesize
        if n.nil?
          result = @data.byteslice(@pos..-1)
          @pos = @data.bytesize
        else
          result = @data.byteslice(@pos, n)
          @pos += result.bytesize
        end
        result
      end

      def readbyte
        raise EOFError if @pos >= @data.bytesize
        byte = @data.getbyte(@pos)
        @pos += 1
        byte
      end

      def read_char
        readbyte.chr
      end

      def read_bool
        readbyte == 1
      end

      def read_int8
        readbyte
      end

      def read_int16
        read_bytes(2).unpack1("n")
      end

      def read_int32
        read_bytes(4).unpack1("N")
      end

      def read_int64
        read_bytes(8).unpack1("Q>")
      end

      def read_timestamp
        usecs = POSTGRES_EPOCH_USECS + read_int64
        Time.at(usecs / 1_000_000, usecs % 1_000_000, :microsecond, in: "UTC")
      end

      def read_cstring
        null_pos = @data.index("\0", @pos)
        raise EOFError, "Unterminated C-string" if null_pos.nil?

        str = @data.byteslice(@pos, null_pos - @pos)
        @pos = null_pos + 1 # Skip past null terminator
        str
      end

      private

      def read_bytes(n)
        raise EOFError if @pos + n > @data.bytesize
        result = @data.byteslice(@pos, n)
        @pos += n
        result
      end
    end
  end
end
