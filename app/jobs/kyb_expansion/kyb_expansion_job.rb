# frozen_string_literal: true

module KybExpansion
  class KybExpansionJob < ApplicationJob
    # Premise: the parent kyb_decision event must have properties["ubo_ids"] containing
    # an array of UBO identifier strings (e.g. {"ubo_ids": ["uuid1", "uuid2"]}).
    # This contract is assumed from the event producer; no real KYB integration is performed.
    queue_as do
      if ActiveModel::Type::Boolean.new.cast(ENV["SIDEKIQ_EVENTS"])
        :events
      else
        :default
      end
    end

    def perform(event_id)
      event = Event.find(event_id)
      ubo_ids = event.properties["ubo_ids"]

      if ubo_ids.blank?
        Rails.logger.warn(
          "KybExpansion: kyb_decision event #{event.transaction_id} arrived without ubo_ids metadata, expansion skipped"
        )
        return
      end

      ubo_ids.each_with_index do |ubo_id, index|
        Events::CreateService.call(
          organization: event.organization,
          params: {
            code: "kyc_decision",
            transaction_id: "#{event.transaction_id}_ubo_#{index}",
            external_subscription_id: event.external_subscription_id,
            properties: {
              derived_from: event.transaction_id,
              ubo_id: ubo_id
            },
            timestamp: event.timestamp.to_f
          },
          timestamp: Time.current.to_f,
          metadata: {}
        )
      end
    end
  end
end
