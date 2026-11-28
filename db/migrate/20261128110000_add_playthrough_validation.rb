class AddPlaythroughValidation < ActiveRecord::Migration[8.1]
  def change
    add_column :playthrough_stages, :validation_state, :string
    add_column :playthrough_stages, :validation_result, :json
    add_column :playthrough_stages, :validation_error, :string
  end
end
