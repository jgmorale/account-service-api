module V1
  class WithdrawalsController < ApplicationController
    def create
      withdrawal = withdraw_funds.call(
        account_id: params[:account_id],
        idempotency_key: params[:idempotency_key],
        amount: params[:amount]
      )

      render json: {
        result: "success",
        balance_after_withdrawal: withdrawal.resulting_balance
      }, status: :created
    end

    private

    def withdraw_funds
      @withdraw_funds ||= WithdrawFunds.new
    end
  end
end