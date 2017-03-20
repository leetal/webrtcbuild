#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source $DIR/util.sh

usage ()
{
cat << EOF

Usage:
   $0 [OPTIONS]

WebRTC build script.

OPTIONS:
   -h             Show this message
   -d             Build debug version of WebRTC.
   -p             Package for release.
   -o OUTDIR      Output directory. Default is 'out'
   -b BRANCH      Latest revision on git branch. Overrides -r. Common branch names are 'branch-heads/nn', where 'nn' is the release number.
   -r REVISION    Git SHA revision. Default is latest revision.
   -t TARGET OS   The target os for cross-compilation. Default is the host OS such as 'linux', 'mac', 'win'. Other values can be 'android', 'ios'.
   -c TARGET CPU  The target cpu for cross-compilation. Default is 'none'. Other values can be 'x64 (x86_64)', 'x86', 'arm64', 'arm'.
   -l BLACKLIST   Blacklisted *.o objects to exclude from the static library.
   -e             Compile WebRTC with RTTI enabled.
   -n             Compile WebRTC with Bitcode enabled (iOS/OS X only).
   -s             Skip building.
   -z             Zip the output.
   -w             Skip WebRTC dependencies check.
EOF
}

while getopts :o:b:r:t:c:l:endpszw OPTION; do
  case $OPTION in
  o) OUTDIR=$OPTARG ;;
  b) BRANCH=$OPTARG ;;
  r) REVISION=$OPTARG ;;
  t) TARGET_OS=$OPTARG ;;
  c) TARGET_CPU=$OPTARG ;;
  l) BLACKLIST=$OPTARG ;;
  e) ENABLE_RTTI=1 ;;
  n) ENABLE_BITCODE=1 ;;
  d) BUILD_TYPE=Debug ;;
  p) PACKAGE=1 ;;
  s) SKIP_BUILD=1 ;;
  z) ZIP=true ;;
  w) SKIP_WEBRTC_DEPS=1 ;;
  ?) usage; exit 1 ;;
  esac
done

SKIP_BUILD=${SKIP_BUILD:-0}
SKIP_WEBRTC_DEPS=${SKIP_WEBRTC_DEPS:-0}
OUTDIR=${OUTDIR:-out}
BRANCH=${BRANCH:-artifacts}
if [ "$BRANCH" != "artifacts" ]; then
  BRANCH_NUM=${BRANCH##*/}
fi
BLACKLIST=${BLACKLIST:-}
ENABLE_RTTI=${ENABLE_RTTI:-0}
ENABLE_BITCODE=${ENABLE_BITCODE:-0}
BUILD_TYPE=${BUILD_TYPE:-Release}
PACKAGE=${PACKAGE:-0}
ZIP=${ZIP:-false}
PROJECT_NAME=webrtcbuild
REPO_URL="https://chromium.googlesource.com/external/webrtc"
DEPOT_TOOLS_URL="https://chromium.googlesource.com/chromium/tools/depot_tools.git"
DEPOT_TOOLS_DIR=$DIR/depot_tools
DEPOT_TOOLS_WIN_TOOLCHAIN=0
PATH=$DEPOT_TOOLS_DIR:$DEPOT_TOOLS_DIR/python276_bin:$PATH

mkdir -p $OUTDIR
OUTDIR=$(cd $OUTDIR && pwd -P)

detect-platform
TARGET_OS=${TARGET_OS:-$PLATFORM}
TARGET_CPU=${TARGET_CPU:-none}

echo "Host OS: $PLATFORM"
echo "Target OS: $TARGET_OS"
echo "Target CPU: $TARGET_CPU"

echo "Checking webrtcbuilds dependencies"
check::webrtcbuilds::deps $PLATFORM $TARGET_OS

echo "Checking depot-tools"
check::depot-tools $PLATFORM $DEPOT_TOOLS_URL $DEPOT_TOOLS_DIR

if [ ! -z $BRANCH ]; then
  if [ $PLATFORM = 'mac' ]; then
    CUT='gcut'
    HEAD='ghead'
  else
    CUT='cut'
    HEAD='head'
  fi
  REVISION=$(git ls-remote $REPO_URL --heads $BRANCH | $HEAD --lines 1 | $CUT --fields 1) || \
    { echo "Cound not get branch revision" && exit 1; }
   echo "Building branch: $BRANCH"
   echo "Associated branch number: $BRANCH_NUM"
else
  REVISION=${REVISION:-$(latest-rev $REPO_URL)} || \
    { echo "Could not get latest revision" && exit 1; }
fi

if [ -z $REVISION ]; then
  echo "Could not get a valid revision based on input" && exit 1
fi

REVISION_NUMBER=$(revision-number $REPO_URL $REVISION) || \
  { echo "Could not get revision number" && exit 1; }

echo "Building revision: $REVISION"
echo "Associated revision number: $REVISION_NUMBER"

echo "Checking out WebRTC revision (this will take awhile): $REVISION"
checkout "$TARGET_OS" $OUTDIR $REVISION

if [ $SKIP_BUILD -eq 0 ]; then
  if [ $SKIP_WEBRTC_DEPS -eq 0 ]; then
    echo "Checking WebRTC dependencies"
    check::webrtc::deps $PLATFORM $OUTDIR "$TARGET_OS" "$TARGET_CPU"
  fi

  echo "Patching WebRTC source"
  patch $PLATFORM $OUTDIR $ENABLE_RTTI "$TARGET_OS"

  echo "Compiling WebRTC of type ${BUILD_TYPE}"
  compile $PLATFORM $OUTDIR "$BRANCH" "$TARGET_OS" "$TARGET_CPU" "$BLACKLIST" "$BUILD_TYPE" $ENABLE_BITCODE
else
  echo "Skipping build..."
fi

if [ $PACKAGE -ne 0 ]; then
  echo "Packaging WebRTC"
  if [ ! -z $BRANCH_NUM ]; then
    # label is <projectname>-<branch-number>-<target-os>-<build_type>
    LABEL=$PROJECT_NAME-$BRANCH_NUM-$TARGET_OS
    package $PLATFORM $OUTDIR $LABEL "$BRANCH_NUM" $DIR/resource $TARGET_OS $TARGET_CPU "$BUILD_TYPE" $ZIP
  else
    # label is <projectname>-<rev-number>-<short-rev-sha>-<target-os>-<build_type>
    LABEL=$PROJECT_NAME-$REVISION_NUMBER-$(short-rev $REVISION)-$TARGET_OS
    package $PLATFORM $OUTDIR $LABEL "$BRANCH" $DIR/resource $TARGET_OS $TARGET_CPU "$BUILD_TYPE" $ZIP
  fi
fi

echo "Build successful"
