require 'xcodeproj'
project_path = '/Users/hh/Desktop/my/ECMAIN/ECMAIN.xcodeproj'
project = Xcodeproj::Project.open(project_path)
tunnel_group = project.main_group.find_subpath('Tunnel', false)

if tunnel_group
  puts "Group Path: #{tunnel_group.path}"
  puts "Group Source Tree: #{tunnel_group.source_tree}"
  tunnel_group.files.each do |file|
    puts "File: #{file.name} | Path: #{file.path} | Source Tree: #{file.source_tree}"
  end
else
  puts "Tunnel group not found"
end
