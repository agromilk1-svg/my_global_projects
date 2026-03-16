#!/usr/bin/env ruby
# Script to fix ECWDAStandalone target linkage

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

# Find WebDriverAgentLib target
wda_lib_target = project.targets.find { |t| t.name == 'WebDriverAgentLib' }

if wda_lib_target
  puts "Found WebDriverAgentLib target"
  
  # Get the product reference
  wda_lib_product = wda_lib_target.product_reference
  
  if wda_lib_product
    # Check if already linked
    already_linked = target.frameworks_build_phase.files.any? { |f| 
      f.file_ref == wda_lib_product 
    }
    
    unless already_linked
      target.frameworks_build_phase.add_file_reference(wda_lib_product)
      puts "Linked WebDriverAgentLib.framework product"
    else
      puts "WebDriverAgentLib.framework already linked"
    end
  else
    puts "Warning: WebDriverAgentLib product reference not found"
  end
end

# Update OTHER_LDFLAGS to include -ObjC for loading categories
target.build_configurations.each do |config|
  other_ldflags = config.build_settings['OTHER_LDFLAGS'] || ['$(inherited)']
  other_ldflags = [other_ldflags] unless other_ldflags.is_a?(Array)
  
  unless other_ldflags.include?('-ObjC')
    other_ldflags << '-ObjC'
    config.build_settings['OTHER_LDFLAGS'] = other_ldflags
    puts "Added -ObjC to #{config.name} OTHER_LDFLAGS"
  end
end

project.save
puts "Project saved!"
