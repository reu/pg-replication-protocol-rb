# frozen_string_literal: true

require "pg"
require_relative "version"
require_relative "buffer"
require_relative "pg_output"
require_relative "stream"

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
            data: buffer
              .read
              .then { |msg| Buffer.from_string(msg) }
              .then { |msg| PGOutput.read_message(msg) },
          )

        in unknown
          raise "Unknown replication message type: #{unknown}"
        end
      end
    end

    def start_pgoutput_replication_slot(slot, publications, location: "0/0", keep_alive_time: 10)
      publications = Array(publications)
        .map { |name| quote_ident(name) }
        .map { |name| "'#{name}'" }
        .join(",")

      query(<<~SQL)
        START_REPLICATION SLOT
        #{slot} LOGICAL #{location}
        ("proto_version" '1', "publication_names" #{publications})
      SQL

      last_keep_alive = Time.now
      last_processed_lsn = 0

      stream = PG::Replication::Stream.new(self)
      stream.lazy.map do |msg|
        case msg
        in PG::Replication::Protocol::XLogData(lsn:, data:)
          last_processed_lsn = lsn
          data
        in PG::Replication::Protocol::PrimaryKeepalive(server_time:, asap: true)
          stream.standby_status_update(write_lsn: last_processed_lsn)
          next
        in PG::Replication::Protocol::PrimaryKeepalive(server_time:)
          now = Time.now
          if now - last_keep_alive > keep_alive_time
            stream.standby_status_update(write_lsn: last_processed_lsn)
            last_keep_alive = now
          end
          next
        end
      end
    end
  end

  Connection.send(:include, Replication)
end
