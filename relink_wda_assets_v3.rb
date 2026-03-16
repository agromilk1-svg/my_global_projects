require 'xcodeproj'
project_path = '/Users/hh/Desktop/my/WebDriverAgent.xcodeproj'
project = Xcodeproj::Project.open(project_path)
target = project.targets.find { |t| t.name == 'WebDriverAgentRunner' }
main_group = project.main_group
runner_group = main_group.groups.find { |g| g.name == 'WebDriverAgentRunner' }

if target
  # cleanup old refs in runner_group or main_group
  [main_group, runner_group].each do |g|
      next unless g
      old_ref = g.files.find { |f| f.path == 'Assets.xcassets' || f.path == 'WebDriverAgentRunner/Assets.xcassets' }
      if old_ref
         old_ref.remove_from_project
      end
  end

  # Add to Main Group with relative path from project root
  # File is at /Users/hh/Desktop/my/WebDriverAgentRunner/Assets.xcassets
  # Project is at /Users/hh/Desktop/my/WebDriverAgent.xcodeproj
  # So relative path is 'WebDriverAgentRunner/Assets.xcassets'
  
  ref = main_group.new_reference('WebDriverAgentRunner/Assets.xcassets')
  
  resources = target.resources_build_phase
  # Remove any broken refs
  resources.files.each do |f|
     if f.file_ref.nil? || f.file_ref.path.include?('Assets.xcassets')
         resources.remove_build_file(f)
     end
  end
  
  resources.add_file_reference(ref)
  
  target.build_configurations.each do |config|
    config.build_settings['ASSETCATALOG_COMPILER_APPICON_NAME'] = 'AppIcon'
  end
  
  project.save
  puts "WDA project relinked correctly."
else
  puts "Target not found."
end
