require 'xcodeproj'

project_path = 'ECMAIN/ECMAIN.xcodeproj'
project = Xcodeproj::Project.open(project_path)

target = project.targets.find { |t| t.name == 'Tunnel' }

if target
    puts "Configuring Linker Flags for Tunnel..."
    target.build_configuration_list.build_configurations.each do |config|
        ld_flags = config.build_settings['OTHER_LDFLAGS'] || ['$(inherited)']
        
        # Ensure it's an array
        ld_flags = [ld_flags] if ld_flags.is_a?(String)
        
        # Add force_load for Mihomo
        # Path needs to be correct. $(PROJECT_DIR) maps to project root.
        # Frameworks are in ECMAIN/Frameworks usually.
        # But wait, linking against a framework usually handles the path if setup correctly.
        # For force_load we need the path to the binary inside the framework.
        
        # Our framework is at ECMAIN/Frameworks/Mihomo.xcframework/ios-arm64/Mihomo.framework/Mihomo
        # But this depends on architecture.
        # A safer way for XCFrameworks might be tricky with simple LDFLAGS.
        # Usually standard framework linking is enough unless symbols are stripped.
        
        # Let's try adding -all_load just to be sure, or -force_load for the specific framework if possible.
        # Since we are not using lipo manually, we rely on Xcode resolving the XCFramework slice.
        # But -force_load requires a specific file path.
        
        # Valid approach for XCFramework:
        # Just use -ObJC (already there?) or verify stripping.
        # Go Docs say: Drag .xcframework. Done.
        # But maybe we need to disable DEAD_CODE_STRIPPING?
        
        puts "Current LDFLAGS: #{ld_flags}"
        
        # Let's try -all_load first? No, that might conflict with other libs.
        # Let's simple check if we can add -framework Mihomo (should be there)
        # And maybe verify STRIP style.
        
        # User concern: "Where is Mihomo?" -> "It's inside Tunnel".
        # 33MB vs 70MB. 
        # Maybe the 70MB includes debug symbols (DWARF) which are stripped?
        # The .a file in Go build is huge.
        
        # Let's disable Dead Code Stripping to ensure everything is kept.
        config.build_settings['DEAD_CODE_STRIPPING'] = 'NO'
        config.build_settings['STRIP_INSTALLED_PRODUCT'] = 'NO'
        config.build_settings['STRIP_STYLE'] = 'debugging'
        config.build_settings['DEPLOYMENT_POSTPROCESSING'] = 'NO'
        
        puts "Disabled Stripping for Tunnel in config: #{config.name}"
    end
    project.save
    puts "Project saved."
else
    puts "Tunnel target not found."
end
