module V1
  class WithdrawalsController < ApplicationController
    def create
      withdrawal = withdraw_funds.call(
        account_id: params[:account_id],
        idempotency_key: withdrawal_params[:idempotency_key],
        amount: withdrawal_params[:amount]
      )
        
      render json: {
        result: "success",
        balance_after_withdrawal: withdrawal.resulting_balance
      }, status: :ok
    end

    private

    def withdraw_funds
      @withdraw_funds ||= WithdrawFunds.new
    end

    def withdrawal_params
      params.require(:idempotency_key)
      params.require(:amount)

      permitted = params.permit(:idempotency_key, :amount)

      unless permitted[:idempotency_key].is_a?(String)
        raise ActionController::BadRequest, "idempotency_key must be a string"
      end

      unless permitted[:amount].is_a?(Integer)
        raise ActionController::BadRequest, "amount must be an integer"
      end

      permitted
    end
  end
end