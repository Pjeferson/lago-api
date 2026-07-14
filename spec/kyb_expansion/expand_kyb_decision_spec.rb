# frozen_string_literal: true

require "rails_helper"

RSpec.describe KybExpansion::ExpandKybDecision do
  let(:organization) { create(:organization) }
  let(:subscription) { create(:subscription, organization:) }
  let(:transaction_id) { SecureRandom.uuid }

  let(:base_params) do
    {
      code:,
      transaction_id:,
      external_subscription_id: subscription.external_id,
      properties: {"ubo_ids" => ["uuid-1", "uuid-2", "uuid-3"]},
      timestamp: Time.current.to_f
    }
  end

  let(:code) { "kyb_decision" }

  subject(:call_service) do
    Events::CreateService.call(
      organization:,
      params: base_params,
      timestamp: Time.current.to_f,
      metadata: {}
    )
  end

  context "when KYB_EXPANSION_ENABLED is not set" do
    around { |ex| ENV.delete("KYB_EXPANSION_ENABLED"); ex.run }

    it "does not enqueue KybExpansionJob" do
      call_service
      expect(KybExpansion::KybExpansionJob).not_to have_been_enqueued
    end

    it "returns a successful result" do
      result = call_service
      expect(result).to be_success
      expect(result.event.code).to eq("kyb_decision")
    end
  end

  context "when KYB_EXPANSION_ENABLED is true" do
    around { |ex| ENV["KYB_EXPANSION_ENABLED"] = "true"; ex.run; ENV.delete("KYB_EXPANSION_ENABLED") }

    context "when event code is kyb_decision" do
      let(:code) { "kyb_decision" }

      it "enqueues KybExpansionJob with the created event id" do
        result = call_service
        expect(KybExpansion::KybExpansionJob).to have_been_enqueued.with(result.event.id)
      end

      it "returns the original result unchanged" do
        result = call_service
        expect(result).to be_success
        expect(result.event.code).to eq("kyb_decision")
      end
    end

    context "when event code is not kyb_decision" do
      let(:code) { "kyc_decision" }

      it "does not enqueue KybExpansionJob" do
        call_service
        expect(KybExpansion::KybExpansionJob).not_to have_been_enqueued
      end
    end

    context "when CreateService returns a failure (duplicate transaction_id)" do
      before do
        create(:event,
          organization_id: organization.id,
          transaction_id:,
          external_subscription_id: subscription.external_id)
      end

      it "does not enqueue KybExpansionJob" do
        call_service
        expect(KybExpansion::KybExpansionJob).not_to have_been_enqueued
      end

      it "returns the failure result as-is" do
        result = call_service
        expect(result).not_to be_success
      end
    end
  end
end
