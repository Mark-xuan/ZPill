$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
Push-Location $repoRoot
$videoPath = Join-Path $repoRoot 'lib/platform/video_player.dart'
$wrapperPath = Join-Path $repoRoot 'android/gradle/wrapper/gradle-wrapper.properties'
$videoBytes = [IO.File]::ReadAllBytes($videoPath)
$wrapperBytes = [IO.File]::ReadAllBytes($wrapperPath)
try {
  $utf8 = [Text.UTF8Encoding]::new($false)
  $video = $utf8.GetString($videoBytes).Replace("`r`n", "`n")
  $pattern = "(?ms)^  if \(Platform\.operatingSystem == 'ohos'\) \{\n    return OhosView\(.*?^  \}\n"
  if ([regex]::Matches($video, $pattern).Count -ne 1) { throw 'Expected one HarmonyOS view branch' }
  [IO.File]::WriteAllText($videoPath, [regex]::Replace($video, $pattern, ''), $utf8)
  $wrapper = $utf8.GetString($wrapperBytes).Replace('mirrors.cloud.tencent.com/gradle/', 'services.gradle.org/distributions/')
  [IO.File]::WriteAllText($wrapperPath, $wrapper, $utf8)
  $sdk = Join-Path $repoRoot 'build/android-sdk'
  if (Test-Path $sdk) { $env:ANDROID_HOME = $sdk; $env:ANDROID_SDK_ROOT = $sdk }
  $buildArgs = @('build','apk','--debug','--no-pub')
  & flutter @buildArgs
  if ($LASTEXITCODE -ne 0) { throw "APK build failed: $LASTEXITCODE" }
  $target = "build/app/outputs/flutter-apk/zpill-z30.apk"
  Copy-Item 'build/app/outputs/flutter-apk/app-debug.apk' $target -Force
  Write-Host "APK: $(Join-Path $repoRoot $target)"
} finally {
  [IO.File]::WriteAllBytes($videoPath, $videoBytes)
  [IO.File]::WriteAllBytes($wrapperPath, $wrapperBytes)
  Pop-Location
}
