# frozen_string_literal: true

require "pg"
require_relative "replication/version"
require_relative "replication/buffer"
require_relative "replication/pg_output"
require_relative "replication/stream"

module PG
  module Replication
    def start_pgoutput_replication_slot(slot, publications, location: "0/0", keep_alive_secs: 10)
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

      stream = Stream.new(self)
      stream.lazy.map do |msg|
        case msg
        in Protocol::XLogData(lsn:, data:)
          buffer = Buffer.from_string(data.force_encoding(internal_encoding))
          PGOutput.read_message(buffer).tap do
            last_processed_lsn = lsn
            stream.standby_status_update(write_lsn: last_processed_lsn)
          end

        in Protocol::PrimaryKeepalive(server_time:, asap: true)
          stream.standby_status_update(write_lsn: last_processed_lsn)
          last_keep_alive = Time.now
          next

        in Protocol::PrimaryKeepalive(server_time:)
          now = Time.now
          if now - last_keep_alive > keep_alive_secs
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
