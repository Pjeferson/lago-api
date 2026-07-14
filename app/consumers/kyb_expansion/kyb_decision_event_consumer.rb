# frozen_string_literal: true

module KybExpansion
  class KybDecisionEventConsumer < ApplicationConsumer
    # Receives only kyb_decision events — pre-filtered upstream by the
    # Redpanda Connect pipeline in kyb-expansion/redpanda_connect_kyb_filter.yaml.
    def consume
      messages.each do |message|
        next unless ENV["KYB_EXPANSION_ENABLED"] == "true"

        KybExpansion::KybExpansionFromPayloadJob.perform_later(message.payload)
      end
    end
  end
end
