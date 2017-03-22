# Detect host platform.
# Set PLATFORM environment variable to override default behavior.
# Supported platform types - 'linux', 'win', 'mac'
# 'msys' is the git bash shell, built using mingw-w64, running under Microsoft
# Windows.
function detect-platform() {
  # set PLATFORM to android on linux host to build android
  case "$OSTYPE" in
  darwin*)      PLATFORM=${PLATFORM:-mac} ;;
  linux*)       PLATFORM=${PLATFORM:-linux} ;;
  win32*|msys*) PLATFORM=${PLATFORM:-win} ;;
  *)            echo "Building on unsupported OS: $OSTYPE"; exit 1; ;;
  esac
}

# This cleans the output directory.
# $1: The output directory.
function clean() {
  local outdir="$1"
  rm -rf $outdir/* $outdir/.gclient*
}

# Makes sure depot tools are present.
# $1: The platform type.
# $2: The depot tools url.
# $3: The depot tools directory.
function check::depot-tools() {
  local platform="$1"
  local depot_tools_url="$2"
  local depot_tools_dir="$3"

  if [ ! -d $depot_tools_dir ]; then
    git clone -q $depot_tools_url $depot_tools_dir
    if [ $platform = 'win' ]; then
      # run gclient.bat to get python
      pushd $depot_tools_dir >/dev/null
      ./gclient.bat
      popd >/dev/null
    fi
  else
    pushd $depot_tools_dir >/dev/null
      git reset --hard -q
    popd >/dev/null
  fi
}

# Makes sure package is installed. Depends on sudo to be installed first.
# $1: The name of the package
# $2: Existence check binary. Defaults to name of the package.
function ensure-package() {
  local name="$1"
  local binary="${2:-$1}"
  if ! which $binary > /dev/null ; then
    sudo apt-get update -qq
    sudo apt-get install -y $name
  fi
}

# Makes sure all webrtcbuilds dependencies are present.
# $1: The platform type.
# $2: The target os.
function check::webrtcbuilds::deps() {
  local platform="$1"
  local taget_os="$2"

  case $platform in
    mac)
      # for GNU version of cp: gcp
      which gcp || brew install coreutils
      ;;
    linux)
      if ! grep -v \# /etc/apt/sources.list | grep -q multiverse ; then
        echo "*** Warning: The Multiverse repository is probably not enabled ***"
        echo "*** which is required for things like msttcorefonts.           ***"
      fi
      if ! which sudo > /dev/null ; then
        apt-get update -qq
        apt-get install -y sudo
      fi
      ensure-package curl
      ensure-package git
      ensure-package python
      ensure-package lbzip2
      ensure-package lsb-release lsb_release
      ;;
    win)
      VISUAL_STUDIO_TOOLS=${VS140COMNTOOLS:-}
      if [ -z VISUAL_STUDIO_TOOLS ]; then
        echo "Building under Microsoft Windows requires Microsoft Visual Studio 2015"
        exit 1
      fi
      ;;
  esac
}

# Makes sure all WebRTC build dependencies are present.
# $1: The platform type.
# $2: The output directory.
# $3: The target os.
function check::webrtc::deps() {
  local platform="$1"
  local outdir="$2"
  local target_os="$3"
  local target_cpu="$4"

  if [ $target_os = 'android' ]; then
    # Automatically accepts ttf-mscorefonts EULA
    echo ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula select true | sudo debconf-set-selections
    sudo bash $outdir/src/build/install-build-deps-android.sh

    # Make a standalone toolchain as well locally
    sudo $outdir/src/third_party/android_tools/ndk/build/tools/make_standalone_toolchain.py \
      --arch $target_cpu \
      --api 18 \
      --stl libc++ \
      --install-dir $outdir/ndk-toolchains/$target_cpu \
      --force
  elif [ $platform = 'linux' ]; then
    # Automatically accepts ttf-mscorefonts EULA
    echo ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula select true | sudo debconf-set-selections
    sudo $outdir/src/build/install-build-deps.sh --no-syms --no-arm --no-chromeos-fonts --no-nacl --no-prompt
  fi
}

# Checks out a specific revision
# $1: The target OS type.
# $2: The output directory.
# $3: Revision represented as a git SHA.
function checkout() {
  local target_os="$1"
  local outdir="$2"
  local revision="$3"

  pushd $outdir >/dev/null
  local prev_target_os=$(cat $outdir/.webrtcbuilds_target_os 2>/dev/null)
  if [[ -n "$prev_target_os" && "$target_os" != "$prev_target_os" ]]; then
    echo The target OS has changed. Refetching sources for the new target OS
    rm -rf src .gclient* .webrtcbuilds_*
  fi

  local prev_revision=$(cat $outdir/.webrtcbuilds_revision 2>/dev/null)
  if [[ -n "$prev_revision" && "$revision" != "$prev_revision" ]]; then
    # Clear if revisions missmatch
    rm -rf src .gclient* .webrtcbuilds_*
  elif [[ -n "$prev_revision" && "$revision" == "$prev_revision" ]]; then
    # Abort if revisions match
    return
  fi

  # Fetch only the first-time, otherwise sync.
  if [ ! -d src ]; then
    case $target_os in
    android)
      yes | fetch --nohooks webrtc_android
      ;;
    ios)
      fetch --nohooks webrtc_ios
      ;;
    *)
      fetch --nohooks webrtc
      ;;
    esac
  fi
  # Cache the target OS and revision
  echo $target_os > $outdir/.webrtcbuilds_target_os
  echo $revision > $outdir/.webrtcbuilds_revision

  set +e
  # Checkout the specific revision after fetch
  gclient sync --force --revision $revision
  if [ ! $? -eq 0 ] && [ -f src/setup_links.py ]; then
    yes | src/setup_links.py --force
    gclient sync
  fi
  set -e

  popd >/dev/null
}

# Patches a checkout for building static standalone libs
# $1: The platform type.
# $2: The output directory.
# $3: If to enable rtti.
# $4: The target os.
function patch() {
  local platform="$1"
  local outdir="$2"
  local enable_rtti="$3"
  local target_os="$4"

  pushd $outdir/src >/dev/null
    # Cherry-pick an important fix in boringssl (might fail on newer revisions than M55)
    # pushd chromium/src/third_party/boringssl/src >/dev/null
    # echo "Cherry-picking BoringSSL fix for SSL_COMP_free_compression_methods()"
    # git cherry-pick --allow-empty --keep-redundant-commits --allow-empty-message 3e9e043229c529f09590b7074ba062e0094e9821
    # popd >/dev/null

    # This removes the examples from being built.
    sed -i.bak 's|"//webrtc/examples",|#"//webrtc/examples",|' BUILD.gn

    # Enable RTTI if required by removing the 'no_rtti' compiler flag
    sed -i.bak 's|#"//build/config/compiler:no_rtti",|"//build/config/compiler:no_rtti",|' build/config/BUILDCONFIG.gn
    if [ $enable_rtti = 1 ]; then
      echo "Enabling RTTI"
      sed -i.bak 's|"//build/config/compiler:no_rtti",|#"//build/config/compiler:no_rtti",|' build/config/BUILDCONFIG.gn
      # The icu package is not included in the iOS toolchain
      if [ "$target_os" != "ios" ]; then
        sed -i.bak 's|"//build/config/compiler:no_rtti",|#"//build/config/compiler:no_rtti",|' third_party/icu/BUILD.gn
        sed -i.bak 's|"//build/config/compiler:no_rtti",|#"//build/config/compiler:no_rtti",|' third_party/icu/BUILD.gn
      fi
    fi

  popd >/dev/null
}

# This function compiles a single library using Microsoft Visual C++ for a
# Microsoft Windows (32/64-bit) target. This function is separate from the
# other compile functions because of differences using the Microsoft tools:
#
# The Microsoft Windows tools use different file extensions than the other tools:
#  '.obj' as the object file extension, instead of '.o'
# '.lib' as the static library file extension, instead of '.a'
# '.dll' as the shared library file extension, instead of '.so'
#
# The Microsoft Windows tools have different names than the other tools:
# 'lib' as the librarian, instead of 'ar'. 'lib' must be found through the path
# variable $VS140COMNTOOLS.
#
# The Microsoft tools that target Microsoft Windows run only under
# Microsoft Windows, so the build and target systems are the same.
#
# $1 the output directory, 'Debug', 'Debug_x64', 'Release', or 'Release_x64'
# $2 additional gn arguments
function compile-win() {
  local outputdir="$1"
  local gn_args="$2"
  # local blacklist="$3|unittest|examples|main.o"

  echo "Generating project files with: $gn_args"
  gn gen $outputdir --args="$gn_args"
  ninja -C $outputdir
}

# This function compiles a single library for linux/bsd/osx/ios/android.
#
# $1 the output directory, 'Debug', or 'Release'
# $2 additional ninja arguments
# $3 additional gn arguments
function compile-ninja() {
  local outputdir="$1"
  local ninja_args="$2"
  local gn_args="$3"

  echo "Generating project files with: $gn_args"
  gn gen $outputdir --args="$gn_args"
  ninja -C $outputdir $ninja_args
}

# This function combines build artifact objects into one library named by
# 'outputlib'.
# $1: The platform.
# $2: The output directory.
# $3: The target os.
# $4: The target cpu.
# $5: Properitary blacklist objects to exclude.
# $6: The library name.
# $7: Strip flag.
function combine() {
  local platform="$1"
  local outputdir="$2"
  local target_os="$3"
  local target_cpu="$4"
  local blacklist_input="$5"

  # Blacklist objects from:
  # video_capture_external and device_info_external so that the video capture
  # module internal implementations gets linked.
  # unittest_main because it has a main function defined.
  local blacklist="unittest|examples|main.o|video_capture_external.o|device_info_external.o|clang_x64"
  if [ "$target_os" != "android" ]; then
    local blacklist="$blacklist|x86_abi_support.o"
  fi
  if [ ! -z "$blacklist_input" ]; then
    local blacklist="$blacklist|$blacklist_input"
  fi
  local libname="$6"
  local strip_flag=${7:-false}

  #   local blacklist="unittest_main.obj|video_capture_external.obj|\
  # device_info_external.obj"
  pushd $outputdir >/dev/null

    rm -f $libname.list

    # Method 1: Collect all .o files from .ninja_deps and some missing intrinsics
    local objlist=$(strings .ninja_deps | grep -o '.*\.o') #.obj
    local extras=$(find ./obj/third_party/libvpx/libvpx_* ./obj/third_party/libjpeg_turbo/simd_asm -name *.o) #.obj

    echo "$objlist" | tr ' ' '\n' | grep -v -E $blacklist > $libname.list
    echo "$extras" | tr ' ' '\n' | grep -v -E $blacklist >> $libname.list

    # Method 2: Collect all .o files from output directory
    # local objlist=$(find . -name '*.o' | grep -v -E $blacklist)
    # echo "$objlist" >>$libname.list

    echo "Combining library: $libname"
    echo "Blacklist objects: $blacklist"

    # Combine all objects into one static library. Prevent blacklisted objects
    # such as ones containing a main function from being combined.
    case $platform in
    win)
      rm -f $libname.lib #libwebrtc_full.lib
      "$VS140COMNTOOLS../../VC/bin/lib" /OUT:$libname.lib @$libname.list
      ;;
    *)

      if [ $strip_flag == "true" ]; then
        local lib_temp_name=${libname}_unstripped.a
      else
        local lib_temp_name=${libname}.a
      fi
      rm -f ${lib_temp_name}
      cat $libname.list | grep -v -E $blacklist | xargs ar -crs ${lib_temp_name}

      if [ $strip_flag == "true" ]; then
        echo "Stripping $libname in $outputdir"
        local pre_size=`du -h ${libname}_unstripped.a`
        echo "Size before strip: $pre_size"
        # strip release builds
        stripBuild ${outputdir} ${libname}_unstripped.a $libname.a $platform $target_os $target_cpu
        local post_size=`du -h ${libname}.a`
        echo "Size after strip: $post_size"
        rm -f ${libname}_unstripped.a
      fi

      ;;
    esac

  popd >/dev/null
}

# This compiles the library.
# $1: The platform type.
# $2: The output directory.
# $3: The specified branch (or 'artifacts' if not specified).
# $4: The target os.
# $5: The target cpu.
# $6: The blacklist.
# $7: The current build type (Debug|Release).
function compile() {
  local platform="$1"
  local outdir="$2"
  local branch="$3"
  local target_os="$4"
  local target_cpu="$5"
  local blacklist="$6"
  local build_type="$7" # Release or Debug
  local enable_bitcode="$8"

  if [ "$target_cpu" == "none" ]; then
    echo "Target CPU not specified, skipping compile..."
    return
  fi

  # A note on default common args:
  # `rtc_include_tests=false`: Disable all unit tests
  # `enable_iterator_debugging=false`: Disable libstdc++ debugging facilities
  # unless all your compiled applications and dependencies define _GLIBCXX_DEBUG=1.
  # If not you will wind up with strange errors in Debug builds such as:
  # undefined reference to `non-virtual thunk to cricket::VideoCapturer::
  # AddOrUpdateSink(rtc::VideoSinkInterface<cricket::VideoFrame>*, rtc::VideoSinkWants const&)'
  local common_args="enable_iterator_debugging=false is_component_build=false"
  if [ "$build_type" == "Release" ]; then
    local common_args="$common_args is_debug=false"
  fi
  local target_args="target_os=\"$target_os\" target_cpu=\"$target_cpu\""

  local ninja_args=""

  pushd $outdir/src >/dev/null
  case $platform in
  win)
    # 32-bit build
    compile-win "out/${build_type}" "$common_args $target_args"

    # 64-bit build
    GYP_DEFINES="target_arch=x64 $GYP_DEFINES"
    compile-win "out/${build_type}_x64" "$common_args $target_args"

    echo Combining WebRTC library
    local strip=false
    if [ "$build_type" == "Release" ]; then
      local strip=true
    fi
    combine $platform "out/${build_type}" "$target_os" "$target_cpu" "$blacklist" libwebrtc_full "${strip}"
    combine $platform "out/${build_type}_x64" "$target_os" "$target_cpu" "$blacklist" libwebrtc_full "${strip}"
    ;;
  *)
    # On Linux, use clang = false and sysroot = false to build using gcc.
    # Comment this out to use clang.
    # NOTE: Disabling this because it was creating corrupted binaries with
    # revision 92ea601e90c3fc12624ce35bb62ceaca8bc07f1b
    # if [ $platform = 'linux' ]; then
    #   target_args+=" is_clang=false use_sysroot=false"
    # fi

    # Set target specific GN arbuments
    case $target_os in
      ios)
        target_args="$target_args rtc_include_tests=false use_xcode_clang=true ios_enable_code_signing=false ios_deployment_target=\"8.0\""
        if [ $enable_bitcode = 1 ]; then
          target_args="$target_args enable_ios_bitcode=true"
        fi
        ninja_args="rtc_sdk_objc"
      ;;
      android)
        if [ "$target_cpu" == "arm" ]; then
          target_args="$target_args arm_version=7"
        fi
        target_args="$target_args use_goma=false"
        ninja_args="webrtc/sdk/android:libwebrtc webrtc/sdk/android:libjingle_peerconnection_so"
      ;;
    esac

    compile-ninja "out/${build_type}_${target_cpu}" "$ninja_args" "$common_args $target_args"

    echo Combining WebRTC library `pwd`
    local strip=false
    if [ "$build_type" == "Release" ]; then
      local strip=true
    fi
    combine $platform "out/${build_type}_${target_cpu}" "$target_os" "$target_cpu" "$blacklist" libwebrtc_full "${strip}"
    ;;
  esac
  popd >/dev/null
}

# This packages a compiled build into a zip file in the output directory.
# $1: The platform type.
# $2: The output directory.
# $3: Label of the package.
# $4: The specified branch/branch-number (or 'artifacts' if 'BRANCH' not specified).
# $5: The project's resource dirctory.
# $6: The target os.
# $7: The target cpu.
# $8: The build type.
# $9: If to ZIP the output.
function package() {
  local platform="$1"
  local outdir="$2"
  local label="$3"
  local branch="$4"
  local resourcedir="$5"
  local target_os="$6"
  local target_cpu="$7"
  local build_type="$8"
  local zip_flag=${9:-false}

  if [ $platform = 'mac' ]; then
    CP='gcp'
  else
    CP='cp'
  fi
  pushd $outdir >/dev/null

  # remove any old artifacts in same folder
  rm -rf $branch/$build_type

  # create directory structure
  mkdir -p $branch/$build_type/include $branch/$build_type/lib >/dev/null

  # find and copy header files
  pushd src >/dev/null
  find webrtc -name '*.h' -exec $CP --parents '{}' $outdir/$branch/$build_type/include ';'
  # Copy boringssl headers
  pushd third_party/boringssl/src/include >/dev/null
  find openssl -name '*.h' -exec $CP --parents '{}' $outdir/$branch/$build_type/include ';'
  popd >/dev/null
  # Copy libyuv headers
  pushd third_party/libyuv/include >/dev/null
  find . -name '*.h' -exec $CP --parents '{}' $outdir/$branch/$build_type/include ';'
  popd >/dev/null

  popd >/dev/null

  # find and copy libraries
  pushd src/out >/dev/null
  if [ "$target_cpu" == "none" ]; then
    zip_file=$label-$build_type.zip
    find ${build_type}_* -maxdepth 5 \( -name "*.so" -o -name "*.dll" -o -name "*webrtc_full*" -o -name "*.jar" ! -iname "*test*" ! -path "*/gen/*" ! -path "*/obj/*" \) \
      -exec $CP --parents '{}' $outdir/$branch/$build_type/lib ';'
  else
    zip_file=$label-$build_type-$target_cpu.zip
    if [ ! -d ${build_type}_${target_cpu} ]; then
      echo "Could not find artifacts folder during package step!"
      exit 1
    fi
    pushd ${build_type}_${target_cpu} >/dev/null
    find . -maxdepth 5 \( -name "*.so "-o -name "*.dll" -o -name "*webrtc_full*" -o -name "*.jar" ! -iname "*test*" ! -path "*/gen/*" ! -path "*/obj/*" \) \
      -exec $CP --parents '{}' $outdir/$branch/$build_type/lib ';'
    popd >/dev/null
  fi
  popd >/dev/null

  # for linux, add pkgconfig files
  if [ $platform = 'linux' ]; then
    if [ "$target_cpu" == "none" ]; then
      configs="Debug Release"
      for cfg in $configs; do
        mkdir -p $branch/$build_type/lib/$cfg/pkgconfig
        CONFIG=$cfg envsubst '$CONFIG' < $resourcedir/pkgconfig/libwebrtc_full.pc.in > \
          $branch/$build_type/lib/$cfg/pkgconfig/libwebrtc_full.pc
      done
    else
      mkdir -p $branch/$build_type/lib/$build_type/pkgconfig
      CONFIG=$cfg envsubst '$CONFIG' < $resourcedir/pkgconfig/libwebrtc_full.pc.in > \
          $branch/$build_type/lib/$build_type/pkgconfig/libwebrtc_full.pc
    fi
  fi

  # write the current revision and branch to an info-file
  touch $label.txt
  echo "Branch: ${branch}, Build type: ${build_type}" > $label.txt

  if [ "$zip_flag" == "true" ]; then
    echo "Zipping the artifacts..."
    # remove old zip first for cleaner builds
    rm -f $zip_file >/dev/null

    pushd $branch/$build_type >/dev/null
    # zip up the package
    if [ $platform = 'win' ]; then
      $DEPOT_TOOLS/win_toolchain/7z/7z.exe a -tzip $zip_file include lib >/dev/null
    else
      zip -r $zip_file include lib >/dev/null
    fi
    popd >/dev/null
    # move the zipped files
    mv $branch/$build_type/$zip_file $zip_file
  fi

  popd >/dev/null
}

function stripBuild() {
  local outputdir=$1
  local library_source=$2
  local output_name=$3
  local platform="$4"
  local target_os="$5"
  local target_cpu="$6"

  # Default to use just local toolchain version of strip
  strip_bin=strip
  case $target_os in
    android)
      strip_bin_prepath=$outdir/ndk-toolchains/$target_cpu/bin
      case $target_cpu in
        arm)
          strip_bin=$strip_bin_prepath/arm-linux-androideabi-strip
          ;;
        arm64)
          strip_bin=$strip_bin_prepath/aarch64-linux-android-strip
          ;;
        x86)
          strip_bin=$strip_bin_prepath/i686-linux-android-strip
          ;;
        x86_64)
          strip_bin=$strip_bin_prepath/x86_64-linux-android-strip
          ;;
      esac
    ;;
  esac

  $strip_bin -S ${library_source} -o ${output_name}
}

# This returns the latest revision from the git repo.
# $1: The git repo URL
function latest-rev() {
  local repo_url="$1"
  git ls-remote $repo_url HEAD | cut -f1
}

# This returns the associated revision number for a given git sha revision
# $1: The git repo URL
# $2: The revision git sha string
function revision-number() {
  local repo_url="$1"
  local revision="$2"
  # This says curl the revision log with text format, base64 decode it using
  # openssl since its more portable than just 'base64', take the last line which
  # contains the commit revision number and output only the matching {#nnn} part
  openssl base64 -d -A <<< $(curl --silent $repo_url/+/$revision?format=TEXT) \
    | tail -1 | egrep -o '{#([0-9]+)}' | tr -d '{}#'
}

# This returns a short revision sha.
# $1: The revision string
function short-rev() {
  local revision="$1"
  echo $revision | cut -c -7
}
