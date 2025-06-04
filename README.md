# PG::Replication

Adds support to `pg` for listening to replication slots

## Usage

Add to your Gemfile:

```ruby
gem "pg-replication-protocol", require: "pg/replication"
```

## Demo

```ruby
require "pg"
require "pg/replication"

# It is important to create a connection with the `replication: "database"` option
connection = PG.connect(..., replication: "database")

# Create a publication and a slot (in a real use case the slot will not be temporary)
connection.query("CREATE PUBLICATION some_publication FOR ALL TABLES")
connection.query('CREATE_REPLICATION_SLOT some_slot TEMPORARY LOGICAL "pgoutput"')

# Just a storage for our table relation data
tables = {}

# Start a pgoutput plugin replication slot message stream
# The `messages: true` option is required to be able to decode `PG::Replication::PGOutput::Message`
connection.start_pgoutput_replication_slot(slot, publications, messages: true).each do |msg|
  case msg
  in PG::Replication::PGOutput::Relation(oid:, name:, columns:)
    # This message is received on the first row of each table, or when there are schema changes
    tables[oid] = { name:, columns: }

  in PG::Replication::PGOutput::Begin
    puts "Transaction start"

  in PG::Replication::PGOutput::Commit
    puts "Transaction end"

  in PG::Replication::PGOutput::Insert(oid:, new:)
    puts "Insert #{tables[oid][:name]}"
    new.zip(tables[oid][:columns]).each do |tuple, col|
      puts "#{col.name}: #{tuple.data || "NULL"}"
    end

  in PG::Replication::PGOutput::Update(oid:, new:, old:)
    puts "Update #{tables[oid][:name]}"
    if !old.empty? && new != old
      new.zip(old, tables[oid][:columns]).each do |new, old, col|
        if new != old
          puts "Changed #{col.name}: #{old.data || "NULL"} > #{new.data || "NULL"}"
        end
      end
    end

  in PG::Replication::PGOutput::Delete(oid:)
    puts "Delete #{tables[oid][:name]}"

  in PG::Replication::PGOutput::Message(prefix:, content:)
    puts "Message #{prefix}: #{content}"

  else
    nil
  end
end
```
