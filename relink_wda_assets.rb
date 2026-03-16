require 'xcodeproj'
project_path = '/Users/hh/Desktop/my/WebDriverAgent.xcodeproj'
project = Xcodeproj::Project.open(project_path)
target = project.targets.find { |t| t.name == 'WebDriverAgentRunner' }
group = project.main_group.groups.find { |g| g.name == 'WebDriverAgentRunner' }

if group && target
  # Remove old reference if existing to be safe
  old_ref = group.files.find { |f| f.path == 'Assets.xcassets' }
  if old_ref
     old_ref.remove_from_project
  end

  # Add new reference with explicit path RELATIVE TO GROUP
  # Assuming Group maps to WebDriverAgentRunner (folder)
  # So we just say 'Assets.xcassets' if it is inside that folder.
  # But if group is not mapped, we should check.
  
  # Just add it to Main Group with explicit path relative to Project Root usually works best
  # But keeping it in group is cleaner.
  # Let's check group path.
  
  puts "Group path: #{group.path}"
  
  # Creating ref
  # If group path is 'WebDriverAgentRunner', then file path 'Assets.xcassets' refers to 'WebDriverAgentRunner/Assets.xcassets'
  ref = group.new_reference('Assets.xcassets')
  
  # Add to resources build phase
  resources = target.resources_build_phase
  # clear duplicates
  resources.files.each do |f|
    if f.file_ref && f.file_ref.path == 'Assets.xcassets'
       resources.remove_build_file(f)
    end
  end
  
  resources.add_file_reference(ref)
  
  target.build_configurations.each do |config|
    config.build_settings['ASSETCATALOG_COMPILER_APPICON_NAME'] = 'AppIcon'
  end
  
  project.save
  puts "WDA project updated."
else
  puts "Target or Group not found."
end
