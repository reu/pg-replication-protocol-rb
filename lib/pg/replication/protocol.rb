# frozen_string_literal: true

module PG
  module Replication
    module Protocol
      XLogData = Data.define(:lsn, :current_lsn, :server_time, :data)
      PrimaryKeepalive = Data.define(:current_lsn, :server_time, :asap)

      def self.read_message(buffer)
        case buffer.read_char
        in "k"
          PrimaryKeepalive.new(
            current_lsn: buffer.read_int64,
            server_time: buffer.read_timestamp,
            asap: buffer.read_bool,
          )

        in "w"
          XLogData.new(
            lsn: buffer.read_int64,
            current_lsn: buffer.read_int64,
            server_time: buffer.read_timestamp,
            data: buffer.read,
          )

        in unknown
          raise "Unknown replication message type: #{unknown}"
        end
      end
    end
  end
end
