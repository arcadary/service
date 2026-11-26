require "json"

class CatalogTaskService
  class ImportFailed < StandardError; end

  def self.import(folder:, output: $stdout)
    mappings = CatalogMappingService.load
    failures = []
    CatalogFetchService::MANIFEST.fetch("systems").each do |system, entry|
      begin
        result = CatalogImportService.import(path: Pathname.new(folder).join(entry.fetch("file")), system: system, mappings: mappings)
        output.puts(JSON.generate(result.merge(system: system)))
      rescue CatalogDatService::InvalidDat, CatalogImportService::IdentityConflict, ActiveRecord::ActiveRecordError, SystemCallError => error
        failures << system
        counts = { created: 0, updated: 0, unchanged: 0, skipped: 0 }
        output.puts(JSON.generate(system: system, failed: error.message, whole_system_skipped: true, games: counts, releases: counts))
      end
    end
    raise ImportFailed, "failed systems: #{failures.join(', ')}" if failures.any?
  end
end
