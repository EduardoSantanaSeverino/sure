require "test_helper"

class Account::RunningBalanceManualOrderTest < ActiveSupport::TestCase
  include LedgerTestingHelper

  # Mirrors the reported August-22 case: three same-day flows recorded in an
  # order that differs from when they actually happened (transfer recorded
  # first, interest last). The legacy walk produces a negative intermediate;
  # manual positions restore the true order with the same day-end total.
  #
  # Ledger sign: positive amount = outflow, negative = inflow (inverse of
  # display). Opening balance 32774.16; transfer -32629.75; fee -150.00;
  # interest +5.59.
  setup do
    @date = 5.days.ago.to_date

    @account = create_account_with_ledger(
      account: { type: Depository, currency: "USD" },
      entries: [
        { type: "opening_anchor", date: @date - 1.day, balance: 32774.16 }
      ]
    )

    Balance::Materializer.new(@account, strategy: :forward).materialize_balances

    @transfer = @account.entries.create!(name: "Transfer", date: @date, amount: 32629.75, currency: "USD", entryable: Transaction.new, created_at: Time.utc(@date.year, @date.month, @date.day, 9, 0, 0))
    @fee = @account.entries.create!(name: "Fee", date: @date, amount: 150, currency: "USD", entryable: Transaction.new, created_at: Time.utc(@date.year, @date.month, @date.day, 10, 0, 0))
    @interest = @account.entries.create!(name: "Interest", date: @date, amount: -5.59, currency: "USD", entryable: Transaction.new, created_at: Time.utc(@date.year, @date.month, @date.day, 11, 0, 0))
    @entries = [ @transfer, @fee, @interest ]
  end

  test "legacy walk follows record order including the negative intermediate" do
    balances = Account::RunningBalanceCalculator.new(@entries).running_balances

    assert_equal 144.41, balances[@transfer.id].amount
    assert_equal(-5.59, balances[@fee.id].amount)
    assert_equal 0.0, balances[@interest.id].amount
  end

  test "manual positions restore occurrence order without changing the day-end total" do
    @interest.update!(manual_position: 0)
    @transfer.update!(manual_position: 1)
    @fee.update!(manual_position: 2)

    balances = Account::RunningBalanceCalculator.new(@entries).running_balances

    assert_equal 32779.75, balances[@interest.id].amount
    assert_equal 150.0, balances[@transfer.id].amount
    assert_equal 0.0, balances[@fee.id].amount
  end
end
