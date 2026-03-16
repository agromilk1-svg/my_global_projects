require 'xcodeproj'
project_path = '/Users/hh/Desktop/my/ECMain/ECMAIN.xcodeproj'
project = Xcodeproj::Project.open(project_path)
target = project.targets.find { |t| t.name == 'ECMAIN' }
group = project.main_group.groups.find { |g| g.name == 'ECMAIN' }

if target && group
  ref = group.files.find { |f| f.path == 'Assets.xcassets' }
  unless ref
    puts "Adding file ref..."
    ref = group.new_reference('Assets.xcassets')
  end
  
  resources = target.resources_build_phase
  unless resources.files_references.include?(ref)
     puts "Adding to resources build phase..."
     resources.add_file_reference(ref)
  end
  
  target.build_configurations.each do |config|
    config.build_settings['ASSETCATALOG_COMPILER_APPICON_NAME'] = 'AppIcon'
  end
  
  project.save
  puts "ECMain project updated."
else
  puts "ECMAIN Target or Group not found."
end
