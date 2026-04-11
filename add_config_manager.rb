require 'xcodeproj'

project_path = '/Users/hh/Desktop/my/ECMAIN/ECMAIN.xcodeproj'
project = Xcodeproj::Project.open(project_path)

target = project.targets.find { |t| t.name == 'ECMAIN' }
ecmain_group = project.main_group.groups.find { |g| g.name == 'ECMAIN' }
core_group = ecmain_group.groups.find { |g| g.name == 'Core' } || ecmain_group.new_group('Core')

files = [
  '/Users/hh/Desktop/my/ECMAIN/ECMAIN/Core/ECConfigManager.h',
  '/Users/hh/Desktop/my/ECMAIN/ECMAIN/Core/ECConfigManager.m'
]

files.each do |file_path|
  # 避免重复添加
  unless core_group.files.find { |f| File.absolute_path(f.real_path) == File.absolute_path(file_path) rescue false }
    new_file_ref = core_group.new_reference(File.absolute_path(file_path))
    if file_path.end_with?('.m')
      new_file_ref.last_known_file_type = 'sourcecode.c.objc'
      # 避免在 build_phase 中重复
      unless target.source_build_phase.files_references.include?(new_file_ref)
        target.source_build_phase.add_file_reference(new_file_ref)
      end
    else
      new_file_ref.last_known_file_type = 'sourcecode.c.h'
    end
    puts "Added #{file_path}"
  else
    puts "Already contains #{file_path}"
  end
end

project.save
puts "Project saved."
