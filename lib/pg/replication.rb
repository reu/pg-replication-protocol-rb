# frozen_string_literal: true

require "pg"
require_relative "replication/version"
require_relative "replication/buffer"
require_relative "replication/pg_output"
require_relative "replication/stream"

module PG
  module Replication
    def start_replication_slot(slot, logical: true, location: "0/0", keep_alive_secs: 10, **params)
      query(<<~SQL)
        START_REPLICATION SLOT
        #{slot} #{logical ? "LOGICAL" : "PHYSICAL"} #{location}
        (#{params.map { |k, v| "#{quote_ident(k.to_s)} '#{v}'" }.join(", ")})
      SQL

      last_keep_alive = Time.now
      last_processed_lsn = 0

      Stream.new(self).lazy.filter_map do |msg|
        case msg
        in Protocol::XLogData(lsn:, data:)
          last_processed_lsn = lsn
          standby_status_update(write_lsn: last_processed_lsn)
          last_keep_alive = Time.now
          data

        in Protocol::PrimaryKeepalive(server_time:, asap: true)
          standby_status_update(write_lsn: last_processed_lsn)
          last_keep_alive = Time.now
          next

        in Protocol::PrimaryKeepalive(server_time:)
          now = Time.now
          if now - last_keep_alive > keep_alive_secs
            standby_status_update(write_lsn: last_processed_lsn)
            last_keep_alive = now
          end
          next
        end
      end
    end

    def start_pgoutput_replication_slot(slot, publication_names, **kwargs)
      publication_names = publication_names.join(",")
      start_replication_slot(slot, **kwargs.merge(proto_version: "1", publication_names:)).map do |data|
        buffer = Buffer.from_string(data.force_encoding(internal_encoding))
        PGOutput.read_message(buffer)
      end
    end

    def standby_status_update(
      write_lsn:,
      flush_lsn: write_lsn,
      apply_lsn: write_lsn,
      timestamp: Time.now,
      reply: false
    )
      msg = [
        "r".bytes.first,
        write_lsn,
        flush_lsn,
        apply_lsn,
        (timestamp - Time.new(2_000, 1, 1, 0, 0, 0, 0)) * 10**6,
        reply ? 1 : 0,
      ].pack("CQ>Q>Q>Q>C")

      put_copy_data(msg)
      flush
    end
  end

  Connection.send(:include, Replication)
end
