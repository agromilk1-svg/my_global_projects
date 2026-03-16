require 'xcodeproj'
project_path = '/Users/hh/Desktop/my/ECMAIN/ECMAIN.xcodeproj'
project = Xcodeproj::Project.open(project_path)

tunnel_target = project.targets.find { |t| t.name == 'Tunnel' }
if tunnel_target
  files_to_remove = []
  tunnel_target.source_build_phase.files.each do |build_file|
    file_ref = build_file.file_ref
    if file_ref && file_ref.respond_to?(:path) && file_ref.path
      if file_ref.path.include?('ECTaskPollManager.m') || file_ref.path.include?('ECTaskListViewController.m')
        files_to_remove << build_file
        puts "Found #{file_ref.path} in Tunnel target"
      end
    end
  end
  
  files_to_remove.each do |bf|
    tunnel_target.source_build_phase.remove_build_file(bf)
    puts "Removed!"
  end
  
  project.save
  puts "Successfully cleaned Tunnel target."
else
  puts "Tunnel target not found."
end
