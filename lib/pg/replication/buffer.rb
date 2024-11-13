# frozen_string_literal: true

require "stringio"

module PG
  module Replication
    class Buffer
      attr_reader :buffer

      def self.from_string(str)
        new(StringIO.new(str))
      end

      def initialize(buffer)
        @buffer = buffer
      end

      def read_char
        read_int8.chr
      end

      def read_bool
        read_int8 == 1
      end

      def read_int8
        @buffer.read(1).unpack("C").first
      end

      def read_int16
        @buffer.read(2).unpack("n").first
      end

      def read_int32
        @buffer.read(4).unpack("N").first
      end

      def read_int64
        @buffer.read(8).unpack("Q>").first
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

      def read(size = nil)
        @buffer.read(size)
      end

      def eof?
        @buffer.eof?
      end
    end
  end
end
