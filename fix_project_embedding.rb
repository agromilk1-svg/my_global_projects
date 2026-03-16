require 'xcodeproj'

project_path = 'ECMAIN/ECMAIN.xcodeproj'
project = Xcodeproj::Project.open(project_path)

puts "Opening project: #{project_path}"

# 1. Find Targets
main_target = project.targets.find { |t| t.name == 'ECMAIN' }
tunnel_target = project.targets.find { |t| t.name == 'Tunnel' }

if !main_target || !tunnel_target
  puts "Error: Missing targets. Main: #{main_target}, Tunnel: #{tunnel_target}"
  exit 1
end

# 2. Add Target Dependency
# Ensure Main depends on Tunnel (so Tunnel builds first)
unless main_target.dependencies.any? { |d| d.target == tunnel_target }
  main_target.add_dependency(tunnel_target)
  puts "Added dependency: ECMAIN -> Tunnel"
else
  puts "Dependency already exists."
end

# 3. Embed App Extension
# Ensure Main embeds Tunnel.appex
# PBXCopyFilesBuildPhase with dst_subfolder_spec = '13' (PlugIns)
embed_phase = main_target.copy_files_build_phases.find { |p| p.dst_subfolder_spec == "13" }
unless embed_phase
  embed_phase = main_target.new_copy_files_build_phase('Embed App Extensions')
  embed_phase.dst_subfolder_spec = "13"
  puts "Created 'Embed App Extensions' phase."
end

# Add the file reference if not present
tunnel_product_ref = tunnel_target.product_reference
if !tunnel_product_ref
    puts "Error: Tunnel target has no product reference."
    # Try to find it in products group
    tunnel_product_ref = project.products_group.files.find { |f| f.path == 'Tunnel.appex' }
end

if tunnel_product_ref
    unless embed_phase.files.any? { |f| f.file_ref && f.file_ref.uuid == tunnel_product_ref.uuid }
      build_file = embed_phase.add_file_reference(tunnel_product_ref)
      build_file.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
      puts "Added Tunnel.appex to Embed phase."
    else
      puts "Tunnel.appex already embedded."
    end
else
    puts "Error: Could not find Tunnel.appex product reference."
end

# 4. Link Mihomo.xcframework
# Check if it is already linked
frameworks_phase = tunnel_target.frameworks_build_phase

# Robust way to find file reference
mihomo_ref = project.main_group.recursive_children.find { |f| f.respond_to?(:path) && f.path && f.path.include?('Mihomo.xcframework') }

if mihomo_ref
    unless frameworks_phase.files.any? { |f| f.file_ref && f.file_ref.uuid == mihomo_ref.uuid }
        frameworks_phase.add_file_reference(mihomo_ref)
        puts "Linked Mihomo.xcframework to Tunnel."
    else
        puts "Mihomo.xcframework already linked."
    end
else
    puts "Error: Could not find file reference for Mihomo.xcframework in project."
end

# Remove from Embed Frameworks if present (GoMobile frameworks are static)
embed_fw_phase = tunnel_target.copy_files_build_phases.find { |p| p.dst_subfolder_spec == "10" } # Frameworks
if embed_fw_phase
    file_to_remove = embed_fw_phase.files.find { |f| f.file_ref && f.file_ref.uuid == mihomo_ref.uuid }
    if file_to_remove
        embed_fw_phase.remove_build_file(file_to_remove)
        puts "Removed Mihomo.xcframework from Embed Frameworks (Static Linking)."
    end
end


project.save
puts "Project saved."
