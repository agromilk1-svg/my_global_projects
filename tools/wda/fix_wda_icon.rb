require 'xcodeproj'

project_path = '/Users/hh/Desktop/my/WebDriverAgent.xcodeproj'
project = Xcodeproj::Project.open(project_path)

# Iterate over all targets
project.targets.each do |target|
  puts "Checking target: #{target.name}"
  if target.name == 'WebDriverAgentRunner'
    target.build_configurations.each do |config|
      puts "  Setting ASSETCATALOG_COMPILER_APPICON_NAME for #{config.name}"
      config.build_settings['ASSETCATALOG_COMPILER_APPICON_NAME'] = 'AppIcon'
    end
  end
end

project.save
puts "Saved WebDriverAgent.xcodeproj"
