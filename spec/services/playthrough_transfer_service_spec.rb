require "rails_helper"
require_relative "../support/playthrough_helpers"

RSpec.describe PlaythroughTransferService do
  include PlaythroughHelpers

  let!(:release) { create(:release) }
  let(:declaration) { playthrough_declaration(release: release) }

  it "verifies bytes before storage and preserves accepted object results on retries" do
    stage = declare_playthrough
    object = receive_playthrough(stage: stage)
    expect(object.blob.download).to eq("synthetic segment")
    expect(object.blob.content_type).to eq("video/mp2t")
    expect(receive_playthrough(stage: stage).attributes).to eq(object.attributes)
    expect(ActiveStorage::Blob.count).to eq(1)
    [ { bytes: "wrong-size" }, { bytes: "x" * object.byte_size }, { content_type: "video/mp4" } ].each do |change|
      expect { receive_playthrough(stage: stage, **change) }.to raise_error(PlaythroughStage::Conflict)
      expect(object.reload.blob.download).to eq("synthetic segment")
    end
  end

  it "scopes objects to their stage without overwriting another package" do
    first = declare_playthrough
    declaration["retry_key"] = "second-stage"
    second = declare_playthrough
    expect { receive_playthrough(stage: second, object: first.objects.sole) }.to raise_error(PlaythroughStage::NotFound)
    receive_playthrough(stage: first)
    receive_playthrough(stage: second)
    expect(first.objects.sole.reload.blob.key).not_to eq(second.objects.sole.reload.blob.key)
  end

  it "enforces actual reads at the 8 MiB boundary" do
    bytes = "x" * 8.megabytes
    stage = declare_playthrough(input: playthrough_declaration(release: release, bytes: bytes))
    expect { receive_playthrough(stage: stage, bytes: bytes + "x") }.to raise_error(PlaythroughStage::TooLarge)
    expect(stage.objects.sole.reload.received_at).to be_nil
    expect(receive_playthrough(stage: stage, bytes: bytes).received_at).to be_present
  end

  it "keeps completed progress durable when a read is interrupted and retries using fresh records" do
    entry = declaration["manifest"].first
    declaration["manifest"] << entry.merge("path" => "video/next.ts")
    stage = declare_playthrough
    first, second = stage.objects.to_a
    receive_playthrough(stage: stage, object: first)
    io = double("interrupted stream")
    allow(io).to receive(:read).with(anything).and_invoke(->(*) { "synthetic" }, ->(*) { raise IOError })
    expect { described_class.receive(staging_id: stage.public_id, object_id: second.public_id, io: io, content_type: second.content_type) }
      .to raise_error(PlaythroughStage::InterruptedTransfer)
    reloaded = PlaythroughStagingService.find_by(staging_id: stage.public_id)
    expect(reloaded.objects.map { |object| object.received_at.present? }).to eq([ true, false ])
    receive_playthrough(stage: reloaded, object: second)
    expect(PlaythroughStagingService.find_by(staging_id: stage.public_id).objects).to all(have_attributes(received_at: be_present))
  end

  it "leaves a failed storage object incomplete and safely retryable without changing another stage" do
    stage = declare_playthrough
    receive_playthrough(stage: stage)
    original = stage.objects.sole.reload.attributes
    declaration["retry_key"] = "failing-stage"
    other = declare_playthrough
    allow(ActiveStorage::Blob.service).to receive(:upload).and_raise(IOError)
    expect { receive_playthrough(stage: other) }.to raise_error(PlaythroughStage::StorageUnavailable)
    expect(other.objects.sole.reload).to have_attributes(blob_id: nil, received_at: nil)
    expect(stage.objects.sole.reload.attributes).to eq(original)
    allow(ActiveStorage::Blob.service).to receive(:upload).and_call_original
    expect(receive_playthrough(stage: other).received_at).to be_present
  end
end
