require "application_system_test_case"

class TransfersTest < ApplicationSystemTestCase
  include ActionView::RecordIdentifier

  setup do
    sign_in @user = users(:family_admin)
    visit transactions_url
  end

  test "can create a transfer" do
    transfer_date = Date.current

    click_on "New transaction"
    click_on "Transfer"
    assert_text "New transfer"

    # Select accounts using DS::Select
    select_ds("From", accounts(:depository))
    select_ds("To", accounts(:credit_card))

    fill_in "transfer[amount]", with: 500
    fill_in "Date", with: transfer_date

    click_button "Create transfer"

    within "#entry-group-#{transfer_date}" do
      assert_text "Payment to"
    end
  end

  test "transfer to an investment account defaults to the investment contributions category" do
    investment_category = ensure_investment_contributions_category(@user.family)
    transfer_date = Date.current

    click_on "New transaction"
    click_on "Transfer"
    assert_text "New transfer"

    select_ds("From", accounts(:depository))
    select_ds("To", accounts(:investment))

    fill_in "transfer[amount]", with: 100
    fill_in "Date", with: transfer_date

    click_button "Create transfer"

    within "#entry-group-#{transfer_date}" do
      assert_text investment_category.name
    end
    assert_equal investment_category, Transfer.order(:created_at).last.outflow_transaction.category
  end

  test "can pick a category when creating a transfer" do
    category = @user.family.categories.create!(name: "Rainy day")
    transfer_date = Date.current

    click_on "New transaction"
    click_on "Transfer"
    assert_text "New transfer"

    select_ds("From", accounts(:depository))
    select_ds("To", accounts(:credit_card))
    select_ds("Category", category)

    fill_in "transfer[amount]", with: 100
    fill_in "Date", with: transfer_date

    click_button "Create transfer"

    within "#entry-group-#{transfer_date}" do
      assert_text "Rainy day"
    end
    assert_equal category, Transfer.order(:created_at).last.outflow_transaction.category
  end

  test "can pick a category for a transfer into an investment account, overriding the default" do
    ensure_investment_contributions_category(@user.family)
    category = @user.family.categories.create!(name: "Rainy day")
    transfer_date = Date.current

    click_on "New transaction"
    click_on "Transfer"
    assert_text "New transfer"

    select_ds("From", accounts(:depository))
    select_ds("To", accounts(:investment))
    select_ds("Category", category)

    fill_in "transfer[amount]", with: 100
    fill_in "Date", with: transfer_date

    click_button "Create transfer"

    within "#entry-group-#{transfer_date}" do
      assert_text "Rainy day"
      assert_no_text "Investment Contributions"
    end
    assert_equal category, Transfer.order(:created_at).last.outflow_transaction.category
  end

  # KNOWN LIMITATION: the category <select> uses the same blank value for
  # "untouched" and "explicitly chose Uncategorized" (both submit
  # category_id=""), and Transfer::Creator can't tell those apart - see the
  # comment on Transfer::Creator#outflow_category_id. So explicitly picking
  # "Uncategorized" for a transfer into an investment account currently
  # produces the same result as leaving the field untouched: it still
  # defaults to Investment Contributions, not Uncategorized. This test
  # documents that actual behavior so a future fix (or an intentional
  # decision to keep it) shows up as a diff here instead of silent drift.
  test "explicitly choosing Uncategorized for a transfer into an investment account still defaults to Investment Contributions" do
    investment_category = ensure_investment_contributions_category(@user.family)
    transfer_date = Date.current

    click_on "New transaction"
    click_on "Transfer"
    assert_text "New transfer"

    select_ds("From", accounts(:depository))
    select_ds("To", accounts(:investment))
    select_blank_category

    fill_in "transfer[amount]", with: 100
    fill_in "Date", with: transfer_date

    click_button "Create transfer"

    within "#entry-group-#{transfer_date}" do
      assert_text investment_category.name
    end
    assert_equal investment_category, Transfer.order(:created_at).last.outflow_transaction.category
  end

  test "an uncategorized loan payment displays as Uncategorized, not Payment" do
    transfer_date = Date.current

    click_on "New transaction"
    click_on "Transfer"
    assert_text "New transfer"

    select_ds("From", accounts(:depository))
    select_ds("To", accounts(:loan))

    fill_in "transfer[amount]", with: 100
    fill_in "Date", with: transfer_date

    click_button "Create transfer"

    within "#entry-group-#{transfer_date}" do
      assert_text "Payment to"
    end

    outflow = Transfer.order(:created_at).last.outflow_transaction
    assert_equal "loan_payment", outflow.kind
    assert_nil outflow.category

    within "##{dom_id(outflow, 'category_menu_desktop')}" do
      assert_text "Uncategorized"
      assert_no_text "Payment"
    end
  end

  # The cross-account Transactions page only ever shows one row per transfer
  # (the outflow/source leg) - the inflow/destination leg doesn't appear
  # there at all, which limits the practical blast radius of this. But the
  # inflow leg IS shown, and its category menu IS editable, from the
  # destination account's own Activity tab - nothing there is aware it
  # belongs to a transfer, so it can be given a different category than the
  # outflow leg with no warning.
  test "the two legs of a transfer can end up with different categories" do
    category = @user.family.categories.create!(name: "Rainy day")
    destination = accounts(:investment)
    transfer_date = Date.current

    click_on "New transaction"
    click_on "Transfer"
    assert_text "New transfer"

    select_ds("From", accounts(:depository))
    select_ds("To", destination)
    select_ds("Category", category)

    fill_in "transfer[amount]", with: 100
    fill_in "Date", with: transfer_date

    click_button "Create transfer"

    within "#entry-group-#{transfer_date}" do
      assert_text category.name
    end

    transfer = Transfer.order(:created_at).last
    outflow = transfer.outflow_transaction
    inflow = transfer.inflow_transaction

    # Only the outflow (source) leg is categorized at creation time.
    assert_equal category, outflow.reload.category
    assert_nil inflow.reload.category

    # The inflow (destination) leg can still be categorized independently,
    # from its own account's Activity tab, via the regular per-transaction
    # category menu - which has no transfer-specific guard.
    other_category = @user.family.categories.create!(name: "Side project")

    visit account_url(destination, tab: "activity")

    within "##{dom_id(inflow, 'category_menu_desktop')}" do
      find("button", match: :first).click
    end

    within "turbo-frame#category_dropdown" do
      click_button other_category.name
    end

    within "##{dom_id(inflow, 'category_menu_desktop')}" do
      assert_text other_category.name
    end

    assert_equal other_category, inflow.reload.category
    assert_equal category, outflow.reload.category
    assert_not_equal outflow.category, inflow.category
  end

  test "shows exchange rate field for different currencies" do
    # Create an account with a different currency
    eur_account = @user.family.accounts.create!(
      name: "EUR Savings",
      balance: 1000,
      currency: "EUR",
      accountable: Depository.new
    )

    # Set up exchange rate
    ExchangeRate.create!(
      from_currency: "USD",
      to_currency: "EUR",
      date: Date.current,
      rate: 0.92
    )

    transfer_date = Date.current

    click_on "New transaction"
    click_on "Transfer"
    assert_text "New transfer"

    # Initially, exchange rate field should be hidden
    assert_selector "[data-transfer-form-target='exchangeRateContainer'].hidden", visible: :all

    # Select accounts with different currencies
    select_ds("From", accounts(:depository))
    select_ds("To", eur_account)

    # Exchange rate container should become visible
    assert_selector "[data-transfer-form-target='exchangeRateContainer']", visible: true

    # Exchange rate field should be populated with fetched rate
    exchange_rate_field = find("[data-transfer-form-target='exchangeRateField']")
    assert_not_empty exchange_rate_field.value
    assert_equal "0.92", exchange_rate_field.value

    # Fill in amount
    fill_in "transfer[amount]", with: 100
    fill_in "Date", with: transfer_date

    # Submit form
    click_button "Create transfer"

    # Should redirect and show transfer created
    assert_current_path transactions_url
    within "#entry-group-#{transfer_date}" do
      assert_text "Transfer to"
    end
  end

  private

    def select_ds(label_text, record)
      field_label = find("label", exact_text: label_text)
      container = field_label.ancestor("div.relative")

      # Click the button to open the dropdown
      container.find("button").click

      # If searchable, type in the search input
      if container.has_selector?("input[type='search']", visible: true)
        container.find("input[type='search']", visible: true).set(record.name)
      end

      # Wait for the listbox to appear inside the relative container
      listbox = container.find("[role='listbox']", visible: true)

      # Click the option inside the listbox
      listbox.find("[role='option'][data-value='#{record.id}']", visible: true).click
    end

    # Explicitly picks the blank ("Uncategorized") option in the Category
    # select, as opposed to never opening the dropdown at all. Both result in
    # the same submitted value today (category_id=""), which is the crux of
    # the "explicitly choosing Uncategorized" test above.
    def select_blank_category
      field_label = find("label", exact_text: "Category")
      container = field_label.ancestor("div.relative")

      container.find("button").click

      listbox = container.find("[role='listbox']", visible: true)
      listbox.find("[role='option'][data-value='']", visible: true).click
    end
end
