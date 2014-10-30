class CreateTables < ActiveRecord::Migration
  def up()
    create_table(:binaries)  do |t|
#      t.string(:id, :limit => 36, :primary => true, :null => false)

      t.string(:name)
      t.string(:filename)
      t.string(:comment)

      t.timestamps()
    end

    create_table(:workspaces) do |t|
      t.belongs_to(:binary)

      t.string(:name)
      t.text(:settings)

      t.timestamps()
    end

    create_table(:memories) do |t|
      t.belongs_to(:workspace)

      t.string(:name)
      t.text(:deltas)
      t.text(:undo_buffer)
      t.text(:redo_buffer)
      t.text(:snapshot)

      t.timestamps()
    end
  end

  def down()
    drop_table :binaries
    drop_table :projects
    drop_table :memory_deltas
  end
end
