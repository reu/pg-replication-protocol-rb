# frozen_string_literal: true

require "pg"
require "thread"
require_relative "replication/version"
require_relative "replication/buffer"
require_relative "replication/pg_output"
require_relative "replication/protocol"

module PG
  module Replication
    DEFAULT_QUEUE_SIZE = 10_000

    StreamEnd = Object.new.freeze
    StreamError = Data.define(:exception)

    def start_replication_slot(slot, logical: true, auto_keep_alive: true, location: "0/0", queue_size: DEFAULT_QUEUE_SIZE, **params)
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

      if auto_keep_alive
        start_threaded_replication(keep_alive_secs, queue_size)
      else
        start_sync_replication
      end
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
        ((timestamp.to_r - POSTGRES_EPOCH.to_r) * 1_000_000).to_i,
        reply ? 1 : 0,
      ].pack("CQ>Q>Q>Q>C")

      status_update_mutex.synchronize do
        put_copy_data(msg)
        flush
        @last_confirmed_lsn = [@last_confirmed_lsn, write_lsn].compact.max
      end
    end

    def last_confirmed_lsn
      status_update_mutex.synchronize { @last_confirmed_lsn }
    end

    def stop_replication
      status_update_mutex.synchronize do
        put_copy_end
      end
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

    private

    def status_update_mutex
      @status_update_mutex ||= Mutex.new
    end

    def start_threaded_replication(keep_alive_secs, queue_size)
      conn = self
      queue = SizedQueue.new(queue_size)
      last_keepalive = Time.now

      thread = Thread.new do
        loop do
          break if queue.closed?

          conn.consume_input
          next if conn.is_busy

          case (data = conn.get_copy_data(async: true))
          when nil
            queue.push(StreamEnd, true) rescue nil
            conn.get_last_result
            break

          when false
            timeout = [keep_alive_secs - (Time.now - last_keepalive), 0.1].max
            IO.select([conn.socket_io], nil, nil, timeout)

            if Time.now - last_keepalive >= keep_alive_secs
              conn.standby_status_update(write_lsn: conn.last_confirmed_lsn)
              last_keepalive = Time.now
            end

          else
            msg = Protocol.read_message(Buffer.new(data))

            if msg.is_a?(Protocol::PrimaryKeepalive) && msg.asap
              conn.standby_status_update(write_lsn: msg.current_lsn)
              last_keepalive = Time.now
            end

            # Non-blocking push with keepalive retry loop
            loop do
              break if queue.closed?
              begin
                queue.push(msg, true)
                break
              rescue ThreadError
                if Time.now - last_keepalive >= keep_alive_secs
                  conn.standby_status_update(write_lsn: conn.last_confirmed_lsn)
                  last_keepalive = Time.now
                end
                sleep(0.05)
              end
            end
          end
        end
      rescue ClosedQueueError
        # Clean exit
      rescue => e
        queue.push(StreamError.new(e), true) rescue nil
      end

      Enumerator.new do |y|
        loop do
          msg = queue.pop

          case msg
          when StreamEnd
            break
          when StreamError
            raise msg.exception
          else
            y << msg

            lsn = case msg
            when Protocol::XLogData
              msg.lsn
            when Protocol::PrimaryKeepalive
              msg.current_lsn
            end

            if lsn && lsn > 0
              status_update_mutex.synchronize { @last_confirmed_lsn = lsn }
            end
          end
        end
      ensure
        queue.close
        thread.join(5)
        thread.kill if thread.alive?
      end.lazy
    end

    def start_sync_replication
      Enumerator.new do |y|
        loop do
          consume_input
          next if is_busy

          case get_copy_data(async: true)
          in nil
            get_last_result
            break
          in false
            IO.select([socket_io], nil, nil, 10)
            next
          in data
            y << Protocol.read_message(Buffer.new(data))
          end
        end
      end.lazy
    end
  end

  Connection.send(:include, Replication)
end
