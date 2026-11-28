namespace :screenshots do
  desc "Remove a screenshot by its stable id, as list_screenshots shows it"
  task :remove, [ :screenshot_id ] => :environment do |_task, args|
    ScreenshotService.remove(screenshot_id: args[:screenshot_id])
  end
end
