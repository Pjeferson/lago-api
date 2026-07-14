# frozen_string_literal: true

require "rails_helper"

RSpec.describe KybExpansion::KybExpansionJob do
  let(:organization) { create(:organization) }
  let(:subscription) { create(:subscription, organization:) }
  let(:parent_transaction_id) { "kyb_tx_#{SecureRandom.hex(8)}" }

  let!(:parent_event) do
    create(:event,
      organization_id: organization.id,
      code: "kyb_decision",
      transaction_id: parent_transaction_id,
      external_subscription_id: subscription.external_id,
      properties: properties)
  end

  describe "#perform" do
    context "when the parent event has 3 UBOs" do
      let(:properties) { {"ubo_ids" => ["ubo_a", "ubo_b", "ubo_c"]} }

      it "creates exactly 3 kyc_decision events" do
        expect { described_class.new.perform(parent_event.id) }
          .to change(Event, :count).by(3)
      end

      it "creates events with deterministic transaction_ids" do
        described_class.new.perform(parent_event.id)

        transaction_ids = Event.where(code: "kyc_decision").pluck(:transaction_id)
        expect(transaction_ids).to match_array([
          "#{parent_transaction_id}_ubo_0",
          "#{parent_transaction_id}_ubo_1",
          "#{parent_transaction_id}_ubo_2"
        ])
      end

      it "sets derived_from and ubo_id in each child event properties" do
        described_class.new.perform(parent_event.id)

        child_events = Event.where(code: "kyc_decision").order(:created_at)
        expect(child_events.map { |e| e.properties["derived_from"] }).to all(eq(parent_transaction_id))
        expect(child_events.map { |e| e.properties["ubo_id"] }).to eq(["ubo_a", "ubo_b", "ubo_c"])
      end

      it "sets external_subscription_id equal to the parent event" do
        described_class.new.perform(parent_event.id)

        child_events = Event.where(code: "kyc_decision")
        expect(child_events.map(&:external_subscription_id)).to all(eq(subscription.external_id))
      end
    end

    context "when ubo_ids is absent from properties" do
      let(:properties) { {} }

      it "does not create any events" do
        expect { described_class.new.perform(parent_event.id) }
          .not_to change(Event, :count)
      end

      it "logs a warning" do
        allow(Rails.logger).to receive(:warn)
        described_class.new.perform(parent_event.id)
        expect(Rails.logger).to have_received(:warn).with(/kyb_decision.*without ubo_ids.*skipped/i)
      end

      it "does not raise" do
        expect { described_class.new.perform(parent_event.id) }.not_to raise_error
      end
    end

    context "when ubo_ids is an empty array" do
      let(:properties) { {"ubo_ids" => []} }

      it "does not create any events" do
        expect { described_class.new.perform(parent_event.id) }
          .not_to change(Event, :count)
      end

      it "logs a warning" do
        allow(Rails.logger).to receive(:warn)
        described_class.new.perform(parent_event.id)
        expect(Rails.logger).to have_received(:warn).with(/kyb_decision.*without ubo_ids.*skipped/i)
      end
    end

    context "when the job runs twice for the same parent event (idempotency)" do
      let(:properties) { {"ubo_ids" => ["ubo_a", "ubo_b", "ubo_c"]} }

      it "does not duplicate kyc_decision events" do
        described_class.new.perform(parent_event.id)

        expect { described_class.new.perform(parent_event.id) }
          .not_to change(Event.where(code: "kyc_decision"), :count)
      end

      it "does not raise on the second run" do
        described_class.new.perform(parent_event.id)
        expect { described_class.new.perform(parent_event.id) }.not_to raise_error
      end
    end
  end
end
