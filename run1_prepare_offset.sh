#!/usr/bin/env bash
# Author: Wang Xin
# Date: 2026-09-20
# Affiliation: University of Science and Technology of China (USTC)
# Contact: xinw11@mail.ustc.edu.cn
# Purpose: Prepare an isolated GMTSAR offset-processing directory.

set -euo pipefail

read_prm_value() {
    local prm_file=$1
    local prm_key=$2
    awk -F= -v wanted="$prm_key" '
        {
            key=$1
            gsub(/[[:space:]]/, "", key)
            if (key == wanted) {
                value=$2
                gsub(/[[:space:]]/, "", value)
                print value
                exit
            }
        }
    ' "$prm_file"
}

execute_run=0
if [[ ${1:-} == 1 ]]; then
    execute_run=1
    shift
fi

auto_detect=0
if (( $# == 0 )); then
    auto_detect=1
    script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
    project_dir=$(dirname "$script_dir")

    if [[ ! -d $project_dir/intf_all ]]; then
        printf 'ERROR: cannot auto-detect pairs because this directory is missing:\n' >&2
        printf '  %s\n' "$project_dir/intf_all" >&2
        printf 'Run with explicit arguments: %s PROJECT_DIR PAIR_NAME\n' "$0" >&2
        exit 2
    fi

    mapfile -t detected_pairs < <(
        find "$project_dir/intf_all" -mindepth 1 -maxdepth 1 -type d \
            -printf '%f\n' | sort
    )
    if (( ${#detected_pairs[@]} != 1 )); then
        printf 'ERROR: expected exactly one pair under %s, found %d:\n' \
            "$project_dir/intf_all" "${#detected_pairs[@]}" >&2
        printf '  %s\n' "${detected_pairs[@]}" >&2
        printf 'Run with explicit arguments: %s PROJECT_DIR PAIR_NAME\n' "$0" >&2
        exit 2
    fi
    pair_name=${detected_pairs[0]}
elif (( $# == 2 )); then
    project_dir=${1%/}
    pair_name=$2
else
    printf 'Usage:\n' >&2
    printf '  %s                         # preview, auto-detect project/pair\n' "$0" >&2
    printf '  %s 1                       # execute previewed auto-detected plan\n' "$0" >&2
    printf '  %s PROJECT_DIR PAIR_NAME   # preview explicit plan\n' "$0" >&2
    printf '  %s 1 PROJECT_DIR PAIR_NAME # execute explicit plan\n' "$0" >&2
    exit 2
fi

offset_dir=$project_dir/offset
intf_dir=$offset_dir/intf
pair_dir=$intf_dir/$pair_name

if [[ ! $pair_name =~ ^[A-Za-z0-9._-]+$ ]]; then
    printf 'ERROR: unsafe pair name: %s\n' "$pair_name" >&2
    exit 2
fi

for required_dir in "$project_dir/SLC" "$project_dir/topo"; do
    if [[ ! -d $required_dir ]]; then
        printf 'ERROR: directory not found: %s\n' "$required_dir" >&2
        exit 3
    fi
done

for required_file in "$project_dir/topo/trans.dat" "$project_dir/topo/dem.grd"; do
    if [[ ! -f $required_file ]]; then
        printf 'ERROR: file not found: %s\n' "$required_file" >&2
        exit 3
    fi
done

mapfile -t source_prms < <(
    find "$project_dir/SLC" -maxdepth 1 -type f -name '*.PRM' -print | sort
)
if (( ${#source_prms[@]} != 2 )); then
    printf 'ERROR: expected exactly two PRM files under %s, found %d:\n' \
        "$project_dir/SLC" "${#source_prms[@]}" >&2
    printf '  %s\n' "${source_prms[@]}" >&2
    exit 3
fi

prm_slc_names=()
prm_rng_sizes=()
prm_azi_sizes=()
for prm_path in "${source_prms[@]}"; do
    slc_reference=$(read_prm_value "$prm_path" SLC_file)
    rng_size=$(read_prm_value "$prm_path" num_rng_bins)
    azi_size=$(read_prm_value "$prm_path" num_valid_az)
    if [[ -z $slc_reference || ! $rng_size =~ ^[1-9][0-9]*$ ||
          ! $azi_size =~ ^[1-9][0-9]*$ ]]; then
        printf 'ERROR: missing/invalid SLC_file, num_rng_bins, or num_valid_az in:\n' >&2
        printf '  %s\n' "$prm_path" >&2
        exit 3
    fi
    slc_name=$(basename "$slc_reference")
    slc_path=$project_dir/SLC/$slc_name
    if [[ ! -f $slc_path ]]; then
        printf 'ERROR: PRM references an SLC that is missing from PROJECT/SLC:\n' >&2
        printf '  PRM: %s\n' "$prm_path" >&2
        printf '  SLC_file: %s\n' "$slc_reference" >&2
        printf '  Expected: %s\n' "$slc_path" >&2
        exit 3
    fi
    prm_slc_names+=("$slc_name")
    prm_rng_sizes+=("$rng_size")
    prm_azi_sizes+=("$azi_size")
done
if [[ ${prm_rng_sizes[0]} != "${prm_rng_sizes[1]}" ||
      ${prm_azi_sizes[0]} != "${prm_azi_sizes[1]}" ]]; then
    printf 'ERROR: the two PRM image dimensions do not match:\n' >&2
    printf '  %s: %s x %s\n' "$(basename "${source_prms[0]}")" \
        "${prm_rng_sizes[0]}" "${prm_azi_sizes[0]}" >&2
    printf '  %s: %s x %s\n' "$(basename "${source_prms[1]}")" \
        "${prm_rng_sizes[1]}" "${prm_azi_sizes[1]}" >&2
    exit 3
fi
if [[ ${prm_slc_names[0]} == "${prm_slc_names[1]}" ]]; then
    printf 'ERROR: both PRMs reference the same SLC file: %s\n' \
        "${prm_slc_names[0]}" >&2
    exit 3
fi

printf '\n===== Run1 preview / 执行预览 =====\n'
printf 'Project:           %s\n' "$project_dir"
printf 'Pair:              %s\n' "$pair_name"
if [[ -d $offset_dir ]]; then
    printf 'Offset directory:  %s (exists)\n' "$offset_dir"
else
    printf 'Offset directory:  %s (will be created)\n' "$offset_dir"
fi
printf 'Create directory:  %s\n' "$pair_dir"
printf 'Create link:       %s -> ../SLC\n' "$offset_dir/SLC"
printf 'Create link:       %s -> ../topo\n' "$offset_dir/topo"
if [[ -d $project_dir/intf_all/$pair_name ]]; then
    printf 'DInSAR pair:       %s\n' "$project_dir/intf_all/$pair_name"
else
    printf 'DInSAR pair:       not found (offset preparation can still continue)\n'
fi

printf '\n===== PRM/SLC input check / 输入检查 =====\n'
printf '  %-28s %-28s %-12s %-12s %s\n' \
    'PRM' 'Referenced SLC' 'range px' 'azimuth px' 'status'
for index in "${!source_prms[@]}"; do
    printf '  %-28s %-28s %-12s %-12s %s\n' \
        "$(basename "${source_prms[$index]}")" \
        "${prm_slc_names[$index]}" \
        "${prm_rng_sizes[$index]}" \
        "${prm_azi_sizes[$index]}" \
        'PRM+SLC OK'
done
printf 'SLC directory:     %s\n' "$project_dir/SLC"
printf 'PRM count:         %d (expected 2)\n' "${#source_prms[@]}"
printf 'Referenced SLCs:   both present\n'
printf 'Referenced SLC file sizes:\n'
ls -lh "$project_dir/SLC/${prm_slc_names[0]}" \
       "$project_dir/SLC/${prm_slc_names[1]}"

printf '\nRequired topo files:\n'
ls -lh "$project_dir/topo/trans.dat" "$project_dir/topo/dem.grd"

if (( execute_run == 0 )); then
    printf '\nPreview only. No directories or links were changed.\n'
    if (( auto_detect == 1 )); then
        printf 'To execute Run1, run:\n  %s 1\n' "$0"
    else
        printf 'To execute Run1, run:\n  %s 1 %q %q\n' \
            "$0" "$project_dir" "$pair_name"
    fi
    exit 0
fi

printf '\nExecution authorized by argument 1. Applying Run1 now...\n'

mkdir -p "$pair_dir"

ensure_link() {
    local target=$1
    local link_path=$2
    if [[ -L $link_path ]]; then
        ln -sfn "$target" "$link_path"
    elif [[ -e $link_path ]]; then
        printf 'ERROR: expected a symlink but found an existing path: %s\n' \
            "$link_path" >&2
        exit 4
    else
        ln -s "$target" "$link_path"
    fi
}

ensure_link ../SLC "$offset_dir/SLC"
ensure_link ../topo "$offset_dir/topo"

mapfile -t pair_dirs < <(find "$intf_dir" -mindepth 1 -maxdepth 1 -type d -print)
if (( ${#pair_dirs[@]} != 1 )) || [[ ${pair_dirs[0]} != "$pair_dir" ]]; then
    printf 'ERROR: the stock make_a_offset.csh requires exactly one directory under:\n'
    printf '  %s\n' "$intf_dir"
    printf 'Current directories:\n'
    printf '  %s\n' "${pair_dirs[@]}"
    exit 5
fi

printf '\nRun1 complete.\n'
printf 'Project: %s\n' "$project_dir"
printf 'Offset root: %s\n' "$offset_dir"
printf 'Pair directory: %s\n' "$pair_dir"
printf 'SLC link: %s -> %s\n' "$offset_dir/SLC" \
    "$(readlink -f "$offset_dir/SLC")"
printf 'Topo link: %s -> %s\n\n' "$offset_dir/topo" \
    "$(readlink -f "$offset_dir/topo")"

printf 'Available PRM files:\n'
printf '  %s\n' "$(basename "${source_prms[0]}")" "$(basename "${source_prms[1]}")"

printf '\nRequired topo files:\n'
ls -lh "$project_dir/topo/trans.dat" "$project_dir/topo/dem.grd"

printf '\n===== Next step / 下一步：Run2 =====\n'
printf 'Preview PRM values and the recommended sampling grid:\n'
printf '  ./run2_recommend_grid.sh\n'
printf 'After checking the preview, save the parameters for Run3:\n'
printf '  ./run2_recommend_grid.sh 1\n'
