#!/usr/bin/env ruby
# Script to add C++ stdlib to ECWDAStandalone target

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

# Update OTHER_LDFLAGS to include C++ stdlib
target.build_configurations.each do |config|
  other_ldflags = config.build_settings['OTHER_LDFLAGS'] || ['$(inherited)']
  other_ldflags = [other_ldflags] unless other_ldflags.is_a?(Array)
  
  # Add C++ standard library
  unless other_ldflags.include?('-lc++')
    other_ldflags << '-lc++'
    puts "Added -lc++ to #{config.name}"
  end
  
  config.build_settings['OTHER_LDFLAGS'] = other_ldflags
  
  # Also ensure CLANG_CXX_LIBRARY is set
  config.build_settings['CLANG_CXX_LIBRARY'] = 'libc++'
end

project.save
puts "Project saved!"
