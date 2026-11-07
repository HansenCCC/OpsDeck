#!/usr/bin/env ruby
# Generate OpsDeck.xcodeproj. Re-run after adding source files or resources.
require 'fileutils'
require 'xcodeproj'

ROOT = File.expand_path(File.dirname(__FILE__))
PROJ = File.join(ROOT, 'OpsDeck.xcodeproj')
SRC = File.join(ROOT, 'OpsDeck')
TEST_SRC = File.join(ROOT, 'OpsDeckTests')
LOCK = File.join(PROJ, 'project.xcworkspace/xcshareddata/swiftpm/Package.resolved')
resolved_packages = File.binread(LOCK) if File.file?(LOCK)

FileUtils.rm_rf(PROJ)

project = Xcodeproj::Project.new(PROJ)
project.root_object.known_regions = ['en', 'zh-Hans', 'zh-Hant', 'ar', 'de', 'ru', 'fr', 'ko', 'pt-BR', 'ja', 'tr', 'es', 'Base']
project.root_object.development_region = 'zh-Hans'

target = project.new_target(:application, 'OpsDeck', :osx, '15.0')
test_target = project.new_target(:unit_test_bundle, 'OpsDeckTests', :osx, '15.0')
test_target.add_dependency(target)
main_group = project.main_group.new_group('OpsDeck', 'OpsDeck')
test_group = project.main_group.new_group('OpsDeckTests', 'OpsDeckTests')

def add_remote_package(project, target, url:, product:, minimum_version:)
  package = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
  package.repositoryURL = url
  package.requirement = {
    'kind' => 'upToNextMajorVersion',
    'minimumVersion' => minimum_version
  }
  project.root_object.package_references << package

  dependency = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  dependency.product_name = product
  dependency.package = package
  target.package_product_dependencies << dependency

  build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build_file.product_ref = dependency
  target.frameworks_build_phase.files << build_file
end

Dir.glob(File.join(SRC, '**', '*.swift')).sort.each do |path|
  rel = path.sub(SRC + '/', '')
  parts = rel.split('/')
  group = main_group
  parts[0...-1].each do |dir|
    group = group.children.find { |c| c.display_name == dir && c.is_a?(Xcodeproj::Project::Object::PBXGroup) } || group.new_group(dir, dir)
  end
  ref = group.new_file(path)
  target.add_file_references([ref])
end

Dir.glob(File.join(TEST_SRC, '**', '*.swift')).sort.each do |path|
  ref = test_group.new_file(path)
  test_target.add_file_references([ref])
end

resources = [
  'Resources/Assets.xcassets',
  'Resources/Localizable.xcstrings',
  'PrivacyInfo.xcprivacy'
]

resources.each do |rel|
  path = File.join(SRC, rel)
  next unless File.exist?(path)

  ref = main_group.new_file(path)
  target.add_resources([ref])
end

# Bundle upstream license and notice texts with distributed applications.
notices = project.main_group.new_group('Third-party notices')
([File.join(ROOT, 'THIRD_PARTY_NOTICES.md')] + Dir.glob(File.join(ROOT, 'docs/licenses/*.txt'))).each do |path|
  target.add_resources([notices.new_file(path)])
end

info_plist_strings = Dir.glob(File.join(SRC, '*.lproj', 'InfoPlist.strings')).sort
unless info_plist_strings.empty?
  variant = main_group.new_variant_group('InfoPlist.strings')
  info_plist_strings.each do |path|
    locale = File.basename(File.dirname(path), '.lproj')
    ref = variant.new_file(path)
    ref.name = locale
  end
  target.add_resources([variant])
end

main_group.new_file(File.join(SRC, 'Info.plist'))
main_group.new_file(File.join(SRC, 'OpsDeck.entitlements'))
main_group.new_file(File.join(ROOT, 'Products.storekit')) if File.exist?(File.join(ROOT, 'Products.storekit'))

unless ENV['OPSDECK_DISABLE_CITADEL'] == '1'
  add_remote_package(
    project,
    target,
    url: 'https://github.com/orlandos-nl/Citadel',
    product: 'Citadel',
    minimum_version: '0.12.1'
  )
end

unless ENV['OPSDECK_DISABLE_SWIFTTERM'] == '1'
  add_remote_package(
    project,
    target,
    url: 'https://github.com/migueldeicaza/SwiftTerm.git',
    product: 'SwiftTerm',
    minimum_version: '1.14.0'
  )
end

target.build_configurations.each do |config|
  s = config.build_settings
  s['OPSDECK_BUNDLE_IDENTIFIER'] = 'com.hansen.opsdeck'
  s['PRODUCT_BUNDLE_IDENTIFIER'] = '$(OPSDECK_BUNDLE_IDENTIFIER)'
  s['PRODUCT_NAME'] = 'OpsDeck'
  s['MACOSX_DEPLOYMENT_TARGET'] = '15.0'
  s['SWIFT_VERSION'] = '5.0'
  s['INFOPLIST_FILE'] = 'OpsDeck/Info.plist'
  s['CODE_SIGN_ENTITLEMENTS'] = 'OpsDeck/OpsDeck.entitlements'
  s['GENERATE_INFOPLIST_FILE'] = 'NO'
  s['ENABLE_HARDENED_RUNTIME'] = 'YES'
  s['ASSETCATALOG_COMPILER_APPICON_NAME'] = 'AppIcon'
  s['ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME'] = 'AccentColor'
  # Local builds work without a maintainer certificate. Distribution uses a private xcconfig.
  s['CODE_SIGN_STYLE'] = 'Manual'
  s['DEVELOPMENT_TEAM'] = ''
  s['CODE_SIGN_IDENTITY'] = '-'
  s['COMBINE_HIDPI_IMAGES'] = 'YES'
  s['LD_RUNPATH_SEARCH_PATHS'] = ['$(inherited)', '@executable_path/../Frameworks']
  s['MARKETING_VERSION'] = '1.2.1'
  s['CURRENT_PROJECT_VERSION'] = '0725'
