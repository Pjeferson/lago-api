# frozen_string_literal: true

module KybExpansion
  class KybDecisionEventConsumer < ApplicationConsumer
    def consume
      messages.each do |message|
        next unless ENV["KYB_EXPANSION_ENABLED"] == "true"
        next unless message.payload["code"] == "kyb_decision"

        KybExpansion::KybExpansionFromPayloadJob.perform_later(message.payload)
      end
    end
  end
end
