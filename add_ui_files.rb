require 'xcodeproj'

project_path = 'ECMAIN/ECMAIN.xcodeproj'
project = Xcodeproj::Project.open(project_path)

target = project.targets.find { |t| t.name == 'ECMAIN' }
group = project.main_group.find_file_by_path('ECMAIN') || project.main_group['ECMAIN']
# If main group ECMAIN isn't found using path, it might be the top level.
# Actually ECMAIN group usually exists.
# Let's just assume project.main_group is the root and look for 'ECMAIN' child group.
ecmain_group = project.main_group.groups.find { |g| g.name == 'ECMAIN' }
unless ecmain_group
  puts "Could not find ECMAIN group, listing all groups:"
  project.main_group.groups.each { |g| puts g.name }
  exit 1
end

ui_group = ecmain_group.groups.find { |g| g.name == 'UI' } || ecmain_group.new_group('UI')

files = [
  'ECMAIN/ECMAIN/UI/VPNConfigViewController.h',
  'ECMAIN/ECMAIN/UI/VPNConfigViewController.m',
  'ECMAIN/ECMAIN/UI/MainTabBarController.h',
  'ECMAIN/ECMAIN/UI/MainTabBarController.m',
  'ECMAIN/ECMAIN/UI/ProxyTypeSelectionViewController.h',
  'ECMAIN/ECMAIN/UI/ProxyTypeSelectionViewController.m'
]

# Clean group first
ui_group.clear

files.each do |file_path|
  # Add file
  new_file_ref = ui_group.new_reference(File.absolute_path(file_path))
  
  if file_path.end_with?('.m')
    new_file_ref.last_known_file_type = 'sourcecode.c.objc'
    target.source_build_phase.add_file_reference(new_file_ref)
  elsif file_path.end_with?('.h')
    new_file_ref.last_known_file_type = 'sourcecode.c.h'
  end
  
  puts "Added #{file_path} as #{new_file_ref.last_known_file_type}"
end

project.save
puts "Project saved."
