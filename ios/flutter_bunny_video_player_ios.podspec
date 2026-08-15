#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html
#
Pod::Spec.new do |s|
  s.name             = 'flutter_bunny_video_player_ios'
  s.version          = '0.0.1'
  s.summary          = 'Bunny native player for Mirmaz lessons.'
  s.description      = <<-DESC
Native Bunny Stream player used for type_video: "mirmaz" lessons.
                       DESC
  s.homepage         = 'http://example.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Your Company' => 'email@example.com' }
  s.source           = { :path => '.' }
  s.source_files = 'flutter_bunny_video_player_ios/Sources/flutter_bunny_video_player_ios/**/*'
  s.dependency 'Flutter'
  s.dependency 'BunnyStreamPlayer'
  s.platform = :ios, '15.6'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
  }
  s.swift_version = '5.0'
end
