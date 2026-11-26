namespace :catalog do
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
