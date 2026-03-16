require 'xcodeproj'

project_path = '/Users/hh/Desktop/my/ECMAIN/ECMAIN.xcodeproj'
puts "Opening project at #{project_path}"
project = Xcodeproj::Project.open(project_path)

# 1. Create Group for Tunnel
# We want this group to appear in the project explorer.
# Check if it exists first.
tunnel_group = project.main_group.find_subpath('Tunnel', true)
tunnel_group.set_source_tree('<group>')
tunnel_group.set_path('Tunnel') # Relative to project root, which maps to ECMAIN dir

puts "Created/Found Group: Tunnel"

# 2. Add files to the group
files = [
  'PacketTunnelProvider.h',
  'PacketTunnelProvider.m',
  'Info.plist',
  'Tunnel.entitlements'
]

file_refs = {}
files.each do |filename|
  # Files are in Tunnel/ subdirectory physically
  # Group path is set to 'Tunnel', so we add files by name relative to group path?
  # Or if we use new_file on the group, it expects path relative to project or absolute?
  # Xcodeproj new_file usually handles relative paths from the project root if provided.
  # Let's provide relative path from project root: "Tunnel/filename"
  path = "Tunnel/#{filename}"
  file_refs[filename] = tunnel_group.new_file(path)
  puts "Added file reference: #{path}"
end

# 3. Create Target
target_name = 'Tunnel'
existing_target = project.targets.find { |t| t.name == target_name }
if existing_target
  puts "Target #{target_name} already exists. Skipping creation."
  target = existing_target
else
  puts "Creating new target: #{target_name}"
  target = project.new_target(:app_extension, target_name, :ios)
end

# 4. Configure Target
target.build_configuration_list.build_configurations.each do |config|
  config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.ecmain.shared.Tunnel'
  config.build_settings['INFOPLIST_FILE'] = 'Tunnel/Info.plist'
  config.build_settings['CODE_SIGN_ENTITLEMENTS'] = 'Tunnel/Tunnel.entitlements'
  config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'
  config.build_settings['SKIP_INSTALL'] = 'YES'
  config.build_settings['MARKETING_VERSION'] = '1.0'
  config.build_settings['CURRENT_PROJECT_VERSION'] = '1'
end

# 5. Add Build Phases
# Sources
target.add_file_references([file_refs['PacketTunnelProvider.m']])

# Frameworks
# Add NetworkExtension.framework
ne_framework = project.frameworks_group.find_file_by_path('System/Library/Frameworks/NetworkExtension.framework')
unless ne_framework
  ne_framework = project.frameworks_group.new_file('System/Library/Frameworks/NetworkExtension.framework')
end
target.frameworks_build_phase.add_file_reference(ne_framework)

puts "Configured Build Phases"

# 6. Embed Extension in Main App
main_target = project.targets.find { |t| t.name == 'ECMAIN' }
if main_target
  puts "Found Main Target: #{main_target.name}"
  
  # Add Dependency
  unless main_target.dependencies.any? { |d| d.target == target }
    main_target.add_dependency(target)
    puts "Added Target Dependency"
  end

  # Embed
  # dst_subfolder_spec: 13 (PlugIns)
  embed_phase = main_target.copy_files_build_phases.find { |p| p.dst_subfolder_spec == '13' }
  unless embed_phase
    embed_phase = main_target.new_copy_files_build_phase('Embed App Extensions')
    embed_phase.dst_subfolder_spec = '13'
    puts "Created Embed App Extensions Phase"
  end
  
  # Check if already added
  unless embed_phase.files.any? { |f| f.file_ref.path == target.product_reference.path }
    embed_phase.add_file_reference(target.product_reference)
    puts "Added Tunnel.appex to Embed Phase"
  end

  # Add NetworkExtension framework to Main App as well (needed for NEVPNManager)
  unless main_target.frameworks_build_phase.files.any? { |f| f.file_ref.path == ne_framework.path }
    main_target.frameworks_build_phase.add_file_reference(ne_framework)
    puts "Added NetworkExtension.framework to Main Target"
  end

else
  puts "ERROR: Main Target 'ECMAIN' not found!"
end

project.save
puts "Project saved successfully."
