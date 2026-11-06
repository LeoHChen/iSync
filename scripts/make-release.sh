#!/bin/zsh
# Builds a self-contained iSync.app and packages it as a DMG in dist/.
# Needs Xcode, XcodeGen, the Homebrew libraries in the README, and dmgbuild on PATH.
set -euo pipefail
cd "${0:A:h}/.."

version=$(awk '/MARKETING_VERSION/{gsub(/"/,"",$2); print $2}' project.yml)
products=build-release/Build/Products/Release
app="$products/iSync.app"

xcodegen generate
rm -rf "$app"
xcodebuild -project iSync.xcodeproj -scheme iSync -configuration Release -derivedDataPath build-release build

# The debug symbol table holds local build paths, including the builder's home folder.
strip -S -x "$app/Contents/MacOS/iSync"

# Copy every Homebrew library the app needs, however deep, and point references at the bundle.
frameworks="$app/Contents/Frameworks"
mkdir -p "$frameworks"
typeset -A copied
homebrew_refs() { otool -L "$1" | awk 'NR>1 {print $1}' | grep '^/opt/homebrew/' || true }
bundle_deps() {
    local file=$1 dep name target
    for dep in ${(f)"$(homebrew_refs "$file")"}; do
        name=${dep:t}
        target="$frameworks/$name"
        if [[ -z ${copied[$name]:-} ]]; then
            copied[$name]=1
            cp -L "$dep" "$target"
            chmod u+w "$target"
            install_name_tool -id "@rpath/$name" "$target"
            install_name_tool -add_rpath "@loader_path" "$target"
            bundle_deps "$target"
        fi
        install_name_tool -change "$dep" "@rpath/$name" "$file"
    done
}
bundle_deps "$app/Contents/MacOS/iSync"

# The LGPL notices travel with the libraries.
resources="$app/Contents/Resources"
mkdir -p "$resources/licenses"
cp LICENSE THIRD_PARTY_NOTICES "$resources/"
cp licenses/* "$resources/licenses/"

# Rewriting a library breaks its signature, so sign the libraries, then the app. Ad-hoc
# signing is all that's available without a Developer ID.
for lib in "$frameworks"/*.dylib; do
    codesign --force --sign - --timestamp=none "$lib"
done
codesign --force --sign - --timestamp=none "$app"
codesign --verify --deep --strict "$app"

# Nothing may still point at Homebrew.
leftovers=0
for file in "$app/Contents/MacOS/iSync" "$frameworks"/*.dylib; do
    if otool -L "$file" | grep -q '/opt/homebrew'; then
        echo "Still references Homebrew: $file"
        leftovers=1
    fi
done
# Nothing may reveal where this was built.
for file in "$app/Contents/MacOS/iSync" "$frameworks"/*.dylib; do
    if LC_ALL=C grep -aq "$HOME" "$file" || LC_ALL=C grep -aq '/Users/' "$file"; then
        echo "Contains a local path: $file"
        leftovers=1
    fi
done
[[ $leftovers == 0 ]] || exit 1

mkdir -p dist
dmg="dist/iSync-$version.dmg"
rm -f "$dmg" "$dmg.sha256"
dmgbuild -s scripts/dmg-settings.py -D "app=$PWD/$app" "iSync $version" "$dmg"
(cd dist && shasum -a 256 "${dmg:t}" > "${dmg:t}.sha256")
echo "Built $dmg"
cat "$dmg.sha256"
