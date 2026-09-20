#!/usr/bin/env bash
# Author: Wang Xin
# Date: 2026-09-20
# Affiliation: University of Science and Technology of China (USTC)
# Contact: xinw11@mail.ustc.edu.cn
# Purpose: Read PRM metadata and recommend/save the offset sampling grid.
# Citation: Xin Wang et al. (2026), Earth Planet. Sci. Lett. 686, 120070.
# DOI: https://doi.org/10.1016/j.epsl.2026.120070

set -euo pipefail

read_prm_value() {
    local prm_file=$1
    local prm_key=$2
    local value
    value=$(awk -F= -v wanted="$prm_key" '
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
    ' "$prm_file")
    printf '%s\n' "${value:-N/A}"
}

execute_run=0
if [[ ${1:-} == 1 ]]; then
    execute_run=1
    shift
fi
if (( $# == 0 )); then
    xsearch=${OFFSET_XSEARCH:-16}
    ysearch=${OFFSET_YSEARCH:-16}
elif (( $# == 2 )); then
    xsearch=$1
    ysearch=$2
else
    printf 'Usage:\n' >&2
    printf '  %s [XSEARCH YSEARCH]       # preview\n' "$0" >&2
    printf '  %s 1 [XSEARCH YSEARCH]     # save parameters for Run3\n' "$0" >&2
    printf 'Allowed search values: 16 32 64 128 256; default: 16 16\n' >&2
    exit 2
fi

valid_search_value() {
    case $1 in
        16|32|64|128|256) return 0 ;;
        *) return 1 ;;
    esac
}
if ! valid_search_value "$xsearch" || ! valid_search_value "$ysearch"; then
    printf 'ERROR: XSEARCH and YSEARCH must each be one of:\n' >&2
    printf '  16 32 64 128 256\n' >&2
    exit 2
fi

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
offset_dir=$script_dir
project_dir=$(dirname "$offset_dir")
intf_dir=$offset_dir/intf
config_file=$offset_dir/offset_run.conf

if [[ ! -d $intf_dir ]]; then
    printf 'ERROR: Run1 output directory not found: %s\n' "$intf_dir" >&2
    printf 'Run ./run1_prepare_offset.sh 1 first.\n' >&2
    exit 3
fi

mapfile -t detected_pairs < <(
    find "$intf_dir" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort
)
if (( ${#detected_pairs[@]} != 1 )); then
    printf 'ERROR: expected exactly one pair under %s, found %d:\n' \
        "$intf_dir" "${#detected_pairs[@]}" >&2
    printf '  %s\n' "${detected_pairs[@]}" >&2
    exit 3
fi
pair_name=${detected_pairs[0]}

mapfile -t slc_prms < <(
    find "$project_dir/SLC" -maxdepth 1 -type f -name '*.PRM' \
        -printf '%f\n' | sort
)
if (( ${#slc_prms[@]} != 2 )); then
    printf 'ERROR: expected exactly two .PRM files under %s, found %d:\n' \
        "$project_dir/SLC" "${#slc_prms[@]}" >&2
    printf '  %s\n' "${slc_prms[@]}" >&2
    exit 3
fi

master_prm=${slc_prms[0]}
aligned_prm=${slc_prms[1]}
master_path=$project_dir/SLC/$master_prm
aligned_path=$project_dir/SLC/$aligned_prm

master_num_rng=$(read_prm_value "$master_path" num_rng_bins)
master_num_azi=$(read_prm_value "$master_path" num_valid_az)
aligned_num_rng=$(read_prm_value "$aligned_path" num_rng_bins)
aligned_num_azi=$(read_prm_value "$aligned_path" num_valid_az)

for dimension in \
    "$master_num_rng" "$master_num_azi" \
    "$aligned_num_rng" "$aligned_num_azi"; do
    if [[ ! $dimension =~ ^[1-9][0-9]*$ ]]; then
        printf 'ERROR: invalid num_rng_bins or num_valid_az in the PRM files.\n' >&2
        exit 4
    fi
done
if [[ $master_num_rng != "$aligned_num_rng" ||
      $master_num_azi != "$aligned_num_azi" ]]; then
    printf 'ERROR: master and aligned PRM image dimensions differ.\n' >&2
    exit 4
fi

nproc=${OFFSET_NPROC:-32}
target_points=${OFFSET_TARGET_POINTS:-4800000}
round_to=${OFFSET_GRID_ROUND:-100}
for item_name in xsearch ysearch nproc target_points round_to; do
    item_value=${!item_name}
    if [[ ! $item_value =~ ^[1-9][0-9]*$ ]]; then
        printf 'ERROR: %s must be a positive integer: %s\n' \
            "$item_name" "$item_value" >&2
        exit 4
    fi
done

raw_nx=$(awk \
    -v total="$target_points" \
    -v rng="$master_num_rng" \
    -v azi="$master_num_azi" \
    'BEGIN { printf "%.0f", sqrt(total * rng / azi) }')
nx=$((((raw_nx + round_to / 2) / round_to) * round_to))
raw_ny=$(((master_num_azi * nx + master_num_rng / 2) / master_num_rng))
ny=$((((raw_ny + round_to / 2) / round_to) * round_to))

total_points=$((nx * ny))
range_spacing=$(awk -v size="$master_num_rng" -v count="$nx" \
    'BEGIN { printf "%.2f", size / count }')
azimuth_spacing=$(awk -v size="$master_num_azi" -v count="$ny" \
    'BEGIN { printf "%.2f", size / count }')
x_inc=$((master_num_rng / nx))
y_inc=$((master_num_azi / ny))

printf '\n===== Run2 preview / 参数预览 =====\n'
printf 'Project:             %s\n' "$project_dir"
printf 'Offset pair:         %s\n' "$pair_name"

printf '\nMaster PRM:          %s\n' "$master_prm"
printf '  SLC_file:          %s\n' "$(read_prm_value "$master_path" SLC_file)"
printf '  num_rng_bins:      %s\n' "$master_num_rng"
printf '  num_valid_az:      %s\n' "$master_num_azi"
printf '  rshift/ashift:     %s / %s\n' \
    "$(read_prm_value "$master_path" rshift)" \
    "$(read_prm_value "$master_path" ashift)"
printf '  sub_int_r/a:       %s / %s\n' \
    "$(read_prm_value "$master_path" sub_int_r)" \
    "$(read_prm_value "$master_path" sub_int_a)"

printf '\nAligned PRM:         %s\n' "$aligned_prm"
printf '  SLC_file:          %s\n' "$(read_prm_value "$aligned_path" SLC_file)"
printf '  num_rng_bins:      %s\n' "$aligned_num_rng"
printf '  num_valid_az:      %s\n' "$aligned_num_azi"
printf '  rshift/ashift:     %s / %s\n' \
    "$(read_prm_value "$aligned_path" rshift)" \
    "$(read_prm_value "$aligned_path" ashift)"
printf '  sub_int_r/a:       %s / %s\n' \
    "$(read_prm_value "$aligned_path" sub_int_r)" \
    "$(read_prm_value "$aligned_path" sub_int_a)"

printf '\nRecommended formal parameters / 正式推荐参数:\n'
printf '  nx=%d  ny=%d  total=%d points\n' "$nx" "$ny" "$total_points"
printf '  center spacing:    range=%s px  azimuth=%s px\n' \
    "$range_spacing" "$azimuth_spacing"
printf '  integer increment: x_inc=%d  y_inc=%d (integer truncation)\n' \
    "$x_inc" "$y_inc"
printf '  xsearch/ysearch:   %d / %d (internal window %d x %d px)\n' \
    "$xsearch" "$ysearch" "$((xsearch * 2))" "$((ysearch * 2))"
printf '  allowed search:    16 32 64 128 256; recommended default: 16 / 16\n'
printf '  workers:           %d\n' "$nproc"
printf '  rule: nx:ny follows num_rng_bins:num_valid_az, rounded to %d.\n' \
    "$round_to"

if (( execute_run == 0 )); then
    printf '\nPreview only. No file was changed.\n'
    printf 'To save the currently displayed search size for Run3, run:\n'
    if [[ $xsearch == 16 && $ysearch == 16 ]]; then
        printf '  ./run2_recommend_grid.sh 1\n'
    else
        printf '  ./run2_recommend_grid.sh 1 %s %s\n' "$xsearch" "$ysearch"
    fi
    printf 'Example using another search size:\n'
    printf '  ./run2_recommend_grid.sh 32 32\n'
    printf '  ./run2_recommend_grid.sh 1 32 32\n'
    exit 0
fi

config_tmp=$(mktemp "$config_file.tmp.XXXXXX")
cleanup_tmp() {
    rm -f -- "$config_tmp"
}
trap cleanup_tmp EXIT
{
    printf 'CONFIG_VERSION=1\n'
    printf 'PROJECT_DIR=%s\n' "$project_dir"
    printf 'PAIR_NAME=%s\n' "$pair_name"
    printf 'MASTER_PRM=%s\n' "$master_prm"
    printf 'ALIGNED_PRM=%s\n' "$aligned_prm"
    printf 'NUM_RNG_BINS=%s\n' "$master_num_rng"
    printf 'NUM_VALID_AZ=%s\n' "$master_num_azi"
    printf 'NX=%s\n' "$nx"
    printf 'NY=%s\n' "$ny"
    printf 'XSEARCH=%s\n' "$xsearch"
    printf 'YSEARCH=%s\n' "$ysearch"
    printf 'X_INC=%s\n' "$x_inc"
    printf 'Y_INC=%s\n' "$y_inc"
    printf 'NPROC=%s\n' "$nproc"
} > "$config_tmp"
chmod 600 "$config_tmp"
mv -f -- "$config_tmp" "$config_file"
trap - EXIT

printf '\nRun2 complete. Parameters saved to:\n  %s\n' "$config_file"
printf '\n===== Next step / 下一步：Run3 =====\n'
printf 'Preview the saved parameters and exact parallel command:\n'
printf '  ./run3_run_offset.sh\n'
printf 'To start the formal calculation after checking it:\n  ./run3_run_offset.sh 1\n'
