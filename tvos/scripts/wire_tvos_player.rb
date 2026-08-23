#!/usr/bin/env ruby
# Adds tvos/Runner/Playback sources to Runner.xcodeproj. flutter-tvos create
# only scaffolds the base project; native playback code added under
# Runner/Playback afterwards has to be wired into the pbxproj by hand (or by
# opening Xcode once and adding it), and this script does that idempotently
# so it can be re-run whenever files under Playback/ change.
require 'xcodeproj'

project_dir = File.expand_path(File.join(__dir__, '..'))
project_path = File.join(project_dir, 'Runner.xcodeproj')
project = Xcodeproj::Project.open(project_path)
target = project.targets.find { |t| t.name == 'Runner' } or abort('Runner target not found')

playback_group = project.main_group.find_subpath('Runner/Playback', true)
playback_group.set_source_tree('SOURCE_ROOT')
playback_group.set_path('Runner/Playback')

source_exts = %w[.swift .c .m .mm]
abs_files = Dir.glob(File.join(project_dir, 'Runner/Playback/**/*'))
  .select { |f| source_exts.include?(File.extname(f)) }.sort
basenames = abs_files.map { |f| File.basename(f) }

# Drop references this script is about to re-add, and any left pointing at a
# playback file that no longer exists.
playback_root = File.join(project_dir, 'Runner/Playback')
project.files.select do |f|
  next true if basenames.include?(File.basename(f.path.to_s))
  begin
    path = f.real_path.to_s
    path.start_with?(playback_root) && !File.exist?(path)
  rescue StandardError
    false
  end
end.each do |f|
  f.referrers.grep(Xcodeproj::Project::Object::PBXBuildFile).each(&:remove_from_project)
  f.remove_from_project
end

abs_files.each do |abs|
  ref = playback_group.new_reference(abs)
  target.add_file_references([ref]) unless File.extname(abs) == '.h'
  puts "added source: #{File.basename(abs)}"
end

project.save
puts 'saved project'
