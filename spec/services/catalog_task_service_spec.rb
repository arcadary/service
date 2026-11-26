require "rails_helper"
require "open3"
require_relative "../support/catalog_helpers"

RSpec.describe CatalogTaskService do
  include CatalogHelpers

  around do |example|
    Dir.mktmpdir("catalog-task-", Rails.root.join("tmp")) do |folder|
      @folder = folder
      example.run
    end
  end

  it "reports each system and preserves successful systems while failing the task for missing lists" do
    allow(CatalogMappingService).to receive(:load).and_return({})
    write_dat(entries: [ { title: "A Game (World)", sha1: checksum(1) } ], filename: "Nintendo - Game Boy.dat")
    output = StringIO.new
    expect { described_class.import(folder: @folder, output: output) }.to raise_error(described_class::ImportFailed, /failed systems/)
    results = output.string.lines.map { |line| JSON.parse(line) }
    expect(results.size).to eq(8)
    expect(results.count { |result| result.key?("failed") }).to eq(7)
    expect(results.find { |result| result["system"] == "gb" }.dig("releases", "created")).to eq(1)
    expect(Release.sole.system).to eq("gb")
  end

  it "exits non-zero for a failed import or refused fetch arguments without downloading" do
    _, import_error, import_status = Open3.capture3(RbConfig.ruby, "bin/rails", "catalog:import[#{@folder}]")
    expect(import_status.exitstatus).not_to eq(0)
    expect(import_error).to include("failed systems")
    _, fetch_error, fetch_status = Open3.capture3(RbConfig.ruby, "bin/rails", "catalog:fetch[#{@folder},other.dat]")
    expect(fetch_status.exitstatus).not_to eq(0)
    expect(fetch_error).to include("Usage:")
    fake_download = "require_relative './config/environment'; CatalogFetchService.define_singleton_method(:download) { |_| 'mismatched synthetic bytes' }; ARGV.replace(['catalog:fetch[#{@folder}]']); load './bin/rails'"
    _, digest_error, digest_status = Open3.capture3(RbConfig.ruby, "-e", fake_download)
    expect(digest_status.exitstatus).not_to eq(0)
    expect(digest_error).to include("SHA-256 mismatch")
  end
end
