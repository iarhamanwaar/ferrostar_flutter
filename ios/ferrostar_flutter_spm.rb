# CocoaPods hosts: attach the Ferrostar Swift package to the ferrostar_flutter pod.
#
#   # ios/Podfile
#   require File.expand_path('.symlinks/plugins/ferrostar_flutter/ios/ferrostar_flutter_spm', __dir__)
#   post_install do |installer|
#     ferrostar_flutter_link_spm(installer)   # <- add
#     ...
#   end
#
# (CocoaPods has no native SPM support; this is the same technique React Native uses.)
FERROSTAR_URL = 'https://github.com/stadiamaps/ferrostar'
# Pre-1.0 core: pinned to an exact release on purpose (API churn).
FERROSTAR_VERSION = '0.59.0'

def ferrostar_flutter_link_spm(installer)
  project = installer.pods_project
  target = project.targets.find { |t| t.name == 'ferrostar_flutter' }
  raise 'ferrostar_flutter pod target not found' unless target

  ref = project.root_object.package_references.find do |r|
    r.respond_to?(:repositoryURL) && r.repositoryURL == FERROSTAR_URL
  end
  unless ref
    ref = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
    ref.repositoryURL = FERROSTAR_URL
    ref.requirement = { 'kind' => 'exactVersion', 'version' => FERROSTAR_VERSION }
    project.root_object.package_references << ref
  end

  # The pod is compiled in the Pods project; make the SPM-built modules (the
  # core and its FFI clang module) visible to it.
  target.build_configurations.each do |c|
    c.build_settings['SWIFT_INCLUDE_PATHS'] = '$(inherited) "$(BUILD_DIR)/$(CONFIGURATION)$(EFFECTIVE_PLATFORM_NAME)"'
    c.build_settings['FRAMEWORK_SEARCH_PATHS'] = '$(inherited) "$(BUILD_DIR)/$(CONFIGURATION)$(EFFECTIVE_PLATFORM_NAME)" "$(BUILD_DIR)/$(CONFIGURATION)$(EFFECTIVE_PLATFORM_NAME)/PackageFrameworks"'
  end

  ferrostar_flutter_dedupe_signature(target)

  return if target.package_product_dependencies.any? { |d| d.product_name == 'FerrostarCore' }

  dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  dep.product_name = 'FerrostarCore'
  dep.package = ref
  target.package_product_dependencies << dep
  # Explicit build-order dependency: without it the pod can compile before the
  # package's modules exist ("Unable to resolve module dependency: FerrostarCore").
  td = project.new(Xcodeproj::Project::Object::PBXTargetDependency)
  td.product_ref = dep
  target.dependencies << td
  bf = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  bf.product_ref = dep
  target.frameworks_build_phase.files << bf
end

# Xcode archive bug (Xcode 15, 16 and 26; no Apple fix): a binary SwiftPM xcframework
# that is linked from a pod framework AND the app that contains it gets its
# `.signature` written under both build directories, and `flutter build ipa` then
# fails with "libferrostar-rs.xcframework-ios.signature couldn't be copied to
# Signatures because an item with the same name already exists". The pod removes its
# own copy when it finishes building. It lives in the generated Pods project, so no
# committed project file changes, and it does nothing for simulator or debug builds.
DEDUPE_PHASE = 'Dedupe Ferrostar xcframework signature'

def ferrostar_flutter_dedupe_signature(target)
  return if target.shell_script_build_phases.any? { |p| p.name == DEDUPE_PHASE }

  phase = target.new_shell_script_build_phase(DEDUPE_PHASE)
  phase.shell_script = 'rm -f "${CONFIGURATION_BUILD_DIR}/libferrostar-rs.xcframework-ios.signature"'
  phase.always_out_of_date = '1'
end
