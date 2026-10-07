#!/bin/bash
# Assembles GelScribe.app around the SwiftPM binary (DocumentGroup needs a real bundle with document types).
# Projects (.gelscribe) are the documents. TIFF, PNG and JPEG are listed as viewable at the
# lowest rank, so Open With and the Dock icon take them without GelScribe becoming their default app. An image sent
# that way starts a new untitled project (AppDelegate.application(_:open:)); it is never the document, so macOS can't
# save over an original.
set -e
CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/.build/$CONFIG"
APP="$ROOT/GelScribe.app"

swift build -c "$CONFIG" --product GelScribeApp
swift build -c "$CONFIG" --product gelscribe

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BUILD/GelScribeApp" "$APP/Contents/MacOS/GelScribe"
# The CLI (and MCP server) ships in Helpers/: APFS is case-insensitive, so "gelscribe" next to "GelScribe" in
# MacOS/ would overwrite the app binary.
cp "$BUILD/gelscribe" "$APP/Contents/Helpers/gelscribe"
for bundle in "$BUILD"/*.bundle; do
  [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done
[ -f "$ROOT/Resources/AppIcon.icns" ] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"
# the About window shows Credits.rtf under the copyright (the GitHub link)
[ -f "$ROOT/Resources/Credits.rtf" ] && cp "$ROOT/Resources/Credits.rtf" "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>GelScribe</string>
  <key>CFBundleDisplayName</key><string>GelScribe</string>
  <key>CFBundleIdentifier</key><string>local.gelscribe</string>
  <key>CFBundleExecutable</key><string>GelScribe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Pratiman De</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>GelScribe Project</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Owner</string>
      <key>LSTypeIsPackage</key><true/>
      <key>LSItemContentTypes</key><array><string>local.gelscribe.project</string></array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>Gel Image</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>public.tiff</string><string>public.png</string><string>public.jpeg</string></array>
    </dict>
  </array>
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>local.gelscribe.project</string>
      <key>UTTypeDescription</key><string>GelScribe Project</string>
      <key>UTTypeConformsTo</key><array><string>com.apple.package</string><string>public.composite-content</string></array>
      <key>UTTypeTagSpecification</key>
      <dict><key>public.filename-extension</key><array><string>gelscribe</string></array></dict>
    </dict>
    <dict>
      <!-- a gel's place in the stack, dragged inside the Gels list only -->
      <key>UTTypeIdentifier</key><string>local.gelscribe.gel-place</string>
      <key>UTTypeDescription</key><string>GelScribe Gel Position</string>
      <key>UTTypeConformsTo</key><array><string>public.data</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

# Ad-hoc signing: macOS won't run (or keep Keychain access for) an unsigned bundle reliably, so a failure stops the build.
if ! out=$(codesign --force --deep --sign - "$APP" 2>&1); then
  echo "codesign failed, so $APP is not signed:" >&2
  echo "$out" >&2
  exit 1
fi
if ! out=$(codesign --verify --deep --strict "$APP" 2>&1); then
  echo "the signature of $APP does not verify:" >&2
  echo "$out" >&2
  exit 1
fi
echo "built $APP"
