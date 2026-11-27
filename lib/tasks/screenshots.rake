namespace :screenshots do
  desc "Remove a screenshot by stable release public ID and kind"
  task :remove, [ :public_id, :kind ] => :environment do |_task, args|
    ScreenshotService.remove(public_id: args[:public_id], kind: args[:kind])
  end
end
