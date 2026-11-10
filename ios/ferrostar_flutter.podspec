# Ferrostar publishes no CocoaPods spec (Swift Package Manager only). Under
# CocoaPods the host app's Podfile must call `ferrostar_flutter_link_spm`
# (ferrostar_flutter_spm.rb, next to this file) from post_install, which attaches
# the Ferrostar Swift package to this pod's target. With Flutter's Swift Package
# Manager integration enabled, ferrostar_flutter/Package.swift is used instead.
Pod::Spec.new do |s|
  s.name             = 'ferrostar_flutter'
  s.version          = '0.1.1'
  s.summary          = 'Headless Flutter bridge to the Ferrostar navigation core.'
  s.description      = 'Headless Flutter bridge to Ferrostar (BSD-3-Clause).'
  s.license          = { :type => 'BSD-3-Clause', :file => '../LICENSE' }
  s.author           = { 'Arham Anwaar' => 'iarhamanwaar@users.noreply.github.com' }
  s.homepage         = 'https://github.com/iarhamanwaar/ferrostar_flutter'
  s.source           = { :path => '.' }
  s.source_files     = 'ferrostar_flutter/Sources/ferrostar_flutter/**/*.swift'
  s.dependency 'Flutter'
  s.platform         = :ios, '16.0'
  s.swift_version    = '5.9'
end
