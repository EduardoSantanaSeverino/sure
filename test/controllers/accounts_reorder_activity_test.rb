require "test_helper"

class AccountsReorderActivityTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    sign_in @user = users(:family_admin)
    @account = accounts(:depository)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true, "transactions_compact" => true, "transactions_group_by_date" => false))
    @date = 5.days.ago.to_date
  end

  test "stores walk order from submitted display order and streams the day" do
    first = create_transaction(account: @account, name: "Reorder A", date: @date, amount: 10, created_at: 3.days.ago)
    second = create_transaction(account: @account, name: "Reorder B", date: @date, amount: 20, created_at: 2.days.ago)
    third = create_transaction(account: @account, name: "Reorder C", date: @date, amount: 30, created_at: 1.day.ago)

    # Display order is top-to-bottom (reverse chronological): C, B, A.
    # Submitting C, A, B means the walk becomes B, A, C.
    patch reorder_activity_account_path(@account),
      params: { date: @date.iso8601, entry_ids: [ third.id, first.id, second.id ], grouped: false },
      headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html", response.media_type
    assert_includes response.body, %(target="activity_day_#{@date.iso8601}")

    # Walk order is second, first, third regardless of other entries that
    # may share the date (untouched siblings keep earlier positions).
    second_position = second.reload.manual_position
    assert_equal second_position + 1, first.reload.manual_position
    assert_equal second_position + 2, third.reload.manual_position

    # Stream renders the submitted rows in submitted display order.
    body = response.body
    assert body.index("Reorder C") < body.index("Reorder A"), "expected submitted display order"
    assert body.index("Reorder A") < body.index("Reorder B"), "expected submitted display order"
  end

  test "moves split families together when grouped" do
    parent = create_transaction(account: @account, name: "Reorder Split", date: @date, amount: 100, created_at: 3.days.ago)
    parent.split!([ { name: "Part One", amount: 60 }, { name: "Part Two", amount: 40 } ])
    other = create_transaction(account: @account, name: "Reorder Single", date: @date, amount: 10, created_at: 1.day.ago)

    patch reorder_activity_account_path(@account),
      params: { date: @date.iso8601, entry_ids: [ parent.id, other.id ], grouped: true },
      headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success

    children = Entry.where(parent_entry_id: parent.id).to_a
    assert_equal 2, children.length
    positions = ([ parent.reload ] + children.map(&:reload)).map(&:manual_position).uniq
    assert_equal 1, positions.length, "split family shares one position"
    assert_equal other.reload.manual_position + 1, positions.first
  end

  test "skips valuations and keeps them pinned" do
    entry = create_transaction(account: @account, name: "Reorder Plain", date: @date, amount: 10, created_at: 1.day.ago)
    valuation = @account.entries.create!(name: "Reorder Valuation", date: @date, amount: 5000, currency: "USD", entryable: Valuation.new(kind: "reconciliation"), created_at: 2.days.ago)

    patch reorder_activity_account_path(@account),
      params: { date: @date.iso8601, entry_ids: [ valuation.id, entry.id ], grouped: false },
      headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_nil valuation.reload.manual_position
    entry_position = entry.reload.manual_position
    assert_not_nil entry_position
    untouched_max = @account.entries.where(date: @date).where.not(id: [ entry.id, valuation.id ])
      .where.not(entryable_type: "Valuation").maximum(:manual_position)
    assert untouched_max.nil? || untouched_max < entry_position,
      "submitted entry sorts after untouched day-siblings"
  end

  test "rejects missing dates, empty orders and foreign entries" do
    entry = create_transaction(account: @account, name: "Reorder Guard", date: @date, amount: 10)
    foreign = create_transaction(account: accounts(:credit_card), name: "Foreign", date: @date, amount: 10)

    patch reorder_activity_account_path(@account), params: { date: "not-a-date", entry_ids: [ entry.id ] }
    assert_response :unprocessable_entity

    patch reorder_activity_account_path(@account), params: { date: @date.iso8601, entry_ids: [] }
    assert_response :unprocessable_entity

    patch reorder_activity_account_path(@account), params: { date: @date.iso8601, entry_ids: [ foreign.id ] }
    assert_response :unprocessable_entity

    assert_nil entry.reload.manual_position
  end

  test "flat compact show renders manual order with drag units" do
    first = create_transaction(account: @account, name: "OrderFirst Row", date: @date, amount: 10, created_at: 3.days.ago)
    second = create_transaction(account: @account, name: "OrderSecond Row", date: @date, amount: 20, created_at: 1.day.ago)
    first.update!(manual_position: 1)
    second.update!(manual_position: 0)

    get account_url(@account)

    assert_response :success
    assert_includes response.body, 'data-controller="activity-reorder"'
    # Walk order is Second then First, so display order is First then Second.
    assert response.body.index("OrderFirst Row") < response.body.index("OrderSecond Row"),
      "expected manual display order (First before Second)"
    assert_select '[data-activity-reorder-target="unit"]', minimum: 2
  end
end
