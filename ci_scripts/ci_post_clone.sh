#!/usr/bin/env bash
set -euo pipefail

repository_path="${CI_PRIMARY_REPOSITORY_PATH:-$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)}"

cd "$repository_path"
tools_root="${CI_DERIVED_DATA_PATH:-$HOME/Library/Caches}/EncryptedMemoriesTools"
xcodegen="$(bash ./scripts/install-xcodegen.sh "$tools_root/xcodegen")"

bash ./scripts/update-proton-sdk.sh 0.24.0
"$xcodegen" generate --spec project.yml

source scripts/build-paths.sh
encryptedmemories_pin_generated_project_packages "$repository_path"

generated_lock="EncryptedMemories.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
cmp "$generated_lock" XcodeCloud/Package.resolved
cmp EncryptedMemories.xcworkspace/xcshareddata/swiftpm/Package.resolved XcodeCloud/Package.resolved

echo "Generated EncryptedMemories.xcodeproj for Xcode Cloud with pinned packages."
