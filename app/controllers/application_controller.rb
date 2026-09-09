class ApplicationController < ActionController::API
  rescue_from AccountNotFoundError, with: :render_account_not_found
  rescue_from InvalidAmountError, with: :render_invalid_amount
  rescue_from InsufficientFundsError, with: :render_insufficient_funds
  rescue_from ActionController::ParameterMissing, with: :render_bad_request
  rescue_from ActionController::BadRequest, with: :render_bad_request

  private

  def render_account_not_found(error)
    render json: {
      result: "account_not_found",
      message: error.message
    }, status: :not_found
  end

  def render_invalid_amount(error)
    render json: {
      result: "bad_request",
      message: error.message
    }, status: :bad_request
  end

  def render_insufficient_funds(error)
    render json: {
      result: "insufficient_funds",
      message: error.message
    }, status: :unprocessable_entity
  end

  def render_bad_request(error)
    render json: {
      result: "bad_request",
      message: error.message
    }, status: :bad_request
  end
end