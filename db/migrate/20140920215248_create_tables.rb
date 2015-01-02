class CreateTables < ActiveRecord::Migration
  def up()
    create_table(:binaries)  do |t|
#      t.string(:id, :limit => 36, :primary => true, :null => false)

      t.string(:name)
      t.binary(:properties)

      t.string(:filename)
      t.string(:comment)

      t.timestamps()
    end

    create_table(:workspaces) do |t|
      t.belongs_to(:binary)

      t.string(:name)
      t.binary(:properties)

      t.binary(:undo_buffer)
      t.binary(:redo_buffer)
      t.binary(:segments)
      t.binary(:refs)
      t.binary(:xrefs)

      t.integer(:revision)

      t.timestamps()
    end
  end

  def down()
    drop_table :binaries
    drop_table :workspaces
  end
end
