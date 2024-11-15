# frozen_string_literal: true

module PG
  module Replication
    module PGOutput
      Begin = Data.define(:final_lsn, :timestamp, :xid)
      Message = Data.define(:transactional, :lsn, :prefix, :content)
      Commit = Data.define(:lsn, :end_lsn, :timestamp)
      Origin = Data.define(:commit_lsn, :name)
      Relation = Data.define(:oid, :namespace, :name, :replica_identity, :columns)
      Type = Data.define(:oid, :namespace, :name)
      Insert = Data.define(:oid, :new)
      Update = Data.define(:oid, :key, :old, :new)
      Delete = Data.define(:oid, :old)
      Truncate = Data.define(:oid)
      Tuple = Data.define(:type, :data)
      Column = Data.define(:flags, :name, :oid, :modifier) do
        def key?
          flags == 1
        end
      end

      def self.read_message(buffer)
        case buffer.read_char
        in "B"
          PGOutput::Begin.new(
            final_lsn: buffer.read_int64,
            timestamp: buffer.read_timestamp,
            xid: buffer.read_int32,
          )

        in "M"
          PGOutput::Message.new(
            transactional: buffer.read_bool,
            lsn: buffer.read_int64,
            prefix: buffer.read_cstring,
            content: case buffer.read_int32
              in 0
                nil
              in n
                buffer.read(n)
            end,
          )

        in "C"
          buffer.read_int8 # Unused byte
          PGOutput::Commit.new(
            lsn: buffer.read_int64,
            end_lsn: buffer.read_int64,
            timestamp: buffer.read_timestamp,
          )

        in "O"
          PGOutput::Origin.new(
            commit_lsn: buffer.read_int64,
            name: buffer.read_cstring,
          )

        in "R"
          PGOutput::Relation.new(
            oid: buffer.read_int32,
            namespace: buffer.read_cstring.then { |ns| ns == "" ? "pg_catalog" : ns },
            name: buffer.read_cstring,
            replica_identity: buffer.read_char,
            columns: buffer.read_int16.times.map do
              PGOutput::Column.new(
                flags: buffer.read_int8,
                name: buffer.read_cstring,
                oid: buffer.read_int32,
                modifier: buffer.read_int32,
              )
            end
          )

        in "Y"
          PGOutput::Type.new(
            oid: buffer.read_int32,
            namespace: buffer.read_cstring,
            name: buffer.read_cstring,
          )

        in "I"
          PGOutput::Insert.new(
            oid: buffer.read_int32,
            new: case a = buffer.read_char
              when "N"
                PGOutput.read_tuples(buffer)
              else
                []
              end,
          )

        in "U"
          oid = buffer.read_int32
          key = []
          new = []
          old = []

          until buffer.eof?
            case buffer.read_char
            when "K"
              key = PGOutput.read_tuples(buffer)
            when "N"
              new = PGOutput.read_tuples(buffer)
            when "O"
              old = PGOutput.read_tuples(buffer)
            end
          end

          PGOutput::Update.new(
            oid:,
            key:,
            old:,
            new:,
          )

        in "D"
          PGOutput::Delete.new(
            oid: buffer.read_int32,
            old: case buffer.read_char
              when "N", "K"
                PGOutput.read_tuples(buffer)
              else
                []
              end,
          )

        in "T"
          PGOutput::Truncate.new(
            oid: buffer.read_int32,
            data: buffer.buffer,
          )

        in unknown
          raise "Unknown PGOutput message type: #{unknown}"
        end
      end

      def self.read_tuples(buffer)
        buffer.read_int16.times.map { read_tuple(buffer) }
      end

      def self.read_tuple(buffer)
        case buffer.read_char
        in type if type == "n"
          Tuple.new(type:, data: nil)
        in type
          size = buffer.read_int32
          data = buffer.read(size)
          Tuple.new(type:, data:)
        end
      end
    end
  end
end
