class CreateBinaries < ActiveRecord::Migration
  def up()
    create_table(:binaries, :id => false)  do |t|
      t.string(:id, :limit => 36, :primary => true, :null => false)

      t.string(:name)
      t.string(:filename)
      t.integer(:base_address)
      t.string(:comment)
      t.boolean(:is_processed)

      # This will be a serialized array (or maybe hash)
      t.text(:instructions)

      t.timestamps()
    end
  end

  def down()
    drop_table :binaries
  end
end
