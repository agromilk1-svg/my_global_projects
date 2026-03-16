require 'xcodeproj'

project_path = '/Users/hh/Desktop/my/WebDriverAgent.xcodeproj'
project = Xcodeproj::Project.open(project_path)

target = project.targets.find { |t| t.name == 'WebDriverAgentRunner' }

if target
  puts "Target: #{target.name}"
  resources_phase = target.build_phases.find { |p| p.isa == 'PBXResourcesBuildPhase' }
  if resources_phase
    puts "Resources Build Phase found."
    files = resources_phase.files.map { |f| f.file_ref.display_name if f.file_ref }.compact
    puts "Files in Resources:"
    files.each { |f| puts "  - #{f}" }
    
    if files.include?('Assets.xcassets')
      puts "Assets.xcassets is present."
    else
      puts "Assets.xcassets is MISSING!"
    end
  else
    puts "No Resources Build Phase found!"
  end
else
  puts "Target WebDriverAgentRunner not found!"
end
