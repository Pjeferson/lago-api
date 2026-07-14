# frozen_string_literal: true

require "rails_helper"

RSpec.describe KybExpansion::KybDecisionEventConsumer do
  let(:organization) { create(:organization) }
  let(:subscription) { create(:subscription, organization:) }
  let(:transaction_id) { "kyb_kafka_#{SecureRandom.hex(8)}" }

  let(:kyb_payload) do
    {
      "organization_id" => organization.id,
      "transaction_id" => transaction_id,
      "external_subscription_id" => subscription.external_id,
      "code" => "kyb_decision",
      "properties" => {"ubo_ids" => ["u1", "u2", "u3"]},
      "timestamp" => Time.current.to_f.to_s
    }
  end

  let(:message) { instance_double("Karafka::Messages::Message", payload: kyb_payload) }

  let(:consumer) do
    described_class.new.tap { |c| allow(c).to receive(:messages).and_return([message]) }
  end

  describe "#consume" do
    context "when KYB_EXPANSION_ENABLED is true" do
      around { |ex| ENV["KYB_EXPANSION_ENABLED"] = "true"; ex.run; ENV.delete("KYB_EXPANSION_ENABLED") }

      context "when message code is kyb_decision" do
        it "enqueues KybExpansionFromPayloadJob with the message payload" do
          consumer.consume
          expect(KybExpansion::KybExpansionFromPayloadJob).to have_been_enqueued.with(kyb_payload)
        end
      end

      context "when message code is not kyb_decision" do
        let(:kyb_payload) { super().merge("code" => "kyc_decision") }

        it "does not enqueue KybExpansionFromPayloadJob" do
          consumer.consume
          expect(KybExpansion::KybExpansionFromPayloadJob).not_to have_been_enqueued
        end
      end
    end

    context "when KYB_EXPANSION_ENABLED is not set" do
      around { |ex| ENV.delete("KYB_EXPANSION_ENABLED"); ex.run }

      it "does not enqueue KybExpansionFromPayloadJob" do
        consumer.consume
        expect(KybExpansion::KybExpansionFromPayloadJob).not_to have_been_enqueued
      end
    end
  end
end
