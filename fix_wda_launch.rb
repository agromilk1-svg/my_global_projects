require 'xcodeproj'
require 'fileutils'

# Configuration
PROJECT_PATH = 'WebDriverAgent.xcodeproj'
ENTITLEMENTS_PATH = 'WDA_Standard.entitlements'
TARGET_NAME = 'WebDriverAgentRunner'
NEW_BUNDLE_ID = 'com.ecwda.runner'

def usage
  puts "Usage: ruby fix_wda_launch.rb <YOUR_TEAM_ID>"
  puts "Example: ruby fix_wda_launch.rb HBQHWTT87F"
  exit 1
end

team_id = ARGV[0]
usage if team_id.nil? || team_id.empty?

puts "=== Fixing WebDriverAgentRunner Launch Config ==="
puts "Team ID: #{team_id}"

# 1. Update Entitlements File
puts "\n[1/2] Updating #{ENTITLEMENTS_PATH}..."
if File.exist?(ENTITLEMENTS_PATH)
  content = File.read(ENTITLEMENTS_PATH)
  
  # Replace Team ID and App ID prefix
  # Regex to match the standard format including the hardcoded one we saw
  updated_content = content.gsub(/<string>[A-Z0-9]{10}\.com\.ecwda\.runner<\/string>/, "<string>#{team_id}.com.ecwda.runner</string>")
  updated_content = updated_content.gsub(/<string>[A-Z0-9]{10}<\/string>/) { |match|
    # Only replace if it looks like a Team ID (10 chars key content), avoid replacing other random strings if possible
    # But for now, we know specifically we want to replace the Team ID field.
    # Let's be more specific with the key context if we were parsing XML, but regex is fine for this specific file structure we saw.
    # The file has <key>com.apple.developer.team-identifier</key> followed by <string>...</string>
    match
  }
  
  # Better regex approach using lookbehind isn't fully supported in all ruby versions/contexts easily, 
  # so let's just do a direct replacement of the known ID 'HBQHWTT87F' if present, otherwise warn key update might need manual check.
  # If the user has a different ID currently there, we might miss it.
  # Let's try to match the pattern.
  
  # Replace Team ID associated with team-identifier key
  if content =~ /<key>com.apple.developer.team-identifier<\/key>\s*<string>([^<]+)<\/string>/
    old_team_id = $1
    puts "  Found existing Team ID: #{old_team_id}"
    updated_content = updated_content.gsub("<string>#{old_team_id}</string>", "<string>#{team_id}</string>")
    updated_content = updated_content.gsub("#{old_team_id}.com.ecwda.runner", "#{team_id}.com.ecwda.runner")
  else
    puts "  ⚠️ Could not find standard Team ID pattern. Attempting specific replacement of HBQHWTT87F if present."
    updated_content = updated_content.gsub("HBQHWTT87F", team_id)
  end

  File.write(ENTITLEMENTS_PATH, updated_content)
  puts "  ✅ Updated Entitlements"
else
  puts "  ❌ Error: #{ENTITLEMENTS_PATH} not found!"
  exit 1
end

# 2. Update Xcode Project
puts "\n[2/2] Updating Xcode Project #{PROJECT_PATH}..."
project = Xcodeproj::Project.open(PROJECT_PATH)
target = project.targets.find { |t| t.name == TARGET_NAME }

if target
  puts "  Found target: #{target.name}"
  
  target.build_configuration_list.build_configurations.each do |config|
    puts "  Updating config: #{config.name}"
    
    # Update Bundle ID
    old_bid = config.build_settings['PRODUCT_BUNDLE_IDENTIFIER']
    config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = NEW_BUNDLE_ID
    puts "    Bundle ID: #{old_bid} -> #{NEW_BUNDLE_ID}"
    
    # Set Entitlements Path
    config.build_settings['CODE_SIGN_ENTITLEMENTS'] = ENTITLEMENTS_PATH
    puts "    Set CODE_SIGN_ENTITLEMENTS = #{ENTITLEMENTS_PATH}"
    
    # Set Team ID
    config.build_settings['DEVELOPMENT_TEAM'] = team_id
    puts "    Set DEVELOPMENT_TEAM = #{team_id}"
  end
  
  project.save
  puts "  ✅ Project Saved"
else
  puts "  ❌ Target #{TARGET_NAME} not found!"
  exit 1
end

puts "\n=== Fix Complete ==="
puts "Now please try running/testing in Xcode again."
