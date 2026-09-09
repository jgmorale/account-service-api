module V1
  class WithdrawalsController < ApplicationController
    def create
      validated = withdrawal_params

      withdrawal = withdraw_funds.call(
        account_id: account_id,
        idempotency_key: validated[:idempotency_key],
        amount: validated[:amount]
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

    def withdrawal_params
      params.require(:idempotency_key)
      params.require(:amount)

      permitted = params.permit(:idempotency_key, :amount)

      idempotency_key = permitted[:idempotency_key]
      amount = permitted[:amount]

      unless idempotency_key.is_a?(String) && idempotency_key.present?
        raise ActionController::BadRequest,
              "idempotency_key must be a non-empty string"
      end

      unless amount.is_a?(Integer)
        raise ActionController::BadRequest,
              "amount must be an integer"
      end

      {
        idempotency_key: idempotency_key,
        amount: amount
      }
    end

    def account_id
      Integer(params[:account_id], 10)
    rescue ArgumentError, TypeError
      raise ActionController::BadRequest, "account_id must be an integer"
    end
  end
end