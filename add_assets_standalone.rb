#!/usr/bin/env ruby
# Script to update ECWDAStandalone target with Assets

require 'xcodeproj'

project_path = '/Users/hh/Desktop/my/WebDriverAgent.xcodeproj'
project = Xcodeproj::Project.open(project_path)

# Find ECWDAStandalone target
target = project.targets.find { |t| t.name == 'ECWDAStandalone' }

unless target
  puts "Error: ECWDAStandalone target not found"
  exit 1
end

puts "Found target: #{target.name}"

# Find Assets.xcassets
# Usually in WebDriverAgentRunner group
wda_runner_group = project.main_group.find_subpath('WebDriverAgentRunner', true)
assets_ref = wda_runner_group.files.find { |f| f.path&.include?('Assets.xcassets') }

# If not found in file references, look for it on disk and add it
unless assets_ref
  puts "Assets.xcassets reference not found in group, checking disk..."
  assets_path = '/Users/hh/Desktop/my/WebDriverAgentRunner/Assets.xcassets'
  if File.exist?(assets_path)
    assets_ref = wda_runner_group.new_reference(assets_path)
    puts "Added Assets.xcassets to group"
  end
end

if assets_ref
  # Check if already in Resources build phase
  already_added = target.resources_build_phase.files.any? { |f| f.file_ref == assets_ref }
  
  unless already_added
    target.resources_build_phase.add_file_reference(assets_ref)
    puts "Added Assets.xcassets to Resources build phase"
  else
    puts "Assets.xcassets already in build phase"
  end
else
  puts "Error: Assets.xcassets not found"
end

project.save
puts "Project saved!"
