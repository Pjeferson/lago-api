# frozen_string_literal: true

module KybExpansion
  class KybExpansionFromPayloadJob < ApplicationJob
    # Works from the Kafka message payload rather than an Event DB record,
    # making it compatible with both PostgreSQL and ClickHouse event stores.
    # Premise: payload["properties"]["ubo_ids"] contains an array of UBO
    # identifier strings — assumed from the event producer, not a real integration.
    queue_as do
      if ActiveModel::Type::Boolean.new.cast(ENV["SIDEKIQ_EVENTS"])
        :events
      else
        :default
      end
    end

    def perform(payload)
      organization_id = payload["organization_id"]
      transaction_id = payload["transaction_id"]
      external_subscription_id = payload["external_subscription_id"]
      properties = payload["properties"] || {}
      timestamp = payload["timestamp"].to_f

      ubo_ids = properties["ubo_ids"]

      if ubo_ids.blank?
        Rails.logger.warn(
          "KybExpansion: kyb_decision event #{transaction_id} arrived without ubo_ids metadata, expansion skipped"
        )
        return
      end

      organization = Organization.find(organization_id)

      ubo_ids.each_with_index do |ubo_id, index|
        Events::CreateService.call(
          organization:,
          params: {
            code: "kyc_decision",
            transaction_id: "#{transaction_id}_ubo_#{index}",
            external_subscription_id:,
            properties: {
              derived_from: transaction_id,
              ubo_id:
            },
            timestamp:
          },
          timestamp: Time.current.to_f,
          metadata: {}
        )
      end
    end
  end
end
