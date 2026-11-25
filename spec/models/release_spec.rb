require "rails_helper"

RSpec.describe Release, type: :model do
  subject { Game.create!(public_id: "a-game", title: "A game").releases.build(sha1: "a" * 40, system: "gb") }

  it { is_expected.to belong_to(:game).touch(true) }
  it { is_expected.to validate_presence_of(:sha1) }
  it { is_expected.to validate_uniqueness_of(:sha1) }
  it { is_expected.to allow_value("a" * 40).for(:sha1) }
  it { is_expected.not_to allow_value("A" * 40).for(:sha1) }
  it { is_expected.to validate_inclusion_of(:system).in_array(Release::SYSTEMS) }
end
