require 'xcodeproj'

PROJECT_PATH = 'WebDriverAgent.xcodeproj'
TARGET_NAME = 'WebDriverAgentRunner'
ASSETS_PATH = 'WebDriverAgentRunner/Assets.xcassets'
INFO_PLIST_PATH = 'WebDriverAgentRunner/Info.plist'

puts "=== Configuring ECWDA Appearance ==="

# 1. Add Assets to Project
puts "\n[1/3] Adding Assets.xcassets to project..."
project = Xcodeproj::Project.open(PROJECT_PATH)
target = project.targets.find { |t| t.name == TARGET_NAME }

if target
  # Find the group 'WebDriverAgentRunner'
  group = project.main_group.find_subpath(File.dirname(ASSETS_PATH))
  if group
    # Check if reference exists
    file_ref = group.files.find { |f| f.path == File.basename(ASSETS_PATH) }
    unless file_ref
      puts "  Adding file reference..."
      file_ref = group.new_reference(File.basename(ASSETS_PATH))
    else
      puts "  File reference already exists."
    end
    
    # Add to Resources Build Phase
    resources_phase = target.resources_build_phase
    build_file = resources_phase.files.find { |f| f.file_ref == file_ref }
    unless build_file
      puts "  Adding to Resources Build Phase..."
      resources_phase.add_file_reference(file_ref)
    else
      puts "  Already in Resources Build Phase."
    end
  else
    puts "  ⚠️ Group WebDriverAgentRunner not found!"
  end

  # 2. Update Build Settings
  puts "\n[2/3] Updating Build Settings..."
  target.build_configuration_list.build_configurations.each do |config|
    puts "  Configuring #{config.name}..."
    config.build_settings['ASSETCATALOG_COMPILER_APPICON_NAME'] = 'AppIcon'
    config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0' # Ensure modern enough
  end
  project.save
  puts "  ✅ Project Saved"

else
  puts "  ❌ Target #{TARGET_NAME} not found!"
end

# 3. Update Info.plist using plutil
puts "\n[3/3] Updating Info.plist..."
if File.exist?(INFO_PLIST_PATH)
  puts "  Setting CFBundleName and CFBundleDisplayName to ECWDA..."
  system("plutil -replace CFBundleName -string 'ECWDA' '#{INFO_PLIST_PATH}'")
  system("plutil -replace CFBundleDisplayName -string 'ECWDA' '#{INFO_PLIST_PATH}'")
  puts "  ✅ Info.plist Updated"
else
  puts "  ❌ Info.plist not found at #{INFO_PLIST_PATH}"
end
