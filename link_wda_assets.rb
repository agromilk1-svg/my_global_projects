require 'xcodeproj'
project_path = '/Users/hh/Desktop/my/WebDriverAgent.xcodeproj'
project = Xcodeproj::Project.open(project_path)
target = project.targets.find { |t| t.name == 'WebDriverAgentRunner' }
group = project.main_group.groups.find { |g| g.name == 'WebDriverAgentRunner' }

if group && target
  file_ref = group.files.find { |f| f.path == 'Assets.xcassets' }
  unless file_ref
    puts "Adding Assets.xcassets reference..."
    file_ref = group.new_reference('Assets.xcassets')
  end
  
  resources_phase = target.resources_build_phase
  entry = resources_phase.files.find { |f| f.file_ref == file_ref }
  unless entry
    puts "Adding to Resource Build Phase..."
    resources_phase.add_file_reference(file_ref)
    project.save
    puts "Saved project."
  else
    puts "Already linked."
  end
else
  puts "Group or Target not found."
end
