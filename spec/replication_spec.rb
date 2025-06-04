require "pg/replication"

RSpec.describe do
  around(:context) do |ex|
    pg_container = RSpec.configuration.postgres_container
    @pg = PG.connect(
      dbname: pg_container.username,
      host: pg_container.host,
      user: pg_container.username,
      password: pg_container.password,
      port: pg_container.first_mapped_port,
      replication: "database",
    )
    @pg.query("CREATE TABLE IF NOT EXISTS test(num integer)")
    @pg.query("ALTER TABLE test REPLICA IDENTITY FULL")
    ex.run
  ensure
    @pg.close
  end

  def xlog_data(msg)
    case msg
    in PG::Replication::Protocol::XLogData(data:)
      data
    else
      nil
    end
  end

  describe "#start_replication_slot" do
    before do
      @pg.query('CREATE_REPLICATION_SLOT test_slot TEMPORARY LOGICAL "test_decoding"')
    end

    it "returns a replication message stream" do
      @pg.query("BEGIN")
      @pg.query("INSERT INTO test VALUES (10)")
      @pg.query("UPDATE test SET num = 20 WHERE num = 10")
      @pg.query("DELETE FROM test WHERE num = 20")
      @pg.query("SELECT * FROM pg_logical_emit_message(true, 'test', 'message')")
      @pg.query("COMMIT")

      messages = @pg.start_replication_slot("test_slot")
      begin_txn, insert, update, delete, msg, commit_txn = messages.filter_map { xlog_data(_1) }.take(6).to_a

      expect(begin_txn).to include("BEGIN")
      expect(insert).to include("INSERT: num[integer]:10")
      expect(update).to include("num[integer]:20")
      expect(delete).to include("DELETE")
      expect(msg).to include('test')
      expect(msg).to include('message')
      expect(commit_txn).to include("COMMIT")
    end
  end

  describe "#start_pgoutput_replication_slot" do
    before do
      @pg.query('CREATE_REPLICATION_SLOT test_slot_pgoutput TEMPORARY LOGICAL "pgoutput"')
      @pg.query("CREATE PUBLICATION test_pub FOR TABLE test")
    end

    it "returns a decoded pgoutput message stream" do
      @pg.query("BEGIN")
      @pg.query("INSERT INTO test VALUES (10)")
      @pg.query("UPDATE test SET num = 20 WHERE num = 10")
      @pg.query("DELETE FROM test WHERE num = 20")
      @pg.query("SELECT * FROM pg_logical_emit_message(true, 'test', 'message')")
      @pg.query("COMMIT")

      messages = @pg.start_pgoutput_replication_slot("test_slot_pgoutput", ["test_pub"], messages: true)
      start, relation, insert, update, delete, msg, commit = messages.filter_map { xlog_data(_1) }.take(7).to_a

      expect(start).to match_pattern(PG::Replication::PGOutput::Begin)

      expect(relation).to match_pattern(PG::Replication::PGOutput::Relation)

      expect(insert).to match_pattern(PG::Replication::PGOutput::Insert)
      expect(insert.new[0].data).to eq("10")

      expect(update).to match_pattern(PG::Replication::PGOutput::Update)
      expect(update.old[0].data).to eq("10")
      expect(update.new[0].data).to eq("20")

      expect(delete).to match_pattern(PG::Replication::PGOutput::Delete)
      expect(delete.old[0].data).to eq("20")

      expect(msg).to match_pattern(PG::Replication::PGOutput::Message)
      expect(msg.prefix).to eq("test")
      expect(msg.content).to eq("message")

      expect(commit).to match_pattern(PG::Replication::PGOutput::Commit)
    end
  end
end
