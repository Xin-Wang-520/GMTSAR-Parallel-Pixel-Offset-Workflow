#!/usr/bin/env bash
# Author: Wang Xin
# Date: 2026-09-20
# Affiliation: University of Science and Technology of China (USTC)
# Contact: xinw11@mail.ustc.edu.cn
# Purpose: Run CPU-parallel GMTSAR offset tracking with progress reporting.

set -euo pipefail

execute_run=0
replace_existing=0
if [[ ${1:-} == 1 ]]; then
    execute_run=1
    shift
fi
if [[ ${1:-} == --replace ]]; then
    replace_existing=1
    shift
fi
if (( $# != 0 )); then
    printf 'Usage: %s [1] [--replace]\n' "$0" >&2
    printf '  no argument: preview only\n' >&2
    printf '  1: execute the formal offset calculation\n' >&2
    printf '  1 --replace: delete only the existing azi_offset result and rerun\n' >&2
    exit 2
fi

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
offset_dir=$script_dir
config_file=$offset_dir/offset_run.conf
if [[ ! -f $config_file ]]; then
    printf 'ERROR: Run2 parameter file not found: %s\n' "$config_file" >&2
    printf 'Run ./run2_recommend_grid.sh 1 first.\n' >&2
    exit 3
fi

config_version=''
project_dir=''
pair_name=''
master_prm=''
aligned_prm=''
num_rng_bins=''
num_valid_az=''
nx=''
ny=''
xsearch=''
ysearch=''
nproc=''
x_inc=''
y_inc=''
while IFS='=' read -r key value; do
    case $key in
        CONFIG_VERSION) config_version=$value ;;
        PROJECT_DIR) project_dir=$value ;;
        PAIR_NAME) pair_name=$value ;;
        MASTER_PRM) master_prm=$value ;;
        ALIGNED_PRM) aligned_prm=$value ;;
        NUM_RNG_BINS) num_rng_bins=$value ;;
        NUM_VALID_AZ) num_valid_az=$value ;;
        NX) nx=$value ;;
        NY) ny=$value ;;
        XSEARCH) xsearch=$value ;;
        YSEARCH) ysearch=$value ;;
        NPROC) nproc=$value ;;
        X_INC) x_inc=$value ;;
        Y_INC) y_inc=$value ;;
    esac
done < "$config_file"

if [[ $config_version != 1 ]]; then
    printf 'ERROR: unsupported or missing CONFIG_VERSION in %s\n' \
        "$config_file" >&2
    exit 3
fi
for text_name in project_dir pair_name master_prm aligned_prm; do
    if [[ -z ${!text_name} ]]; then
        printf 'ERROR: %s is missing in %s\n' "$text_name" "$config_file" >&2
        exit 3
    fi
done
for number_name in num_rng_bins num_valid_az nx ny xsearch ysearch nproc x_inc y_inc; do
    number_value=${!number_name}
    if [[ ! $number_value =~ ^[1-9][0-9]*$ ]]; then
        printf 'ERROR: invalid %s in %s: %s\n' \
            "$number_name" "$config_file" "$number_value" >&2
        exit 3
    fi
done
if [[ ! $pair_name =~ ^[A-Za-z0-9._-]+$ ||
      ! $master_prm =~ ^[A-Za-z0-9._-]+$ ||
      ! $aligned_prm =~ ^[A-Za-z0-9._-]+$ ]]; then
    printf 'ERROR: unsafe pair or PRM filename in %s\n' "$config_file" >&2
    exit 3
fi

expected_offset_dir=$project_dir/offset
if [[ $offset_dir != "$expected_offset_dir" ]]; then
    printf 'ERROR: this script must be located in the configured offset directory.\n' >&2
    printf 'Script directory: %s\nExpected: %s\n' \
        "$offset_dir" "$expected_offset_dir" >&2
    exit 3
fi

for required_file in \
    "$project_dir/SLC/$master_prm" \
    "$project_dir/SLC/$aligned_prm" \
    "$project_dir/topo/trans.dat" \
    "$project_dir/topo/dem.grd"; do
    if [[ ! -f $required_file ]]; then
        printf 'ERROR: required file not found: %s\n' "$required_file" >&2
        exit 4
    fi
done

pair_dir=$offset_dir/intf/$pair_name
azi_dir=$pair_dir/azi_offset
if [[ ! -d $pair_dir ]]; then
    printf 'ERROR: pair directory not found: %s\n' "$pair_dir" >&2
    printf 'Run ./run1_prepare_offset.sh 1 first.\n' >&2
    exit 4
fi

