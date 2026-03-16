require 'xcodeproj'
require 'fileutils'

project_path = 'ECMAIN/ECMAIN.xcodeproj'
project = Xcodeproj::Project.open(project_path)

# Framework Artifact Name
framework_name = 'Mihomo.xcframework'
source_path = File.join(Dir.pwd, framework_name)
dest_dir = File.join(Dir.pwd, 'ECMAIN', 'Frameworks')
dest_path = File.join(dest_dir, framework_name)

# Ensure Frameworks dir exists
FileUtils.mkdir_p(dest_dir)

# Check if user put the file in root
# Check if user put the file in root
if File.exist?(source_path)
  puts "Moving #{framework_name} to #{dest_dir}..."
  FileUtils.rm_rf(dest_path) if File.exist?(dest_path)
  FileUtils.mv(source_path, dest_path)
elsif File.exist?(dest_path)
  puts "Framework already in destination."
else
  puts "Error: #{framework_name} not found in current directory or destination."
  puts "Please build it via GitHub Actions, download it, unzip if needed, and place #{framework_name} here."
  exit 1
end

# Add to Xcode Project
# We need to add it to the Tunnel target (Extension) and arguably Main App if we embed it?
# Usually PacketTunnelProvider needs it.
target_name = 'Tunnel' 
target = project.targets.find { |t| t.name == target_name }

unless target
  puts "Error: Target #{target_name} not found."
  exit 1
end

# Create Frameworks group if needed
group = project.main_group['Frameworks'] || project.main_group.new_group('Frameworks')
file_ref = group.new_reference(dest_path)

# Add to Frameworks Build Phase
build_phase = target.frameworks_build_phase
unless build_phase.files.any? { |f| f.file_ref && f.file_ref.path == dest_path }
  build_phase.add_file_reference(file_ref)
  puts "Linked #{framework_name} to #{target_name} build phase."
else
  puts "#{framework_name} already linked."
end

# Add to Embed Frameworks Build Phase (if needed for Extension, usually yes for dynamic frameworks)
# Check if it's dynamic. Assuming yes.
# Extensions usually need Embed Frameworks.
embed_phase = target.build_phases.find { |bp| bp.isa == 'PBXCopyFilesBuildPhase' && bp.dst_subfolder_spec == "10" }
unless embed_phase
  embed_phase = target.new_copy_files_build_phase('Embed Frameworks')
  embed_phase.dst_subfolder_spec = "10" # Frameworks directory
end

unless embed_phase.files.any? { |f| f.file_ref && f.file_ref.path == dest_path }
  build_file = embed_phase.add_file_reference(file_ref)
  build_file.settings = { 'ATTRIBUTES' => ['CodeSignOnCopy', 'RemoveHeadersOnCopy'] }
  puts "Added to Embed Frameworks phase."
else
  puts "Already in Embed Frameworks phase."
end

project.save
puts "Project saved. Mihomo integrated."
