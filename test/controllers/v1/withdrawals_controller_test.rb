require "test_helper"

class V1::WithdrawalsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @account = Account.create!(balance: 1_000)
  end

  test "creates a withdrawal when the request payload is valid" do
    post "/v1/accounts/#{@account.id}/withdrawals",
         params: {
           idempotency_key: "req-valid",
           amount: 250
         },
         as: :json

    assert_response :created
    assert_equal "success", JSON.parse(response.body)["result"]
    assert_equal 750, JSON.parse(response.body)["balance_after_withdrawal"]
  end

  test "returns bad request when idempotency key is missing" do
    post "/v1/accounts/#{@account.id}/withdrawals",
         params: {
           amount: 250
         },
         as: :json

    assert_response :bad_request
    assert_equal "bad_request", JSON.parse(response.body)["result"]
  end

  test "returns bad request when amount is not a number" do
    post "/v1/accounts/#{@account.id}/withdrawals",
         params: {
           idempotency_key: "req-invalid-amount",
           amount: "asasdf"
         },
         as: :json

    assert_response :bad_request
    assert_equal "bad_request", JSON.parse(response.body)["result"]
  end
end
