require "test_helper"

class EntryManualOrderingTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:depository)
    @date = 5.days.ago.to_date
    @ids = nil

    @first = @account.entries.create!(name: "First", date: @date, amount: 10, currency: "USD", entryable: Transaction.new, created_at: 3.days.ago)
    @second = @account.entries.create!(name: "Second", date: @date, amount: 20, currency: "USD", entryable: Transaction.new, created_at: 2.days.ago)
    @third = @account.entries.create!(name: "Third", date: @date, amount: 30, currency: "USD", entryable: Transaction.new, created_at: 1.day.ago)
    @ids = [ @first.id, @second.id, @third.id ]
  end

  test "manual scopes match legacy scopes when no positions are set" do
    scope = @account.entries.where(id: @ids)

    assert_equal scope.chronological.map(&:id), scope.chronological_with_manual.map(&:id)
    assert_equal scope.reverse_chronological.map(&:id), scope.reverse_chronological_with_manual.map(&:id)
  end

  test "manual positions reorder the chronological walk with NULLs last" do
    @third.update!(manual_position: 0)
    @first.update!(manual_position: 1)
    # @second stays NULL and sorts after positioned rows, in created_at order.

    walk = @account.entries.where(id: @ids).chronological_with_manual.map(&:id)

    assert_equal [ @third.id, @first.id, @second.id ], walk
  end

  test "reverse scope mirrors the manual walk for display" do
    @third.update!(manual_position: 0)
    @first.update!(manual_position: 1)

    display = @account.entries.where(id: @ids).reverse_chronological_with_manual.map(&:id)

    assert_equal [ @second.id, @first.id, @third.id ], display
  end

  test "valuations stay pinned with manual positions present" do
    valuation = @account.entries.create!(name: "Valuation", date: @date, amount: 999, currency: "USD", entryable: Valuation.new(kind: "reconciliation"), created_at: 12.hours.ago)
    valuation.update!(manual_position: 0)
    @third.update!(manual_position: 0)
    ids = @ids + [ valuation.id ]
    scope = @account.entries.where(id: ids)

    assert_equal [ @third.id, @first.id, @second.id, valuation.id ], scope.chronological_with_manual.map(&:id)
    assert_equal [ valuation.id, @second.id, @first.id, @third.id ], scope.reverse_chronological_with_manual.map(&:id)
  end
end
