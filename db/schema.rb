# encoding: UTF-8
# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# Note that this schema.rb definition is the authoritative source for your
# database schema. If you need to create the application database on another
# system, you should be using db:schema:load, not running all the migrations
# from scratch. The latter is a flawed and unsustainable approach (the more migrations
# you'll amass, the slower it'll run and the greater likelihood for issues).
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema.define(version: 20140920215248) do

  create_table "binaries", force: :cascade do |t|
    t.string   "name"
    t.binary   "properties"
    t.string   "filename"
    t.string   "comment"
    t.datetime "created_at"
    t.datetime "updated_at"
  end

  create_table "workspaces", force: :cascade do |t|
    t.integer  "binary_id"
    t.string   "name"
    t.binary   "properties"
    t.binary   "undo_buffer"
    t.binary   "redo_buffer"
    t.binary   "segments"
    t.binary   "refs"
    t.binary   "xrefs"
    t.integer  "revision"
    t.datetime "created_at"
    t.datetime "updated_at"
  end

end
