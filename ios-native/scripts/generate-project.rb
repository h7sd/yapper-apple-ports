#!/usr/bin/env ruby
# Optional project regeneration; the committed project builds without Ruby.
require 'xcodeproj'
require 'fileutils'

root = File.expand_path('..', __dir__)
path = File.join(root, 'YapperNative.xcodeproj')
project = Xcodeproj::Project.new(path)
project.root_object.attributes['LastUpgradeCheck'] = '2600'
app = project.new_target(:application, 'YapperNative', :ios, '17.0')
unit = project.new_target(:unit_test_bundle, 'YapperNativeTests', :ios, '17.0')
ui = project.new_target(:ui_test_bundle, 'YapperNativeUITests', :ios, '17.0')
unit.add_dependency(app)
ui.add_dependency(app)

[[app, 'YapperNative'], [unit, 'YapperNativeTests'], [ui, 'YapperNativeUITests']].each do |target, directory|
  group = project.main_group.new_group(directory, directory)
  Dir.glob(File.join(root, directory, '**', '*.swift')).sort.each do |file|
    ref = group.new_file(file.delete_prefix(File.join(root, directory) + '/'))
    target.source_build_phase.add_file_reference(ref)
  end
  target.build_configurations.each do |config|
    config.build_settings.merge!({
      'SWIFT_VERSION' => '6.0',
      'SWIFT_STRICT_CONCURRENCY' => 'complete',
      'SWIFT_APPROACHABLE_CONCURRENCY' => 'YES',
      'SWIFT_DEFAULT_ACTOR_ISOLATION' => 'MainActor',
      'SWIFT_UPCOMING_FEATURE_NONISOLATED_NONSENDING_BY_DEFAULT' => 'YES',
      'PRODUCT_BUNDLE_IDENTIFIER' => "website.yapper.native.ios#{target == app ? '' : '.' + target.name}",
      'TARGETED_DEVICE_FAMILY' => '1,2',
      'CODE_SIGN_STYLE' => 'Automatic',
      'CURRENT_PROJECT_VERSION' => '1',
      'MARKETING_VERSION' => '0.1.0',
      'CLANG_ENABLE_MODULES' => 'YES',
      'ENABLE_USER_SCRIPT_SANDBOXING' => 'YES',
      'GENERATE_INFOPLIST_FILE' => target == app ? 'NO' : 'YES'
    })
    if target == app
      config.build_settings.merge!({
        'INFOPLIST_FILE' => 'YapperNative/Info.plist',
        'ASSETCATALOG_COMPILER_APPICON_NAME' => 'AppIcon',
        'ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME' => 'AccentColor',
        'LD_RUNPATH_SEARCH_PATHS' => ['$(inherited)', '@executable_path/Frameworks']
      })
    else
      config.build_settings['TEST_TARGET_NAME'] = 'YapperNative'
      config.build_settings['SWIFT_DEFAULT_ACTOR_ISOLATION'] = 'nonisolated' if target == ui
      if target == unit
        config.build_settings['TEST_HOST'] = '$(BUILT_PRODUCTS_DIR)/YapperNative.app/YapperNative'
        config.build_settings['BUNDLE_LOADER'] = '$(TEST_HOST)'
      end
    end
  end
end
assets = project.main_group.find_subpath('YapperNative', false).new_file('Assets.xcassets')
app.resources_build_phase.add_file_reference(assets)
privacy = project.main_group.find_subpath('YapperNative', false).new_file('PrivacyInfo.xcprivacy')
app.resources_build_phase.add_file_reference(privacy)
project.build_configurations.each do |config|
  config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '17.0'
  config.build_settings['SDKROOT'] = 'iphoneos'
  config.build_settings['SWIFT_VERSION'] = '6.0'
  config.build_settings['CLANG_ENABLE_MODULES'] = 'YES'
end
project.save
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.set_launch_target(app)
scheme.add_test_target(unit)
scheme.add_test_target(ui)
scheme.save_as(path, 'YapperNative', true)
puts "Generated #{File.basename(path)}"
