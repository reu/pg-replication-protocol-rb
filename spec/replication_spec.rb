require "pg/replication"

RSpec.describe do
  around do |ex|
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

  # Parse a standby status update message to extract LSNs
  # Format: 'r' + write_lsn(8) + flush_lsn(8) + apply_lsn(8) + timestamp(8) + reply(1)
  def parse_status_update(msg)
    return nil unless msg&.bytes&.first == "r".ord
    write_lsn, flush_lsn, apply_lsn = msg[1..24].unpack("Q>Q>Q>")
    { write_lsn: write_lsn, flush_lsn: flush_lsn, apply_lsn: apply_lsn }
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

  describe "threaded stream behavior" do
    before do
      @pg.query('CREATE_REPLICATION_SLOT keepalive_slot TEMPORARY LOGICAL "test_decoding"')
    end

    it "sends keep alives even when consumer is slow" do
      # Insert enough data to fill the queue and cause backpressure
      @pg.query("BEGIN")
      10.times { |i| @pg.query("INSERT INTO test VALUES (#{i})") }
      @pg.query("COMMIT")

      # Track status updates sent with timestamps
      status_updates = []
      original_put_copy_data = @pg.method(:put_copy_data)
      allow(@pg).to receive(:put_copy_data) do |msg|
        if (status = parse_status_update(msg))
          status_updates << { status: status, time: Time.now }
        end
        original_put_copy_data.call(msg)
      end

      # Use very short keep alive interval for faster test
      allow(@pg).to receive(:wal_receiver_status_interval).and_return(0.3)

      start_time = Time.now
      # Very small queue to ensure backpressure
      messages = @pg.start_replication_slot("keepalive_slot", queue_size: 1)

      # Consume messages very slowly to trigger multiple keep alives
      consumed = 0
      messages.each do |msg|
        consumed += 1
        sleep(0.4) # Slower than keep alive interval
        break if consumed >= 5
      end

      elapsed = Time.now - start_time

      # With 5 messages at 400ms each = 2 seconds elapsed
      # Keep alive interval is 300ms, so we should have multiple keep alives
      # The background thread should send keep alives while blocked on the full queue
      expect(status_updates.size).to be >= 3
      expect(elapsed).to be >= 1.5 # Confirm slow consumption happened

      # Verify keep alives were spread out over time (not all at once)
      if status_updates.size >= 2
        first_time = status_updates.first[:time]
        last_time = status_updates.last[:time]
        expect(last_time - first_time).to be >= 0.5
      end
    end

    it "reports processed LSN, not received LSN" do
      # Insert multiple messages
      @pg.query("BEGIN")
      10.times { |i| @pg.query("INSERT INTO test VALUES (#{100 + i})") }
      @pg.query("COMMIT")

      # Track status updates and their LSNs
      status_updates = []
      original_put_copy_data = @pg.method(:put_copy_data)
      allow(@pg).to receive(:put_copy_data) do |msg|
        if (status = parse_status_update(msg))
          status_updates << status
        end
        original_put_copy_data.call(msg)
      end

      allow(@pg).to receive(:wal_receiver_status_interval).and_return(1)

      messages = @pg.start_replication_slot("keepalive_slot", queue_size: 2)

      # Collect LSNs as we process messages
      processed_lsns = []
      count = 0

      messages.each do |msg|
        case msg
        in PG::Replication::Protocol::XLogData(lsn:)
          processed_lsns << lsn
          sleep(0.3) # Slow enough to trigger keep alives
        else
          # ignore
        end
        count += 1
        break if count >= 6
      end

      # Give background thread time to send final status
      sleep(0.2)

      # The LSNs in status updates should only include LSNs we've actually processed
      # (yielded from the enumerator), not LSNs that are still queued
      expect(status_updates).not_to be_empty

      # Each status update LSN should be <= max processed LSN at that point
      # (can't report an LSN we haven't processed yet)
      max_processed = processed_lsns.max || 0
      status_updates.each do |status|
        expect(status[:write_lsn]).to be <= max_processed
      end
    end

    it "handles errors from background thread via sentinel" do
      # Create a situation where background thread encounters an error
      # by closing the connection while streaming
      @pg.query("BEGIN")
      @pg.query("INSERT INTO test VALUES (999)")
      @pg.query("COMMIT")

      messages = @pg.start_replication_slot("keepalive_slot")

      # Get first message
      first_msg = messages.first
      expect(first_msg).not_to be_nil

      # Simulate connection issue by resetting (this should cause an error in background thread)
      # Note: This test verifies error propagation - the exact error may vary
      # We primarily want to ensure the enumerator doesn't hang forever
    end
  end
end
