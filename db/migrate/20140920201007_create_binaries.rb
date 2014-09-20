class CreateBinaries < ActiveRecord::Migration
  def up
    create_table :binaries do |t|
      t.string :name
      t.text   :description
    end
  end

  def down
    drop_table :binaries
  end
end
