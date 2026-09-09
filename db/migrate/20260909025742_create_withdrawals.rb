class CreateWithdrawals < ActiveRecord::Migration[7.0]
  def change
    create_table :withdrawals do |t|
      t.references :account, null: false, foreign_key: true
      t.string :idempotency_key, null: false
      t.integer :amount, null: false
      t.integer :resulting_balance, null: false

      t.timestamps
    end

    add_index :withdrawals,
              [:account_id, :idempotency_key],
              unique: true
  end
end
