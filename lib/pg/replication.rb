# frozen_string_literal: true

require "pg"
require_relative "replication/version"
require_relative "replication/buffer"
require_relative "replication/pg_output"
require_relative "replication/protocol"

module PG
  module Replication
    def start_replication_slot(slot, logical: true, location: "0/0", **params)
      keep_alive_secs = query(<<~SQL).getvalue(0, 0)&.to_i || 10
        SELECT setting FROM pg_catalog.pg_settings WHERE name = 'wal_receiver_status_interval'
      SQL

      query(<<~SQL)
        START_REPLICATION SLOT
        #{slot} #{logical ? "LOGICAL" : "PHYSICAL"} #{location}
        (#{params.map { |k, v| "#{quote_ident(k.to_s)} '#{escape_string(v.to_s)}'" }.join(", ")})
      SQL

      last_processed_lsn = 0
      last_keep_alive = Time.now

      Enumerator
        .new do |y|
          loop do
            if Time.now - last_keep_alive > keep_alive_secs
              standby_status_update(write_lsn: last_processed_lsn)
              last_keep_alive = Time.now
            end

            consume_input
            next if is_busy

            case get_copy_data(async: true)
            in nil
              get_last_result
              break

            in false
              IO.select([socket_io], nil, nil, keep_alive_secs)
              next

            in data
              buffer = Buffer.new(StringIO.new(data))
              y << Protocol.read_message(buffer)
            end
          end
        end
        .lazy
        .filter_map do |msg|
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

          else
            next
          end
        end
    end

    def start_pgoutput_replication_slot(slot, publication_names, **kwargs)
      publication_names = publication_names.join(",")

      start_replication_slot(slot, **kwargs.merge(proto_version: "1", publication_names:))
        .map { |data| data.force_encoding(internal_encoding) }
        .map { |data| PGOutput.read_message(Buffer.from_string(data)) }
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
