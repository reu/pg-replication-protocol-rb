# frozen_string_literal: true

require "pg"
require_relative "replication/version"
require_relative "replication/buffer"
require_relative "replication/pg_output"
require_relative "replication/protocol"

module PG
  module Replication
    def start_replication_slot(slot, logical: true, auto_keep_alive: true, location: "0/0", **params)
      keep_alive_secs = wal_receiver_status_interval
      @last_confirmed_lsn = confirmed_slot_lsn(slot) || 0

      start_query = "START_REPLICATION SLOT #{slot} #{logical ? "LOGICAL" : "PHYSICAL"} #{location}"
      unless params.empty?
        start_query << "("
        start_query << params
          .map { |k, v| "#{quote_ident(k.to_s)} '#{escape_string(v.to_s)}'" }
          .join(", ")
        start_query << ")"
      end
      query(start_query)

      last_keep_alive = Time.now

      Enumerator
        .new do |y|
          loop do
            if auto_keep_alive && Time.now - last_keep_alive > keep_alive_secs
              standby_status_update(write_lsn: @last_confirmed_lsn)
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
              case (msg = Protocol.read_message(Buffer.new(StringIO.new(data))))
              in Protocol::XLogData(lsn:, data:) if auto_keep_alive
                y << msg
                standby_status_update(write_lsn: lsn) if lsn > 0
                last_keep_alive = Time.now

              in Protocol::PrimaryKeepalive(current_lsn:, server_time:, asap: true) if auto_keep_alive
                standby_status_update(write_lsn: current_lsn)
                last_keep_alive = Time.now
                y << msg

              in Protocol::PrimaryKeepalive(current_lsn:)
                y << msg
                @last_confirmed_lsn = [@last_confirmed_lsn, current_lsn].compact.max

              else
                y << msg
              end
            end
          end
        end
        .lazy
    end

    def start_pgoutput_replication_slot(slot, publication_names, **kwargs)
      publication_names = publication_names.join(",")

      start_replication_slot(slot, **kwargs.merge(proto_version: "1", publication_names:))
        .map do |msg|
          case msg
          in Protocol::XLogData(data:, lsn:)
            data = data.force_encoding(internal_encoding)
            msg.with(data: PGOutput.read_message(Buffer.from_string(data)))
          else
            msg
          end
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
      @last_confirmed_lsn = [@last_confirmed_lsn, write_lsn].compact.max
    end

    def last_confirmed_lsn
      @last_confirmed_lsn
    end

    def wal_receiver_status_interval
      query(<<~SQL).getvalue(0, 0)&.to_i || 10
        SELECT setting FROM pg_catalog.pg_settings WHERE name = 'wal_receiver_status_interval'
      SQL
    end

    def confirmed_slot_lsn(slot)
      lsn = query(<<~SQL).getvalue(0, 0)
        SELECT confirmed_flush_lsn FROM pg_replication_slots WHERE slot_name = '#{slot}'
      SQL
      high, low = lsn.split("/")
      (high.to_i(16) << 32) + low.to_i(16)
    rescue StandardError
      nil
    end
  end

  Connection.send(:include, Replication)
end
