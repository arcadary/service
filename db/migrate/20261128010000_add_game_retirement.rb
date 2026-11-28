class AddGameRetirement < ActiveRecord::Migration[8.1]
  def change
    add_reference :games, :retired_into_game, foreign_key: { to_table: :games }
  end
end
