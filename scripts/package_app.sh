#!/bin/bash
set -euo pipefail

APP_NAME="Jot"
APP_BUNDLE="${APP_NAME}.app"
BUILD_BIN=".build/arm64-apple-macosx/release/${APP_NAME}"

echo "Creating ${APP_BUNDLE}..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

# Copy binary
cp "${BUILD_BIN}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
chmod +x "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

# Create Info.plist with variables resolved
cat << 'PLIST' > "${APP_BUNDLE}/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleDisplayName</key>
	<string>Jot</string>
	<key>CFBundleExecutable</key>
	<string>Jot</string>
	<key>CFBundleIconFile</key>
	<string>Jot</string>
	<key>CFBundleIdentifier</key>
	<string>com.ammaar.jot</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>Jot</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.4.0</string>
	<key>CFBundleURLTypes</key>
	<array>
		<dict>
			<key>CFBundleURLName</key>
			<string>com.ammaar.jot.url</string>
			<key>CFBundleURLSchemes</key>
			<array>
				<string>jot</string>
			</array>
		</dict>
	</array>
	<key>CFBundleVersion</key>
	<string>9</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.productivity</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHumanReadableCopyright</key>
	<string>Copyright 2026 Google LLC. Apache License 2.0. This is not an officially supported Google product.</string>
	<key>NSMicrophoneUsageDescription</key>
	<string>Jot records audio while you hold the dictation key, so it can transcribe what you say.</string>
</dict>
</plist>
PLIST

# Copy resources
if [ -f "App/Resources/Jot.icns" ]; then
    cp "App/Resources/Jot.icns" "${APP_BUNDLE}/Contents/Resources/"
fi

if [ -d "App/Resources/Fonts" ]; then
    cp -R "App/Resources/Fonts" "${APP_BUNDLE}/Contents/Resources/"
fi

if [ -d "App/Resources/Sounds" ]; then
    cp -R "App/Resources/Sounds" "${APP_BUNDLE}/Contents/Resources/"
fi

# Ad-hoc code sign with entitlements
echo "Signing ${APP_BUNDLE}..."
codesign --force --deep --sign - --entitlements "App/Jot.entitlements" "${APP_BUNDLE}"

echo "Successfully created ${APP_BUNDLE}"
