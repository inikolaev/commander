#!/usr/bin/env bash
# Build the benchmark from current project sources without SwiftPM resolution.
# External dependencies must already have release modules and object files.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: scripts/build-search-benchmark-offline.sh --cache-build /path/to/.build [--modulemap /path/to/CLibArchive/module.modulemap] [--output-dir /path]

Rebuilds TextSearchCore, FileManagerCore, EditorCore, and SearchBenchmark with
release optimization. Reuses only cached external dependency objects/modules.
EOF
  exit 2
}

cache_build=''
modulemap=''
output_dir=''
while (($#)); do
  case "$1" in
    --cache-build|--modulemap|--output-dir)
      (($# >= 2)) || usage
      case "$1" in
        --cache-build) cache_build=$2 ;;
        --modulemap) modulemap=$2 ;;
        --output-dir) output_dir=$2 ;;
      esac
      shift 2 ;;
    *) usage ;;
  esac
done
[[ -n "$cache_build" ]] || usage
repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cache_build=$(cd "$cache_build" && pwd)
release_dir="$cache_build/release"
[[ -d "$release_dir/Modules" ]] || { echo "Missing cached release modules: $release_dir" >&2; exit 1; }

if [[ -z "$modulemap" ]]; then
  modulemap="$cache_build/artifacts/libarchive-bin/CLibArchive/CLibArchive.xcframework/macos-arm64_x86_64/Headers/module.modulemap"
fi
[[ -f "$modulemap" ]] || { echo "Missing CLibArchive module map; pass --modulemap PATH" >&2; exit 1; }

if [[ -z "$output_dir" ]]; then output_dir="$repo_dir/.build/search-benchmark-offline"; fi
mkdir -p "$output_dir/module-cache"
output_dir=$(cd "$output_dir" && pwd)
export CLANG_MODULE_CACHE_PATH="$output_dir/module-cache"

common=(-O -whole-module-optimization -swift-version 6 -emit-module -emit-object)
swiftc "${common[@]}" -module-name TextSearchCore \
  -emit-module-path "$output_dir/TextSearchCore.swiftmodule" -o "$output_dir/TextSearchCore.o" \
  "$repo_dir"/Sources/TextSearchCore/*.swift

swiftc "${common[@]}" -module-name FileManagerCore \
  -I "$output_dir" -I "$release_dir/Modules" -I "$release_dir/CFileCopy.build" \
  -Xcc "-fmodule-map-file=$modulemap" \
  -emit-module-path "$output_dir/FileManagerCore.swiftmodule" -o "$output_dir/FileManagerCore.o" \
  "$repo_dir"/Sources/FileManagerCore/*.swift

swiftc "${common[@]}" -module-name EditorCore \
  -I "$output_dir" -I "$release_dir/Modules" \
  -emit-module-path "$output_dir/EditorCore.swiftmodule" -o "$output_dir/EditorCore.o" \
  "$repo_dir"/Sources/EditorCore/*.swift

objects=(
  "$release_dir"/ArchiveCore.build/*.o
  "$release_dir"/TextBuffer.build/*.o
  "$release_dir"/TextRope.build/*.o
  "$release_dir"/CFileCopy.build/*.o
)
for object in "${objects[@]}" "$release_dir/libCLibArchive.a"; do
  [[ -f "$object" ]] || { echo "Missing cached dependency object: $object" >&2; exit 1; }
done

swiftc -O -swift-version 6 -parse-as-library \
  -I "$output_dir" -I "$release_dir/Modules" -I "$release_dir/CFileCopy.build" \
  -Xcc "-fmodule-map-file=$modulemap" \
  "$repo_dir/Sources/SearchBenchmark/SearchBenchmark.swift" \
  "$output_dir/TextSearchCore.o" "$output_dir/FileManagerCore.o" "$output_dir/EditorCore.o" \
  "${objects[@]}" "$release_dir/libCLibArchive.a" \
  -o "$output_dir/SearchBenchmark"

{
  echo "source-revision $(git -C "$repo_dir" rev-parse HEAD)"
  echo "cache-build $cache_build"
  echo "modulemap $modulemap"
  swiftc --version
  shasum -a 256 "$repo_dir"/Sources/TextSearchCore/*.swift \
    "$repo_dir"/Sources/FileManagerCore/*.swift \
    "$repo_dir"/Sources/EditorCore/*.swift \
    "$repo_dir/Sources/SearchBenchmark/SearchBenchmark.swift" \
    "$output_dir/SearchBenchmark"
} > "$output_dir/provenance.txt"
echo "$output_dir/SearchBenchmark"
