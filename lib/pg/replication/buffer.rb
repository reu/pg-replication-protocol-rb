# frozen_string_literal: true

require "delegate"
require "stringio"

module PG
  module Replication
    class Buffer < SimpleDelegator
      def self.from_string(str)
        new(StringIO.new(str))
      end

      def read_char
        read_int8.chr
      end

      def read_bool
        read_int8 == 1
      end

      def read_int8
        readbyte
      end

      def read_int16
        read_bytes(2).unpack("n").first
      end

      def read_int32
        read_bytes(4).unpack("N").first
      end

      def read_int64
        read_bytes(8).unpack("Q>").first
      end

      def read_timestamp
        usecs = Time.new(2_000, 1, 1, 0, 0, 0, 0).to_i * 10**6 + read_int64
        Time.at(usecs / 10**6, usecs % 10**6, :microsecond)
      end

      def read_cstring
        str = String.new
        loop do
          case read_char
          in "\0"
            return str
          in chr
            str << chr
          end
        end
      end

      private

      def read_bytes(n)
        bytes = read(n)
        raise EOFError if bytes.nil? || bytes.size < n
        bytes
      end
    end
  end
end
