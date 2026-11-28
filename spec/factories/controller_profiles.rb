FactoryBot.define do
  factory :controller_profile, class: Hash do
    version { 1 }
    binding { { "system" => "snes", "region" => nil, "revision" => nil } }
    layout do
      %w[top right bottom left].zip(%w[X A B Y]).map do |position, label|
        { "position" => position, "label" => label, "evidence" => [ "Synthetic layout observation", "Synthetic corroboration", "Synthetic edition citation" ] }
      end
    end
    prompts { [ { "letter" => "A", "position" => "right", "evidence" => [ "Synthetic gameplay observation", "Synthetic corroboration", "Synthetic edition citation" ] } ] }

    initialize_with { attributes.stringify_keys }
  end
end
