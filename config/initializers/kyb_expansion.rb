# frozen_string_literal: true

Rails.application.config.to_prepare do
  Events::CreateService.prepend(KybExpansion::ExpandKybDecision)
end
