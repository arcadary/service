require "rails_helper"
require_relative "../support/playthrough_helpers"

RSpec.describe PlaythroughStagingService do
  include PlaythroughHelpers

  let!(:release) { create(:release) }
  let(:declaration) { playthrough_declaration(release: release) }

  it "binds secondary/shared media by stable release identity and retains normalized provenance" do
    other = create(:release, sha1: release.sha1)
    stage = declare_playthrough
    expect(stage.release).to eq(release)
    expect(stage.declaration.fetch("capture")).to eq(declaration.fetch("capture").merge("captured_at" => "2026-11-28T08:00:00.000000Z"))
    expect(stage.objects.sole).to have_attributes(path: "video/segment.ts", received_at: nil, blob_id: nil)
    expect(stage.release).not_to eq(other)
    medium = create(:media_file)
    create(:release_medium, release: release, media_file: medium, key: "second", position: 2)
    declaration["retry_key"] = "secondary"
    declaration["source_sha1"] = medium.sha1
    expect(declare_playthrough.release).to eq(release)
  end

  it "retains the separate source and verified payload, including 127 removed bytes and the authenticated verifier" do
    declaration["source_sha1"] = "f" * 40
    declaration["verification"] = playthrough_verification(source: declaration["source_sha1"], payload: release.sha1)
    stage = declare_playthrough
    expect(stage.declaration.fetch("source_sha1")).to eq("f" * 40)
    expect(stage.declaration.fetch("verification")).to include("payload_sha1" => release.sha1, "removed_bytes" => 127,
      "verifier" => "synthetic-admin", "result" => "success")
  end

  it "refuses nonmember sources without verification and nonmember verified payloads" do
    declaration["source_sha1"] = "f" * 40
    expect { declare_playthrough }.to raise_error(PlaythroughStage::TargetMismatch)
    declaration["verification"] = playthrough_verification(source: declaration["source_sha1"], payload: "e" * 40)
    expect { declare_playthrough }.to raise_error(PlaythroughStage::TargetMismatch)
    expect(PlaythroughStage.count).to eq(0)
  end

  it "rejects missing, blank, contradictory and multiple verification proposals" do
    declaration["source_sha1"] = "f" * 40
    verification = playthrough_verification(source: declaration["source_sha1"], payload: release.sha1)
    [ verification.except("method"), verification.merge("evidence" => " "), verification.except("removed_bytes"),
      verification.merge("source_sha1" => "e" * 40), verification.merge("verifier" => "someone-else"),
      verification.merge("result" => "failed"), verification.merge("evidence" => "Source #{'e' * 40} matches #{release.sha1}"),
      verification.merge("evidence" => "#{verification['evidence']} Or #{'d' * 40}"), [ verification, verification ] ].each do |input|
      declaration["verification"] = input
      expect { declare_playthrough }.to raise_error(PlaythroughStage::InvalidDeclaration)
    end
  end

  it "rejects absent capture provenance, multiple targets and duplicate JSON keys" do
    [ declaration.except("capture"), declaration.merge("capture" => { "tool" => "", "version" => "1", "captured_at" => "today" }),
      declaration.merge("release_id" => [ release.public_id, "other" ]) ].each do |input|
      expect { declare_playthrough(input: input) }.to raise_error(PlaythroughStage::InvalidDeclaration)
    end
    json = JSON.generate(declaration).sub('"release_id":', '"release_id":"other","release_id":')
    expect { described_class.create(io: StringIO.new(json), content_type: "application/json", verifier: "synthetic-admin") }
      .to raise_error(PlaythroughStage::InvalidDeclaration)
  end

  it "computes the specified bytewise manifest identity and replays normalized declarations without adding accounting" do
    entry = declaration.fetch("manifest").first
    declaration["manifest"] = [ entry.merge("path" => "é.ts"), entry.merge("path" => "z.ts") ]
    stage = declare_playthrough
    canonical = JSON.generate([ [ "z.ts", entry["byte_size"], entry["sha256"], entry["content_type"] ],
      [ "é.ts", entry["byte_size"], entry["sha256"], entry["content_type"] ] ])
    expect(stage.package_sha256).to eq(Digest::SHA256.hexdigest(canonical))
    declaration["manifest"].reverse!
    declaration["capture"]["captured_at"] = "2026-11-28T09:00:00+01:00"
    expect(declare_playthrough.id).to eq(stage.id)
    expect(PlaythroughStageObject.count).to eq(2)
  end

  it "conflicts when a retry changes the release, capture evidence or manifest" do
    declare_playthrough
    [ declaration.merge("release_id" => create(:release).public_id),
      declaration.merge("capture" => declaration["capture"].merge("version" => "2")),
      declaration.merge("manifest" => [ declaration["manifest"].first.merge("path" => "other.ts") ]) ].each do |input|
      expect { declare_playthrough(input: input) }.to raise_error(PlaythroughStage::Conflict)
    end
  end

  it "refuses absolute paths, URLs, traversal and duplicate paths" do
    entry = declaration["manifest"].first
    [ "/segment.ts", "https://example/segment.ts", "video/../segment.ts", "video/%2e%2e/segment.ts", "video\\segment.ts" ].each do |path|
      declaration["manifest"] = [ entry.merge("path" => path) ]
      expect { declare_playthrough }.to raise_error(PlaythroughStage::InvalidDeclaration)
    end
    declaration["manifest"] = [ entry, entry ]
    expect { declare_playthrough }.to raise_error(PlaythroughStage::InvalidDeclaration)
  end

  it "requires positive sizes, lowercase digests and content types" do
    entry = declaration["manifest"].first
    [ entry.merge("byte_size" => 0), entry.merge("sha256" => "A" * 64), entry.merge("content_type" => "") ].each do |invalid|
      declaration["manifest"] = [ invalid ]
      expect { declare_playthrough }.to raise_error(PlaythroughStage::InvalidDeclaration)
    end
  end

  it "enforces the object count, per-object and aggregate ceilings, accepting their boundaries" do
    entry = declaration["manifest"].first
    entries = Array.new(4096) { |index| entry.merge("path" => "#{index}.ts", "byte_size" => 1.megabyte) }
    expect(PlaythroughDeclarationService.manifest!(entries).size).to eq(4096)
    declaration["manifest"] = entries + [ entry ]
    expect { declare_playthrough }.to raise_error(PlaythroughStage::TooLarge)
    declaration["manifest"] = [ entry.merge("byte_size" => 8.megabytes + 1) ]
    expect { declare_playthrough }.to raise_error(PlaythroughStage::TooLarge)
    entries.first["byte_size"] += 1
    declaration["manifest"] = entries
    expect { declare_playthrough }.to raise_error(PlaythroughStage::TooLarge)
    declaration["manifest"] = [ entry.merge("byte_size" => 8.megabytes) ]
    expect(declare_playthrough.objects.sole.byte_size).to eq(8.megabytes)
  end

  it "bounds actual declaration reads and accepts exactly 1 MiB" do
    json = JSON.generate(declaration)
    expect(described_class.create(io: StringIO.new(json.ljust(1.megabyte)), content_type: "application/json", verifier: "synthetic-admin")).to be_persisted
    expect { described_class.create(io: StringIO.new(json.ljust(1.megabyte + 1)), content_type: "application/json", verifier: "synthetic-admin") }
      .to raise_error(PlaythroughStage::TooLarge)
  end
end
