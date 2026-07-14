# frozen_string_literal: true

module KybExpansion
  module ExpandKybDecision
    def call
      result = super

      if ENV["KYB_EXPANSION_ENABLED"] == "true" && result.success? && result.event.code == "kyb_decision"
        KybExpansion::KybExpansionJob.perform_later(result.event.id)
      end

      result
    end
  end
end
