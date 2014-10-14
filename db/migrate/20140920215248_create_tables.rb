class CreateTables < ActiveRecord::Migration
  def up()
    create_table(:binaries)  do |t|
#      t.string(:id, :limit => 36, :primary => true, :null => false)

      t.string(:name)
      t.string(:filename)
      t.string(:arch)
      t.integer(:base_address)
      t.string(:comment)
      t.boolean(:is_processed)

      t.timestamps()
    end

    create_table(:workspaces) do |t|
      t.belongs_to(:binary)

      t.string(:name)
      t.text(:settings)

      t.timestamps()
    end

    create_table(:memory_abstractions) do |t|
      t.belongs_to(:workspace)

      t.string(:name)
      t.text(:deltas)

      t.timestamps()
    end
  end

  def down()
    drop_table :binaries
    drop_table :projects
    drop_table :memory_deltas
  end
end