total_points=$((nx * ny))
range_spacing=$(awk -v pixels="$num_rng_bins" -v samples="$nx" \
    'BEGIN { printf "%.2f", pixels / samples }')
azimuth_spacing=$(awk -v pixels="$num_valid_az" -v samples="$ny" \
    'BEGIN { printf "%.2f", pixels / samples }')
runner=${MAKE_A_OFFSET_MT:-$HOME/bin/make_a_offset_mt.csh}

printf '\n===== Run3 preview / 正式计算预览 =====\n'
printf 'Project:           %s\n' "$project_dir"
printf 'Pair:              %s\n' "$pair_name"
printf 'Master/Aligned:    %s / %s\n' "$master_prm" "$aligned_prm"
printf 'PRM image size:    %s x %s pixels\n' "$num_rng_bins" "$num_valid_az"
printf 'Sampling grid:     nx=%s  ny=%s  total=%s points\n' \
    "$nx" "$ny" "$total_points"
printf 'Center spacing:    range=%s px  azimuth=%s px\n' \
    "$range_spacing" "$azimuth_spacing"
printf 'Integer increment: x_inc=%s  y_inc=%s (integer truncation)\n' \
    "$x_inc" "$y_inc"
printf 'Search arguments:  xsearch=%s  ysearch=%s\n' "$xsearch" "$ysearch"
printf 'Internal window:   %d x %d pixels\n' \
    "$((xsearch * 2))" "$((ysearch * 2))"
printf 'CPU workers:       %s\n' "$nproc"
printf 'Result directory:  %s\n' "$azi_dir"
printf '\nActual command / 实际调用命令:\n'
printf '  %s \\\n' "$runner"
printf '    %s \\\n' "$master_prm"
printf '    %s \\\n' "$aligned_prm"
printf '    %s %s %s %s 1\n' "$nx" "$ny" "$xsearch" "$ysearch"
printf 'Environment: XCORR_NPROC=%s  OMP_NUM_THREADS=1\n' "$nproc"

if [[ -d $azi_dir ]]; then
    printf 'Existing result:   YES\n'
    if (( replace_existing == 1 )); then
        printf 'Run3 action:       existing azi_offset will be replaced\n'
    else
        printf 'Run3 action:       protected; it will not be overwritten\n'
    fi
else
    printf 'Existing result:   NO\n'
fi

if (( execute_run == 0 )); then
    printf '\nPreview only. No calculation was started.\n'
    if [[ -d $azi_dir ]]; then
        printf 'To deliberately replace the existing result, run:\n'
        printf '  ./run3_run_offset.sh 1 --replace\n'
    else
        printf 'To start the formal calculation, run:\n'
        printf '  ./run3_run_offset.sh 1\n'
    fi
    exit 0
fi

if [[ -d $azi_dir && $replace_existing -eq 0 ]]; then
    printf 'ERROR: result directory already exists and was not changed:\n' >&2
    printf '  %s\n' "$azi_dir" >&2
    printf 'Use ./run3_run_offset.sh 1 --replace only for an intentional rerun.\n' >&2
    exit 5
fi

export PATH="$HOME/bin:$PATH"
conda_env_name=${CONDA_ENV_NAME:-}
if [[ -n $conda_env_name && ${CONDA_DEFAULT_ENV:-} != "$conda_env_name" ]]; then
    if ! command -v conda >/dev/null 2>&1; then
        printf 'ERROR: CONDA_ENV_NAME=%s was requested, but conda was not found.\n' \
            "$conda_env_name" >&2
        exit 6
    fi
    conda_base=$(conda info --base)
    # shellcheck disable=SC1091
    source "$conda_base/etc/profile.d/conda.sh"
    conda activate "$conda_env_name"
fi

if [[ ! -x $runner ]]; then
    printf 'ERROR: parallel make_a_offset script is not executable: %s\n' \
        "$runner" >&2
    exit 6
fi
if ! command -v xcorr_mt >/dev/null 2>&1; then
    printf 'ERROR: xcorr_mt was not found in PATH.\n' >&2
    exit 6
fi
if ! command -v setsid >/dev/null 2>&1; then
    printf 'ERROR: setsid was not found (util-linux is required).\n' >&2
    exit 6
fi

if [[ -d $azi_dir ]]; then
    expected_azi_dir=$project_dir/offset/intf/$pair_name/azi_offset
    if [[ $azi_dir != "$expected_azi_dir" ]]; then
        printf 'ERROR: refusing to remove unexpected path: %s\n' "$azi_dir" >&2
        exit 7
    fi
    printf '\nRemoving previous result directory: %s\n' "$azi_dir"
    find "$azi_dir" -depth -delete
