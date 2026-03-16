require 'xcodeproj'
project_path = '/Users/hh/Desktop/my/ECMAIN/ECMAIN.xcodeproj'
project = Xcodeproj::Project.open(project_path)

target_name = 'Tunnel'
target = project.targets.find { |t| t.name == target_name }

if target
  target.build_configuration_list.build_configurations.each do |config|
    old_id = config.build_settings['PRODUCT_BUNDLE_IDENTIFIER']
    new_id = 'com.ecmain.app.Tunnel'
    puts "Updating Bundle ID from #{old_id} to #{new_id}"
    config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = new_id
  end
  project.save
  puts "Project saved."
else
  puts "Target Tunnel not found"
end
