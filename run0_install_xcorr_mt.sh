#!/usr/bin/env bash
# Author: Wang Xin
# Date: 2026-09-20
# Affiliation: University of Science and Technology of China (USTC)
# Contact: xinw11@mail.ustc.edu.cn
# Purpose: Install the CPU-parallel xcorr_mt frontend for GMTSAR.

set -Eeuo pipefail

execute_run=0
replace_existing=0
force_system=0
env_name=${XCORR_MT_CONDA_ENV:-}
source_argument=''
install_dir=${XCORR_MT_INSTALL_DIR:-$HOME/bin}
github_url=https://github.com/Jazz-0626/xcorr_mt.git

if [[ ${1:-} == 1 ]]; then
    execute_run=1
    shift
fi
while (( $# > 0 )); do
    case $1 in
        --env)
            (( $# >= 2 )) || { printf 'ERROR: --env requires a Conda environment name.\n' >&2; exit 2; }
            env_name=$2
            shift 2
            ;;
        --source-dir)
            (( $# >= 2 )) || { printf 'ERROR: --source-dir requires a directory.\n' >&2; exit 2; }
            source_argument=$2
            shift 2
            ;;
        --system)
            force_system=1
            shift
            ;;
        --replace)
            replace_existing=1
            shift
            ;;
        *)
            printf 'ERROR: unknown argument: %s\n' "$1" >&2
            printf 'Usage: %s [1] [--env NAME | --system] [--source-dir DIR] [--replace]\n' "$0" >&2
            exit 2
            ;;
    esac
done
if (( replace_existing == 1 && execute_run == 0 )); then
    printf 'ERROR: --replace is valid only together with execution argument 1.\n' >&2
    exit 2
fi
if (( force_system == 1 )) && [[ -n $env_name ]]; then
    printf 'ERROR: --system and --env/XCORR_MT_CONDA_ENV cannot be used together.\n' >&2
    exit 2
fi

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
local_source=$script_dir/xcorr_mt-source
home_source=$HOME/src/xcorr_mt
source_dir=''
source_mode=''

if [[ -n $source_argument ]]; then
    source_dir=$(cd -- "$source_argument" 2>/dev/null && pwd -P || true)
    source_mode='explicit --source-dir'
elif [[ -f $local_source/xcorr_mt.c ]]; then
    source_dir=$local_source
    source_mode='manually supplied beside Run0'
elif [[ -f $home_source/xcorr_mt.c ]]; then
    source_dir=$home_source
    source_mode='existing source under HOME/src'
else
    source_dir=$home_source
    source_mode='GitHub clone required'
fi

if [[ -n $source_argument && ( -z $source_dir || ! -f $source_dir/xcorr_mt.c ) ]]; then
    printf 'ERROR: --source-dir must contain xcorr_mt.c: %s\n' "$source_argument" >&2
    exit 3
fi

runtime_mode='system PATH'
runtime_prefix=''
if (( force_system == 0 )) && command -v conda >/dev/null 2>&1; then
    if [[ -z $env_name && -n ${CONDA_DEFAULT_ENV:-} ]]; then
        env_name=$CONDA_DEFAULT_ENV
    fi
    [[ -n $env_name ]] || env_name=base
    if [[ ! $env_name =~ ^[A-Za-z0-9._-]+$ ]]; then
        printf 'ERROR: unsafe Conda environment name: %s\n' "$env_name" >&2
        exit 2
    fi
    conda_base=$(conda info --base)
    # shellcheck source=/dev/null
    source "$conda_base/etc/profile.d/conda.sh"
    if ! conda activate "$env_name" >/dev/null 2>&1; then
        printf 'ERROR: Conda environment not found or cannot be activated: %s\n' "$env_name" >&2
        printf 'Use --system to inspect the current PATH without Conda.\n' >&2
        conda env list >&2 || true
        exit 3
    fi
    runtime_mode='Conda environment'
    runtime_prefix=$CONDA_PREFIX
elif [[ -n $env_name ]]; then
    printf 'ERROR: --env was supplied but conda is not installed or not in PATH.\n' >&2
    printf 'Remove --env to use the current system PATH.\n' >&2
    exit 3
fi

installed_xcorr=$install_dir/xcorr_mt
installed_wrapper=$install_dir/make_a_offset_mt.csh
stock_xcorr=$(command -v xcorr 2>/dev/null || true)
stock_driver=$(command -v make_a_offset.csh 2>/dev/null || true)
gcc_path=$(command -v gcc 2>/dev/null || true)
gmt_config_path=$(command -v gmt-config 2>/dev/null || true)

search_roots=()
[[ -n $runtime_prefix && -d $runtime_prefix ]] && search_roots+=("$runtime_prefix")
if [[ -n ${GMTSAR_DEV_ROOT:-} && -d ${GMTSAR_DEV_ROOT:-} ]]; then
    search_roots+=("$GMTSAR_DEV_ROOT")
fi
if [[ -n $stock_xcorr ]]; then
    stock_prefix=$(cd -- "$(dirname "$stock_xcorr")/.." 2>/dev/null && pwd -P || true)
    [[ -n $stock_prefix && -d $stock_prefix ]] && search_roots+=("$stock_prefix")
fi
if [[ -n $stock_driver ]]; then
    driver_prefix=$(cd -- "$(dirname "$stock_driver")/.." 2>/dev/null && pwd -P || true)
    [[ -n $driver_prefix && -d $driver_prefix ]] && search_roots+=("$driver_prefix")
fi
if [[ -n $gmt_config_path ]]; then
    gmt_prefix=$(gmt-config --prefix 2>/dev/null || true)
    [[ -n $gmt_prefix && -d $gmt_prefix ]] && search_roots+=("$gmt_prefix")
fi
for common_root in /usr/local/GMTSAR /opt/GMTSAR /usr/local /usr; do
    [[ -d $common_root ]] && search_roots+=("$common_root")
done

gmtsar_header=''
gmtsar_library=''
if command -v find >/dev/null 2>&1; then
    for search_root in "${search_roots[@]}"; do
        if [[ -z $gmtsar_header ]]; then
            gmtsar_header=$(find "$search_root" -type f -name gmtsar.h -print -quit 2>/dev/null || true)
        fi
        if [[ -z $gmtsar_library ]]; then
            gmtsar_library=$(find "$search_root" -type f -name libgmtsar.a -print -quit 2>/dev/null || true)
        fi
        [[ -n $gmtsar_header && -n $gmtsar_library ]] && break
    done
fi

printf '\n===== Run0 preview / CPU并行互相关安装预览 =====\n'
printf 'Runtime mode:        %s\n' "$runtime_mode"
if [[ $runtime_mode == 'Conda environment' ]]; then
    printf 'Conda environment:   %s (current environment or --env selection)\n' "$env_name"
    printf 'CONDA_PREFIX:        %s\n' "$runtime_prefix"
else
    printf 'Conda environment:   not used (conda unavailable or --system selected)\n'
fi
printf 'Stock xcorr:         %s\n' "${stock_xcorr:-NOT FOUND}"
printf 'Stock driver:        %s\n' "${stock_driver:-NOT FOUND}"
printf 'gmt-config:          %s\n' "${gmt_config_path:-NOT FOUND}"
printf 'gcc:                 %s\n' "${gcc_path:-NOT FOUND}"
printf 'gmtsar.h:            %s\n' "${gmtsar_header:-NOT FOUND}"
printf 'libgmtsar.a:         %s\n' "${gmtsar_library:-NOT FOUND}"
printf 'Source mode:         %s\n' "$source_mode"
printf 'Source directory:    %s\n' "$source_dir"
printf 'GitHub repository:   %s\n' "$github_url"
printf 'Install directory:   %s\n' "$install_dir"
printf 'Parallel executable: %s\n' "$installed_xcorr"
printf 'Parallel driver:     %s\n' "$installed_wrapper"
printf 'Existing xcorr_mt:   %s\n' "$([[ -x $installed_xcorr ]] && printf YES || printf NO)"
printf 'Existing wrapper:    %s\n' "$([[ -x $installed_wrapper ]] && printf YES || printf NO)"
if [[ $runtime_mode == 'Conda environment' && $env_name == base ]]; then
    printf 'Environment note:    using base; a dedicated GMTSAR environment is recommended but not required\n'
fi

if [[ $source_mode == 'GitHub clone required' ]]; then
    printf '\nSource acquisition plan:\n'
    printf '  Run0 will first try: git clone %s %s\n' "$github_url" "$source_dir"
    printf '  If GitHub is unavailable, manually place xcorr_mt.c at:\n'
    printf '    %s/xcorr_mt.c\n' "$local_source"
fi

printf '\nRun0 actions when executed:\n'
printf '  1. Use the selected Conda environment, or the current system PATH.\n'
printf '  2. Use local source, or clone xcorr_mt from GitHub.\n'
printf '  3. Find gmtsar.h and libgmtsar.a under the active installation prefixes.\n'
printf '  4. Compile xcorr_mt and install it without replacing stock xcorr.\n'
printf '  5. Install make_a_offset_mt.csh and test both entry points.\n'

if (( execute_run == 0 )); then
    printf '\nPreview only. Nothing was installed.\n'
    if [[ -x $installed_xcorr && -x $installed_wrapper ]]; then
        printf 'Run0 is already installed. Use the following only to rebuild intentionally:\n'
        printf '  ./run0_install_xcorr_mt.sh 1 --replace\n'
    else
        printf 'To install, run:\n'
        printf '  ./run0_install_xcorr_mt.sh 1\n'
    fi
    printf '\nOffline/manual-source method:\n'
    printf '  1. Download the xcorr_mt repository ZIP on a computer with GitHub access.\n'
    printf '  2. Extract it and upload/rename the source directory to:\n'
    printf '       %s\n' "$local_source"
    printf '  3. Confirm this file exists: %s/xcorr_mt.c\n' "$local_source"
    printf '  4. Rerun: ./run0_install_xcorr_mt.sh 1\n'
    exit 0
fi

if [[ -x $installed_xcorr && -x $installed_wrapper && $replace_existing -eq 0 ]]; then
    printf '\nRun0 is already installed; existing files were not changed.\n'
    printf 'Use ./run0_install_xcorr_mt.sh 1 --replace to rebuild intentionally.\n'
    printf 'Next step: ./run1_prepare_offset.sh\n'
    exit 0
fi

for required_command in gcc gmt-config find install csh sed; do
    if ! command -v "$required_command" >/dev/null 2>&1; then
        printf 'ERROR: required command not found in the selected runtime: %s\n' \
            "$required_command" >&2
        exit 4
    fi
done
if [[ -z $stock_xcorr || -z $stock_driver ]]; then
    printf 'ERROR: stock GMTSAR xcorr or make_a_offset.csh is unavailable in PATH.\n' >&2
    exit 4
fi
if [[ -z $gmtsar_header || -z $gmtsar_library ]]; then
    printf 'ERROR: GMTSAR development files were not found.\n' >&2
    printf 'Required: gmtsar.h and libgmtsar.a\n' >&2
    printf 'If they are in a nonstandard source/build tree, rerun with:\n' >&2
    printf '  GMTSAR_DEV_ROOT=/path/to/GMTSAR ./run0_install_xcorr_mt.sh 1\n' >&2
    exit 4
fi

if [[ ! -f $source_dir/xcorr_mt.c ]]; then
    if ! command -v git >/dev/null 2>&1; then
        printf 'ERROR: git is unavailable and no manual xcorr_mt source was found.\n' >&2
        exit 10
    fi
    if [[ -e $source_dir ]]; then
        printf 'ERROR: source destination exists but lacks xcorr_mt.c: %s\n' "$source_dir" >&2
        printf 'Move that incomplete directory aside, or use --source-dir with a valid source.\n' >&2
        exit 10
    fi
    mkdir -p "$(dirname "$source_dir")"
    printf '\nDownloading xcorr_mt from GitHub...\n'
    if ! GIT_TERMINAL_PROMPT=0 git clone "$github_url" "$source_dir"; then
        printf '\nERROR: GitHub download failed. Nothing was compiled.\n' >&2
        printf 'Manual fallback / 手动下载方法:\n' >&2
        printf '  Open https://github.com/Jazz-0626/xcorr_mt and choose Code -> Download ZIP.\n' >&2
        printf '  Extract the ZIP and upload the directory so this file exists:\n' >&2
        printf '    %s/xcorr_mt.c\n' "$local_source" >&2
        printf '  Then run again:\n' >&2
        printf '    ./run0_install_xcorr_mt.sh 1\n' >&2
        exit 10
    fi
fi

printf '\ngmtsar.h:    %s\n' "${gmtsar_header:-NOT FOUND}"
printf 'libgmtsar.a: %s\n' "${gmtsar_library:-NOT FOUND}"

gmtsar_include=$(dirname "$gmtsar_header")
gmtsar_library_dir=$(dirname "$gmtsar_library")
build_dir=$source_dir/build-run0
mkdir -p "$build_dir"
printf '\nCompiling in: %s\n' "$build_dir"
printf 'GMT CFLAGS: %s\n' "$(gmt-config --cflags)"
printf 'GMT LIBS:   %s\n' "$(gmt-config --libs)"

include_arguments=(-I"$gmtsar_include")
if [[ -n $runtime_prefix && -d $runtime_prefix/include ]]; then
    include_arguments+=(-I"$runtime_prefix/include")
fi

# gmt-config deliberately supplies several compiler arguments.
# shellcheck disable=SC2046
gcc -O2 -Wall -fPIC -fno-strict-aliasing -std=c99 \
    "${include_arguments[@]}" \
    $(gmt-config --cflags) \
    -c "$source_dir/xcorr_mt.c" -o "$build_dir/xcorr_mt.o"

# shellcheck disable=SC2046
gcc -Wl,--allow-multiple-definition -Wl,-rpath,"$gmtsar_library_dir" \
    "$build_dir/xcorr_mt.o" "$gmtsar_library" \
    $(gmt-config --libs) -L"$gmtsar_library_dir" \
    -llapack -lblas -ltiff -lm -o "$build_dir/xcorr_mt"

mkdir -p "$install_dir"
install -m 755 "$build_dir/xcorr_mt" "$installed_xcorr"

# Install a self-contained frontend that adapts the stock GMTSAR script at
# runtime and redirects only its xcorr command to xcorr_mt.
wrapper_tmp=$(mktemp /tmp/make_a_offset_mt.XXXXXX)
trap 'rm -f -- "$wrapper_tmp"' EXIT
cat > "$wrapper_tmp" <<'CSH_WRAPPER'
#!/bin/csh -f
if ($#argv != 7) then
    echo "Usage: make_a_offset_mt.csh Master.PRM Aligned.PRM nx ny xsearch ysearch do_xcorr"
    exit 1
endif
set xcorr_parallel = `which xcorr_mt`
if ($status != 0 || "$xcorr_parallel" == "") then
    echo "ERROR: xcorr_mt was not found in PATH."
    exit 2
endif
if ($?GMTSAR_MAKE_A_OFFSET) then
    set stock_script = "$GMTSAR_MAKE_A_OFFSET"
else
    set stock_script = `which make_a_offset.csh`
endif
if ($status != 0 || "$stock_script" == "" || ! -f "$stock_script") then
    echo "ERROR: stock make_a_offset.csh was not found."
    exit 3
endif
if ($?XCORR_NPROC) then
    if ("$XCORR_NPROC" !~ [1-9]*) then
        echo "ERROR: XCORR_NPROC must be a positive integer."
        exit 4
    endif
    setenv OMP_NUM_THREADS 1
    echo "make_a_offset_mt.csh: xcorr_mt workers = $XCORR_NPROC"
else
    echo "make_a_offset_mt.csh: xcorr_mt will choose its worker count automatically."
endif
echo "make_a_offset_mt.csh: using $xcorr_parallel"
echo "make_a_offset_mt.csh: adapting $stock_script"
set adapted_script = `mktemp /tmp/make_a_offset_mt_runtime.XXXXXX`
if ($status != 0 || "$adapted_script" == "") then
    echo "ERROR: could not create a temporary adapted script."
    exit 5
endif
if ($?XCORR_NPROC) then
    sed "s@) xcorr \(.*\)@) $xcorr_parallel \1 -nproc $XCORR_NPROC@" "$stock_script" >! "$adapted_script"
else
    sed "s@) xcorr @) $xcorr_parallel @" "$stock_script" >! "$adapted_script"
endif
source "$adapted_script"
set run_status = $status
rm -f "$adapted_script"
exit $run_status
CSH_WRAPPER
install -m 755 "$wrapper_tmp" "$installed_wrapper"

export PATH="$install_dir:$PATH"
hash -r
printf '\n===== Run0 complete / 安装完成 =====\n'
printf 'Stock xcorr:         %s\n' "$(command -v xcorr)"
printf 'Parallel xcorr:      %s\n' "$(command -v xcorr_mt)"
printf 'Stock driver:        %s\n' "$(command -v make_a_offset.csh)"
printf 'Parallel driver:     %s\n' "$(command -v make_a_offset_mt.csh)"
ls -lh "$installed_xcorr" "$installed_wrapper"

printf '\nEntry-point checks (Usage output and nonzero status are expected):\n'
set +e
"$installed_xcorr" 2>&1 | sed -n '1,8p'
xcorr_test=${PIPESTATUS[0]}
"$installed_wrapper" 2>&1 | sed -n '1,3p'
wrapper_test=${PIPESTATUS[0]}
set -e
printf 'xcorr_mt no-argument status: %s\n' "$xcorr_test"
printf 'wrapper no-argument status:  %s\n' "$wrapper_test"
printf '\nRun3 automatically adds %s to PATH.\n' "$install_dir"
printf 'Next step / 下一步:\n'
printf '  ./run1_prepare_offset.sh\n'
printf '  ./run1_prepare_offset.sh 1\n'