fi

export XCORR_NPROC=$nproc
export OMP_NUM_THREADS=1
progress_interval=${OFFSET_PROGRESS_SECONDS:-30}
if [[ ! $progress_interval =~ ^[1-9][0-9]*$ ]]; then
    printf 'ERROR: OFFSET_PROGRESS_SECONDS must be a positive integer.\n' >&2
    exit 7
fi

timestamp=$(date +%Y%m%d_%H%M%S)
log_file=$offset_dir/make_a_offset_${pair_name}_${nx}x${ny}_${timestamp}.log
cd "$offset_dir"

printf '\nStarting formal offset calculation...\n'
printf 'Log: %s\n' "$log_file"
setsid "$runner" \
    "$master_prm" "$aligned_prm" \
    "$nx" "$ny" "$xsearch" "$ysearch" 1 \
    > "$log_file" 2>&1 &
job_pid=$!

stop_job() {
    printf '\nStopping process group %d...\n' "$job_pid" >&2
    kill -TERM -- "-$job_pid" 2>/dev/null || true
    wait "$job_pid" 2>/dev/null || true
    exit 130
}
trap stop_job INT TERM

printf 'Started PID %d. Progress refreshes every %d seconds.\n' \
    "$job_pid" "$progress_interval"

printf 'Waiting for make_a_offset initialization details...\n'
for ((init_wait = 0; init_wait < 30; init_wait++)); do
    if grep -q 'locations.*x_inc.*y_inc' "$log_file" 2>/dev/null; then
        break
    fi
    if ! kill -0 "$job_pid" 2>/dev/null; then
        break
    fi
    sleep 1
done

printf '\n===== make_a_offset initialization / 初始化信息 =====\n'
if [[ -s $log_file ]]; then
    awk '
        NR <= 60 { print }
        /locations.*x_inc.*y_inc/ { exit }
        NR == 60 { exit }
    ' "$log_file"
else
    printf '(No initialization output was written to the log.)\n'
fi
printf '===== progress / 运行进度 =====\n'

while kill -0 "$job_pid" 2>/dev/null; do
    part_lines=0
    if [[ -d $azi_dir ]]; then
        part_lines=$(
            find "$azi_dir" -maxdepth 1 -type f -name 'freq_xcorr.dat.part.*' \
                -exec wc -l {} + 2>/dev/null |
            awk '$2 != "total" {sum += $1} END {print sum+0}'
        )
    fi

    final_lines=0
    if [[ -f $azi_dir/freq_xcorr.dat ]]; then
        final_lines=$(wc -l < "$azi_dir/freq_xcorr.dat")
    fi
    completed=$((part_lines + final_lines))
    if (( completed > total_points )); then
        completed=$total_points
    fi

    percent=$(awk -v done="$completed" -v total="$total_points" \
        'BEGIN { printf "%.2f", 100 * done / total }')
    worker_count=$(
        (pgrep -u "$(id -un)" -x xcorr_mt 2>/dev/null || true) |
        wc -l | tr -d ' '
    )
    if (( completed >= total_points )); then
        stage='xcorr complete; GMT post-processing'
    elif (( worker_count > 0 )); then
        stage='cross-correlation'
    else
        stage='preparing inputs'
    fi

    printf '%s  %6s%%  %d/%d  processes=%d  %s\n' \
        "$(date '+%F %T')" "$percent" "$completed" "$total_points" \
        "$worker_count" "$stage"
    sleep "$progress_interval"
done

set +e
wait "$job_pid"
run_status=$?
set -e
trap - INT TERM

printf '\nRun exit status: %d\n' "$run_status"
if (( run_status != 0 )); then
    printf 'Run failed. Last 40 log lines:\n' >&2
    tail -40 "$log_file" >&2
    exit "$run_status"
fi

printf 'Run3 complete.\n'
printf 'Log: %s\n' "$log_file"
printf 'Result directory: %s\n' "$azi_dir"
if [[ -f $azi_dir/azioff_ll.png ]]; then
    printf 'Map: %s\n' "$azi_dir/azioff_ll.png"
fi

printf '\n===== Next step / 下一步：Run4 =====\n'
printf 'Preview range/azimuth gridding and map parameters:\n'
printf '  ./run4_make_range_azimuth_grids_and_plots.sh\n'
printf 'After checking the preview, create the default factor-4 products:\n'
printf '  ./run4_make_range_azimuth_grids_and_plots.sh 1 --factor 4\n'
