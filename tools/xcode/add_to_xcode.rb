require 'xcodeproj'

project_path = 'ECMAIN/ECMAIN.xcodeproj'
project = Xcodeproj::Project.open(project_path)

target = project.targets.find { |t| t.name == 'ECMAIN' }
unless target
  puts "Target ECMAIN not found"
  exit 1
end

# Remove wrong files
wrong_paths = [
  'ECMAIN/ECMAIN/Core/ECVPNConfigManager.m',
  'ECMAIN/ECMAIN/UI/ECHomeViewController.m',
  'ECMAIN/ECMAIN/UI/ECNodeSelectionViewController.m',
  'ECMAIN/ECMAIN/Core/ECVPNConfigManager.h',
  'ECMAIN/ECMAIN/UI/ECHomeViewController.h',
  'ECMAIN/ECMAIN/UI/ECNodeSelectionViewController.h'
]

project.files.each do |file|
  if wrong_paths.include?(file.path)
    # Remove from build phases
    target.source_build_phase.files_references.delete(file)
    # Remove from project
    file.remove_from_project
    puts "Removed wrong file reference: #{file.path}"
  end
end

# Define correct files relative to the .xcodeproj location (which is inside ECMAIN/)
# Wait, actually, the xcodeproj is at ECMAIN/ECMAIN.xcodeproj. The source files are at ECMAIN/ECMAIN/Core/ECVPNConfigManager.m
# If the python script runs from the repository root (/Users/hh/Desktop/my), then we passed 'ECMAIN/ECMAIN/Core/ECVPNConfigManager.m'.
# But typically xcodeproj expects paths relative to its project root (i.e. /Users/hh/Desktop/my/ECMAIN).
# So the path relative to /Users/hh/Desktop/my/ECMAIN is "ECMAIN/Core/ECVPNConfigManager.m"

files_to_add = [
  'ECMAIN/Core/ECVPNConfigManager.h',
  'ECMAIN/Core/ECVPNConfigManager.m',
  'ECMAIN/UI/ECHomeViewController.h',
  'ECMAIN/UI/ECHomeViewController.m',
  'ECMAIN/UI/ECNodeSelectionViewController.h',
  'ECMAIN/UI/ECNodeSelectionViewController.m'
]

files_to_add.each do |file_path|
  # Skip if already in project
  next if project.files.any? { |f| f.path == file_path }
  
  puts "Adding #{file_path}"
  
  file_ref = project.main_group.new_reference(file_path)
  
  # For Xcode, path should usually be relative to the group, but putting it in main_group with a relative path works if source tree is SOURCE_ROOT.
  file_ref.source_tree = 'SOURCE_ROOT'
  
  if file_path.end_with?('.m') || file_path.end_with?('.c') || file_path.end_with?('.swift')
    target.source_build_phase.add_file_reference(file_ref, true)
  end
end

project.save
puts "Saved Xcode project."
