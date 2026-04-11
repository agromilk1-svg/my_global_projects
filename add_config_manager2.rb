require 'xcodeproj'
project_path = '/Users/hh/Desktop/my/ECMAIN/ECMAIN.xcodeproj'
project = Xcodeproj::Project.open(project_path)

target = project.targets.find { |t| t.name == 'ECMAIN' }

file_path = '/Users/hh/Desktop/my/ECMAIN/ECMAIN/Core/ECConfigManager.m'

# Find the file reference anywhere in the project
file_ref = project.files.find { |f| File.absolute_path(f.real_path) == File.absolute_path(file_path) rescue false }

if file_ref
  # Check if it's in the build phase
  unless target.source_build_phase.files_references.include?(file_ref)
    target.source_build_phase.add_file_reference(file_ref)
    puts "Added existing file_ref to source_build_phase"
  else
    puts "Already in source_build_phase"
  end
else
  # Fallback just in case
  ecmain_group = project.main_group.groups.find { |g| g.name == 'ECMAIN' }
  core_group = ecmain_group.groups.find { |g| g.name == 'Core' }
  new_file_ref = core_group.new_reference(File.absolute_path(file_path))
  target.source_build_phase.add_file_reference(new_file_ref)
  puts "Created new file_ref and added to source_build_phase"
end

project.save
