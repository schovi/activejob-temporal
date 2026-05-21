# frozen_string_literal: true

[
  { email: "ada@example.com", name: "Ada Lovelace", subscribed: true },
  { email: "grace@example.com", name: "Grace Hopper", subscribed: true },
  { email: "alan@example.com", name: "Alan Turing", subscribed: false }
].each do |attributes|
  subscriber = EmailSubscriber.find_or_initialize_by(email: attributes[:email])
  subscriber.update!(attributes)
end
