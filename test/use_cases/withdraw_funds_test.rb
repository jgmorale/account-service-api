require "test_helper"

class WithdrawFundsTest < ActiveSupport::TestCase
  setup do
    @account = Account.create!(balance: 1_000)
    @use_case = WithdrawFunds.new
  end

  test "withdraws funds and creates a withdrawal record" do
    withdrawal = @use_case.call(
      account_id: @account.id,
      idempotency_key: "req-1",
      amount: 250
    )

    assert_equal @account.id, withdrawal.account_id
    assert_equal 250, withdrawal.amount
    assert_equal 750, withdrawal.resulting_balance
    assert_equal 750, @account.reload.balance
    assert_equal "req-1", withdrawal.idempotency_key
    assert_equal 1, Withdrawal.where(account_id: @account.id).count
  end

  test "returns the existing withdrawal for the same idempotency key" do
    first = @use_case.call(
      account_id: @account.id,
      idempotency_key: "req-duplicate",
      amount: 250
    )

    second = @use_case.call(
      account_id: @account.id,
      idempotency_key: "req-duplicate",
      amount: 500
    )

    assert_equal first.id, second.id
    assert_equal 750, @account.reload.balance
    assert_equal 1, Withdrawal.where(account_id: @account.id).count
  end

  test "serializes concurrent withdrawals and rejects the second when funds are no longer available" do
    account = Account.create!(balance: 1_000)
    first_requested = Queue.new
    second_requested = Queue.new

    first_thread = Thread.new do
      first_requested << true
      @use_case.call(
        account_id: account.id,
        idempotency_key: "req-concurrent-1",
        amount: 600
      )
    end

    first_requested.pop
    sleep 0.05

    second_thread = Thread.new do
      second_requested << true
      @use_case.call(
        account_id: account.id,
        idempotency_key: "req-concurrent-2",
        amount: 600
      )
    rescue => e
      e
    end

    second_requested.pop

    first_result = first_thread.value
    second_result = second_thread.value

    assert_equal 600, first_result.amount
    assert_equal 400, account.reload.balance
    assert_instance_of InsufficientFundsError, second_result
    assert_equal "InsufficientFundsError", second_result.message
    assert_equal 1, Withdrawal.where(account_id: account.id).count
  end

  test "raises an InvalidAmountError when amount is not positive" do
    error = assert_raises(InvalidAmountError) do
      @use_case.call(
        account_id: @account.id,
        idempotency_key: "req-invalid-amount",
        amount: 0
      )
    end

    assert_equal "Amount must be greater than 0", error.message
  end

  test "raises an AccountNotFoundError when the account does not exist" do
    error = assert_raises(AccountNotFoundError) do
      @use_case.call(
        account_id: 999_999,
        idempotency_key: "req-unknown-account",
        amount: 100
      )
    end

    assert_equal "Account 999999 not found", error.message
  end

  test "raises an InsufficientFundsError when the balance is insufficient" do
    error = assert_raises(InsufficientFundsError) do
      @use_case.call(
        account_id: @account.id,
        idempotency_key: "req-insufficient-funds",
        amount: 1_001
      )
    end

    assert_equal "InsufficientFundsError", error.message
  end
end
