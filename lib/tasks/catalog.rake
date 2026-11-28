namespace :catalog do
  desc "Preview one local UTF-8 JSON authoring operation without writes"
  task :preview, [ :path ] => :environment do |_, args|
    abort "Usage: bin/rails catalog:preview[LOCAL_JSON_FILE]" unless args[:path].present? && args.extras.empty?

    begin
      puts JSON.generate(CatalogManualImportService.call(path: args[:path], preview: true))
    rescue StandardError => error
      abort JSON.generate(failed: error.message, error: error.class.name)
    end
  end

  desc "Apply one local UTF-8 JSON authoring envelope atomically"
  task :apply, [ :path ] => :environment do |_, args|
    abort "Usage: bin/rails catalog:apply[LOCAL_JSON_FILE]" unless args[:path].present? && args.extras.empty?

    begin
      puts JSON.generate(CatalogManualImportService.call(path: args[:path]))
    rescue StandardError => error
      abort JSON.generate(failed: error.message, error: error.class.name)
    end
  end

  desc "Fetch only the eight digest-verified pinned DATs into a local folder"
  task :fetch, [ :folder ] => :environment do |_, args|
    abort "Usage: bin/rails catalog:fetch[LOCAL_FOLDER]" unless args[:folder].present? && args.extras.empty?

    CatalogFetchService.fetch(folder: args[:folder])
  end

  desc "Import local DATs offline, atomically per system, without removing absent records"
  task :import, [ :folder ] => :environment do |_, args|
    abort "Usage: bin/rails catalog:import[LOCAL_FOLDER]" unless args[:folder].present? && args.extras.empty?

    CatalogTaskService.import(folder: args[:folder])
  end
end
