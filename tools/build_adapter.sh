#!/bin/zsh
# Builds the vendored mediaremote-adapter into .build/adapter/MediaRemoteAdapter.framework (ad-hoc
# signed), the way its CMakeLists does, with clang only (no CMake on this Mac).
#   tools/build_adapter.sh            (skips the build when the framework is newer than the sources)
set -euo pipefail
cd "$(dirname "$0")/.."
V=Vendor/mediaremote-adapter
OUT=.build/adapter
F=$OUT/MediaRemoteAdapter.framework
BIN=$F/Versions/A/MediaRemoteAdapter

if [[ -f $BIN && -z "$(find $V -newer $BIN -type f | head -1)" ]]; then
  echo "adapter up to date"
  exit 0
fi

rm -rf $F
mkdir -p $F/Versions/A/Resources
clang -dynamiclib -fobjc-arc -fvisibility=default -O2 \
  -arch arm64 -arch x86_64 -mmacosx-version-min=15.0 \
  -I$V/include -I$V/src \
  $V/src/adapter/{env,get,globals,keys,now_playing,repeat,seek,send,shuffle,speed,stream,test}.m \
  $V/src/private/MediaRemote.m $V/src/utility/{Debounce,helpers}.m \
  -framework Foundation -framework AppKit -framework UniformTypeIdentifiers \
  -install_name @rpath/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter \
  -o $BIN
cat > $F/Versions/A/Resources/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.fellipe.liquidnotch.MediaRemoteAdapter</string>
  <key>CFBundleName</key><string>MediaRemoteAdapter</string>
  <key>CFBundleExecutable</key><string>MediaRemoteAdapter</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>0.1.0</string>
</dict></plist>
PLIST
ln -s A $F/Versions/Current
ln -s Versions/Current/MediaRemoteAdapter $F/MediaRemoteAdapter
ln -s Versions/Current/Resources $F/Resources
codesign --force --sign - $F
echo "built $F"
