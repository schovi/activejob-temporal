# frozen_string_literal: true

class EmailSubscriber < ApplicationRecord
  validates :email, presence: true, uniqueness: true
  validates :name, presence: true

  scope :subscribed, -> { where(subscribed: true) }
end
