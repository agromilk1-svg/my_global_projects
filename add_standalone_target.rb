#!/usr/bin/env ruby
# Script to add ECWDAStandalone target to WebDriverAgent.xcodeproj

require 'xcodeproj'

project_path = '/Users/hh/Desktop/my/WebDriverAgent.xcodeproj'
project = Xcodeproj::Project.open(project_path)

# Check if target already exists
if project.targets.find { |t| t.name == 'ECWDAStandalone' }
  puts "Target ECWDAStandalone already exists, removing..."
  target = project.targets.find { |t| t.name == 'ECWDAStandalone' }
  target.remove_from_project
end

# Create new iOS App target
puts "Creating ECWDAStandalone target..."
target = project.new_target(:application, 'ECWDAStandalone', :ios, '13.0')

# Get WebDriverAgentLib target for dependency
wda_lib_target = project.targets.find { |t| t.name == 'WebDriverAgentLib' }

# Add dependency on WebDriverAgentLib
if wda_lib_target
  target.add_dependency(wda_lib_target)
  puts "Added dependency on WebDriverAgentLib"
end

# Find or create group for standalone files
standalone_group = project.main_group.find_subpath('WebDriverAgentRunner/ECWDAStandalone', true)

# Add source files
source_files = [
  '/Users/hh/Desktop/my/WebDriverAgentRunner/ECWDAStandalone/main.m',
  '/Users/hh/Desktop/my/WebDriverAgentRunner/ECWDAStandalone/ECWDAAppDelegate.m',
]

source_files.each do |file_path|
  if File.exist?(file_path)
    file_ref = standalone_group.new_reference(file_path)
    target.source_build_phase.add_file_reference(file_ref)
    puts "Added source: #{File.basename(file_path)}"
  end
end

# Add header file
header_path = '/Users/hh/Desktop/my/WebDriverAgentRunner/ECWDAStandalone/ECWDAAppDelegate.h'
if File.exist?(header_path)
  standalone_group.new_reference(header_path)
  puts "Added header: ECWDAAppDelegate.h"
end

# Configure build settings
target.build_configurations.each do |config|
  config.build_settings['PRODUCT_NAME'] = 'ECWDA'
  config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.ecwda.standalone'
  config.build_settings['INFOPLIST_FILE'] = '$(SRCROOT)/WebDriverAgentRunner/ECWDAStandalone/Info.plist'
  config.build_settings['CODE_SIGN_IDENTITY'] = ''
  config.build_settings['CODE_SIGNING_REQUIRED'] = 'NO'
  config.build_settings['CODE_SIGNING_ALLOWED'] = 'NO'
  config.build_settings['HEADER_SEARCH_PATHS'] = ['$(inherited)', '$(SRCROOT)/WebDriverAgentLib']
  config.build_settings['FRAMEWORK_SEARCH_PATHS'] = ['$(inherited)', '$(SRCROOT)/Frameworks', '/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/Library/Frameworks']
  config.build_settings['LD_RUNPATH_SEARCH_PATHS'] = ['$(inherited)', '@executable_path/Frameworks']
  config.build_settings['ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES'] = 'YES'
  config.build_settings['CLANG_ENABLE_MODULES'] = 'YES'
  config.build_settings['STRIP_INSTALLED_PRODUCT'] = 'NO'
  config.build_settings['COPY_PHASE_STRIP'] = 'NO'
  config.build_settings['DEAD_CODE_STRIPPING'] = 'NO'
end

# Link WebDriverAgentLib framework
frameworks_group = project.main_group.find_subpath('Frameworks', true)

# Add WebDriverAgentLib.framework to link
wda_lib_ref = frameworks_group.files.find { |f| f.path&.include?('WebDriverAgentLib.framework') }
if wda_lib_ref
  target.frameworks_build_phase.add_file_reference(wda_lib_ref)
  puts "Linked WebDriverAgentLib.framework"
end

# Add system frameworks
['UIKit', 'Foundation', 'XCTest'].each do |fw_name|
  framework_ref = project.frameworks_group.new_reference("System/Library/Frameworks/#{fw_name}.framework")
  framework_ref.source_tree = 'SDKROOT'
  target.frameworks_build_phase.add_file_reference(framework_ref)
  puts "Linked #{fw_name}.framework"
end

# Save project
project.save
puts "Project saved successfully!"
puts "Target ECWDAStandalone created."
