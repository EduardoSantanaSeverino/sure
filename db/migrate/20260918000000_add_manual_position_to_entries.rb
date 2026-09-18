class AddManualPositionToEntries < ActiveRecord::Migration[7.2]
  # Optional per-entry position for manual intra-day ordering in the compact
  # account activity view. NULL means "no manual order" and preserves the
  # legacy created_at/id ordering, so no backfill is required.
  def change
    add_column :entries, :manual_position, :integer
    add_index :entries, %i[account_id date manual_position], name: "index_entries_on_account_date_manual_position"
  end
end
