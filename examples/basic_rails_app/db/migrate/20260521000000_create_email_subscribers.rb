# frozen_string_literal: true

class CreateEmailSubscribers < ActiveRecord::Migration[8.0]
  def change
    create_table :email_subscribers do |t|
      t.string :email, null: false
      t.string :name, null: false
      t.boolean :subscribed, null: false, default: true
      t.string :last_campaign_name
      t.datetime :last_campaign_sent_at

      t.timestamps
    end

    add_index :email_subscribers, :email, unique: true
  end
end
