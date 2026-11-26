require "tmpdir"
require "json"

module CatalogHelpers
  def self.included(group)
    group.before do
      GameIdentity.delete_all
      ReleaseMedium.delete_all
      Release.delete_all
      MediaFile.delete_all
      Game.delete_all
    end
  end

  def checksum(number)
    format("%040x", number)
  end

  def write_dat(entries:, filename: "input.dat")
    path = Pathname.new(@folder).join(filename)
    path.write(entries.map do |entry|
      roms = entry.fetch(:checksums, [ entry[:sha1] ]).map do |sha1|
        metadata = entry.slice(:size, :crc, :md5).map { |key, value| "#{key} #{value}" }.join(" ")
        "rom ( name #{JSON.generate(entry.fetch(:filename, 'game.unh'))} sha1 #{sha1} #{metadata} )"
      end.join("\n")
      "game ( name #{JSON.generate(entry.fetch(:title))} #{roms} )"
    end.join("\n"))
    path
  end

  def import_entries(entries:, system: "nes", mappings: {})
    CatalogImportService.import(path: write_dat(entries: entries), system: system, mappings: mappings)
  end

  def snapshot
    [ Game.order(:id).map(&:attributes), Release.order(:sha1).map(&:attributes), GameIdentity.order(:key).map(&:attributes), MediaFile.order(:sha1).map(&:attributes), ReleaseMedium.order(:id).map(&:attributes) ]
  end
end
