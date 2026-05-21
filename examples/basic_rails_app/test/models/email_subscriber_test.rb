# frozen_string_literal: true

require "test_helper"

class EmailSubscriberTest < ActiveSupport::TestCase
  test "requires an email address" do
    subscriber = EmailSubscriber.new(name: "Ada Lovelace")

    assert_not subscriber.valid?
    assert_includes subscriber.errors[:email], "can't be blank"
  end

  test "requires a name" do
    subscriber = EmailSubscriber.new(email: "ada@example.com")

    assert_not subscriber.valid?
    assert_includes subscriber.errors[:name], "can't be blank"
  end

  test "filters subscribed recipients" do
    subscribed = EmailSubscriber.create!(email: "ada@example.com", name: "Ada Lovelace")
    EmailSubscriber.create!(email: "alan@example.com", name: "Alan Turing", subscribed: false)

    assert_equal [subscribed], EmailSubscriber.subscribed.to_a
  end
end
