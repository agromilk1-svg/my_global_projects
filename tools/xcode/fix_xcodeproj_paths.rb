require 'xcodeproj'
project_path = '/Users/hh/Desktop/my/ECMAIN/ECMAIN.xcodeproj'
project = Xcodeproj::Project.open(project_path)
tunnel_group = project.main_group.find_subpath('Tunnel', false)

if tunnel_group
  tunnel_group.files.each do |file|
    # Strip "Tunnel/" prefix if present
    if file.path.start_with?("Tunnel/")
      new_path = file.path.sub("Tunnel/", "")
      puts "Changing #{file.path} to #{new_path}"
      file.path = new_path
    end
  end
  project.save
  puts "Fixed paths."
else
  puts "Tunnel group not found"
end
