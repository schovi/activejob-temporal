# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.

ActiveRecord::Schema[8.0].define(version: 2026_05_21_000000) do
  create_table "email_subscribers", force: :cascade do |t|
    t.string "email", null: false
    t.string "name", null: false
    t.boolean "subscribed", default: true, null: false
    t.string "last_campaign_name"
    t.datetime "last_campaign_sent_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_email_subscribers_on_email", unique: true
  end
end
