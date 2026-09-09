# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[7.0].define(version: 2026_09_09_025742) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "plpgsql"

  create_table "accounts", force: :cascade do |t|
    t.integer "balance", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "withdrawals", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.string "idempotency_key", null: false
    t.integer "amount", null: false
    t.integer "resulting_balance", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "idempotency_key"], name: "index_withdrawals_on_account_id_and_idempotency_key", unique: true
    t.index ["account_id"], name: "index_withdrawals_on_account_id"
  end

  add_foreign_key "withdrawals", "accounts"
end
