class WithdrawFunds
  def call(account_id:, idempotency_key:, amount:)
    raise "Amount should be greater than 0. Current value: #{amount}" if amount <= 0

    Account.transaction do
      account = Account.lock.find_by(id: account_id)
      raise "Account not found" if account.blank?

      withdrawal = Withdrawal.find_by(
                                       account_id: account_id,
                                       idempotency_key: idempotency_key
                                      )
      next withdrawal if withdrawal.present?

      raise "Insufficient funds" if account.balance < amount

      account.update!( balance: account.balance - amount )

      Withdrawal.create!(
                          account_id: account_id,
                          idempotency_key: idempotency_key,
                          amount: amount,
                          resulting_balance: account.balance
                        )
    end
  end
end