end


test_target.build_configurations.each do |config|
  s = config.build_settings
  s['OPSDECK_BUNDLE_IDENTIFIER'] = 'com.hansen.opsdeck'
  s['PRODUCT_BUNDLE_IDENTIFIER'] = '$(OPSDECK_BUNDLE_IDENTIFIER).tests'
  s['CODE_SIGN_STYLE'] = 'Manual'
  s['DEVELOPMENT_TEAM'] = ''
  s['CODE_SIGN_IDENTITY'] = '-'
  s['PRODUCT_NAME'] = 'OpsDeckTests'
  s['MACOSX_DEPLOYMENT_TARGET'] = '15.0'
  s['SWIFT_VERSION'] = '5.0'
  s['GENERATE_INFOPLIST_FILE'] = 'YES'
  s['TEST_HOST'] = '$(BUILT_PRODUCTS_DIR)/OpsDeck.app/Contents/MacOS/OpsDeck'
  s['BUNDLE_LOADER'] = '$(TEST_HOST)'
end

project.save

scheme_dir = File.join(PROJ, 'xcshareddata', 'xcschemes')
FileUtils.mkdir_p(scheme_dir)
File.write(File.join(scheme_dir, 'OpsDeck.xcscheme'), <<~XML)
  <?xml version="1.0" encoding="UTF-8"?>
  <Scheme
     LastUpgradeVersion = "2600"
     version = "1.7">
     <BuildAction
        parallelizeBuildables = "YES"
        buildImplicitDependencies = "YES">
        <BuildActionEntries>
           <BuildActionEntry
              buildForTesting = "YES"
              buildForRunning = "YES"
              buildForProfiling = "YES"
              buildForArchiving = "YES"
              buildForAnalyzing = "YES">
              <BuildableReference
                 BuildableIdentifier = "primary"
                 BlueprintIdentifier = "#{target.uuid}"
                 BuildableName = "OpsDeck.app"
                 BlueprintName = "OpsDeck"
                 ReferencedContainer = "container:OpsDeck.xcodeproj">
              </BuildableReference>
           </BuildActionEntry>
           <BuildActionEntry
              buildForTesting = "YES"
              buildForRunning = "NO"
              buildForProfiling = "NO"
              buildForArchiving = "NO"
              buildForAnalyzing = "YES">
              <BuildableReference
                 BuildableIdentifier = "primary"
                 BlueprintIdentifier = "#{test_target.uuid}"
                 BuildableName = "OpsDeckTests.xctest"
                 BlueprintName = "OpsDeckTests"
                 ReferencedContainer = "container:OpsDeck.xcodeproj">
              </BuildableReference>
           </BuildActionEntry>
        </BuildActionEntries>
     </BuildAction>
     <TestAction
        buildConfiguration = "Debug"
        selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
        selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
        shouldUseLaunchSchemeArgsEnv = "YES">
        <Testables>
           <TestableReference
              skipped = "NO">
              <BuildableReference
                 BuildableIdentifier = "primary"
                 BlueprintIdentifier = "#{test_target.uuid}"
                 BuildableName = "OpsDeckTests.xctest"
                 BlueprintName = "OpsDeckTests"
                 ReferencedContainer = "container:OpsDeck.xcodeproj">
              </BuildableReference>
           </TestableReference>
        </Testables>
     </TestAction>
     <LaunchAction
        buildConfiguration = "Debug"
        selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
        selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
        launchStyle = "0"
        useCustomWorkingDirectory = "NO"
        ignoresPersistentStateOnLaunch = "NO"
        debugDocumentVersioning = "YES"
        debugServiceExtension = "internal"
        allowLocationSimulation = "YES">
        <BuildableProductRunnable
           runnableDebuggingMode = "0">
           <BuildableReference
              BuildableIdentifier = "primary"
              BlueprintIdentifier = "#{target.uuid}"
              BuildableName = "OpsDeck.app"
              BlueprintName = "OpsDeck"
              ReferencedContainer = "container:OpsDeck.xcodeproj">
           </BuildableReference>
        </BuildableProductRunnable>
        <StoreKitConfigurationFileReference
           identifier = "../Products.storekit">
        </StoreKitConfigurationFileReference>
     </LaunchAction>
     <ProfileAction
        buildConfiguration = "Release"
        shouldUseLaunchSchemeArgsEnv = "YES"
        savedToolIdentifier = ""
        useCustomWorkingDirectory = "NO"
        debugDocumentVersioning = "YES">
        <BuildableProductRunnable
           runnableDebuggingMode = "0">
           <BuildableReference
              BuildableIdentifier = "primary"
              BlueprintIdentifier = "#{target.uuid}"
              BuildableName = "OpsDeck.app"
              BlueprintName = "OpsDeck"
              ReferencedContainer = "container:OpsDeck.xcodeproj">
           </BuildableReference>
        </BuildableProductRunnable>
     </ProfileAction>
     <AnalyzeAction
        buildConfiguration = "Debug">
     </AnalyzeAction>
     <ArchiveAction
        buildConfiguration = "Release"
        revealArchiveInOrganizer = "YES">
     </ArchiveAction>
  </Scheme>
XML
if resolved_packages
  FileUtils.mkdir_p(File.dirname(LOCK))
  File.binwrite(LOCK, resolved_packages)
end
puts "Generated #{PROJ}"
