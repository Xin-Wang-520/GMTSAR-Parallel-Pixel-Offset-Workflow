#!/usr/bin/env bash
# Author: Wang Xin
# Date: 2026-09-20
# Affiliation: University of Science and Technology of China (USTC)
# Contact: xinw11@mail.ustc.edu.cn
# Purpose: Filter geocoded offset grids and create comparison-ready products.

set -euo pipefail

execute_run=0
replace_existing=0
keep_intermediate=0
profile=${RUN5_PROFILE:-balanced}
clip_m=${RUN5_CLIP_M:-10}
output_spacing=${RUN5_OUTPUT_SPACING:-preserve}
custom_median_cells=${RUN5_MEDIAN_CELLS:-}
custom_gaussian_cells=${RUN5_GAUSSIAN_CELLS:-}

if [[ ${1:-} == 1 ]]; then
    execute_run=1
    shift
fi
while (( $# > 0 )); do
    case $1 in
        --profile)
            (( $# >= 2 )) || { printf 'ERROR: --profile requires mild, balanced, or strong.\n' >&2; exit 2; }
            profile=$2
            shift 2
            ;;
        --clip-m)
            (( $# >= 2 )) || { printf 'ERROR: --clip-m requires a non-negative number.\n' >&2; exit 2; }
            clip_m=$2
            shift 2
            ;;
        --median-cells)
            (( $# >= 2 )) || { printf 'ERROR: --median-cells requires a positive integer.\n' >&2; exit 2; }
            custom_median_cells=$2
            shift 2
            ;;
        --gaussian-cells)
            (( $# >= 2 )) || { printf 'ERROR: --gaussian-cells requires a positive integer.\n' >&2; exit 2; }
            custom_gaussian_cells=$2
            shift 2
            ;;
        --spacing)
            (( $# >= 2 )) || { printf 'ERROR: --spacing requires a GMT grid increment.\n' >&2; exit 2; }
            output_spacing=$2
            shift 2
            ;;
        --keep-intermediate)
            keep_intermediate=1
            shift
            ;;
        --replace)
            replace_existing=1
            shift
            ;;
        *)
            printf 'ERROR: unknown argument: %s\n' "$1" >&2
            printf 'Usage: %s [1] [--profile mild|balanced|strong] [--median-cells N --gaussian-cells N] [--clip-m M] [--spacing INC] [--keep-intermediate] [--replace]\n' "$0" >&2
            exit 2
            ;;
    esac
done

case $profile in
    mild)     median_cells=3; gaussian_cells=6 ;;
    balanced) median_cells=5; gaussian_cells=6 ;;
    strong)   median_cells=7; gaussian_cells=12 ;;
    *) printf 'ERROR: profile must be mild, balanced, or strong.\n' >&2; exit 2 ;;
esac
if [[ -n $custom_median_cells || -n $custom_gaussian_cells ]]; then
    if [[ -z $custom_median_cells || -z $custom_gaussian_cells ]]; then
        printf 'ERROR: custom filtering requires both --median-cells and --gaussian-cells.\n' >&2
        exit 2
    fi
    if [[ ! $custom_median_cells =~ ^[1-9][0-9]*$ ||
          ! $custom_gaussian_cells =~ ^[1-9][0-9]*$ ]]; then
        printf 'ERROR: custom filter cell counts must be positive integers.\n' >&2
        exit 2
    fi
    median_cells=$custom_median_cells
    gaussian_cells=$custom_gaussian_cells
    profile=custom
fi
if ! awk -v value="$clip_m" 'BEGIN {exit !(value ~ /^[0-9]*\.?[0-9]+([eE][-+]?[0-9]+)?$/ && value >= 0)}'; then
    printf 'ERROR: --clip-m must be a non-negative number.\n' >&2
    exit 2
fi
if (( replace_existing == 1 && execute_run == 0 )); then
    printf 'ERROR: --replace is valid only together with execution argument 1.\n' >&2
    exit 2
fi

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
offset_dir=$script_dir
project_dir=$(dirname "$offset_dir")
config_file=$offset_dir/offset_run.conf

read_config() {
    local wanted=$1
    awk -F= -v wanted="$wanted" '$1 == wanted {sub(/^[^=]*=/, ""); print; exit}' "$config_file"
}

if [[ ! -f $config_file ]]; then
    printf 'ERROR: Run2 parameter file not found: %s\n' "$config_file" >&2
    printf 'Run ./run2_recommend_grid.sh 1 first, or create offset_run.conf for an existing manual run.\n' >&2
    exit 3
fi
pair_name=$(read_config PAIR_NAME)
if [[ -z $pair_name || ! $pair_name =~ ^[A-Za-z0-9._-]+$ ]]; then
    printf 'ERROR: PAIR_NAME is missing or invalid in %s\n' "$config_file" >&2
    exit 3
fi

azi_dir=$offset_dir/intf/$pair_name/azi_offset
components_dir=$azi_dir/offset_components
azimuth_grid=$components_dir/azimuth_offset_ll_m.grd
range_grid=$components_dir/range_offset_ll_m.grd
clip_tag=$(printf '%s' "$clip_m" | sed 's/[^A-Za-z0-9_-]/p/g')
spacing_tag=$(printf '%s' "$output_spacing" | sed 's/[^A-Za-z0-9_-]/p/g')
run_tag=${profile}_m${median_cells}_g${gaussian_cells}_clip${clip_tag}_${spacing_tag}
output_root=$components_dir/filtered
output_dir=$output_root/$run_tag
dem_file=$azi_dir/dem.grd

for required_file in "$azimuth_grid" "$range_grid"; do
    if [[ ! -f $required_file ]]; then
        printf 'ERROR: Run4 output not found: %s\n' "$required_file" >&2
        printf 'Complete Run4 before running Run5.\n' >&2
        exit 4
    fi
done
if ! command -v gmt >/dev/null 2>&1; then
    printf 'ERROR: gmt was not found in PATH.\n' >&2
    exit 5
fi

# grdinfo -C: file west east south north zmin zmax dx dy nx ny registration...
read -r _ west east south north az_zmin az_zmax dx dy nx ny _ < <(gmt grdinfo "$azimuth_grid" -C)
read -r _ range_west range_east range_south range_north range_zmin range_zmax \
    range_dx range_dy range_nx range_ny _ < <(gmt grdinfo "$range_grid" -C)
for value_name in west east south north dx dy nx ny; do
    if [[ -z ${!value_name:-} ]]; then
        printf 'ERROR: could not read grid geometry from %s\n' "$azimuth_grid" >&2
        exit 5
    fi
done
grid_geometry_match=$(awk \
    -v w1="$west" -v e1="$east" -v s1="$south" -v n1="$north" \
    -v dx1="$dx" -v dy1="$dy" -v nx1="$nx" -v ny1="$ny" \
    -v w2="$range_west" -v e2="$range_east" -v s2="$range_south" -v n2="$range_north" \
    -v dx2="$range_dx" -v dy2="$range_dy" -v nx2="$range_nx" -v ny2="$range_ny" '
    function nearly_equal(a,b) {scale=(a<0?-a:a); if ((b<0?-b:b)>scale) scale=(b<0?-b:b); if (scale<1) scale=1; return ((a-b<0?b-a:a-b) <= scale*1e-9)}
    BEGIN {print (nearly_equal(w1,w2) && nearly_equal(e1,e2) && nearly_equal(s1,s2) && nearly_equal(n1,n2) && nearly_equal(dx1,dx2) && nearly_equal(dy1,dy2) && nx1==nx2 && ny1==ny2) ? "YES" : "NO"}'
)
if [[ $grid_geometry_match != YES ]]; then
    printf 'ERROR: azimuth and range grids do not have matching geometry.\n' >&2
    printf 'Azimuth: %s x %s nodes, increment %s x %s degrees\n' "$nx" "$ny" "$dx" "$dy" >&2
    printf 'Range:   %s x %s nodes, increment %s x %s degrees\n' "$range_nx" "$range_ny" "$range_dx" "$range_dy" >&2
    exit 5
fi

center_lat=$(awk -v south="$south" -v north="$north" 'BEGIN {printf "%.12g", (south+north)/2}')
read -r cell_x_m cell_y_m cell_ref_m < <(
    awk -v dx="$dx" -v dy="$dy" -v lat="$center_lat" '
        BEGIN {
            pi=atan2(0,-1)
            x=dx*111320*cos(lat*pi/180)
            y=dy*110574
            ref=(x>y?x:y)
            printf "%.3f %.3f %.3f\n", x, y, ref
        }'
)
median_km=$(awk -v cell="$cell_ref_m" -v count="$median_cells" 'BEGIN {printf "%.9g", cell*count/1000}')
gaussian_km=$(awk -v cell="$cell_ref_m" -v count="$gaussian_cells" 'BEGIN {printf "%.9g", cell*count/1000}')
median_m=$(awk -v km="$median_km" 'BEGIN {printf "%.1f", km*1000}')
gaussian_m=$(awk -v km="$gaussian_km" 'BEGIN {printf "%.1f", km*1000}')
gaussian_sigma_m=$(awk -v km="$gaussian_km" 'BEGIN {printf "%.1f", km*1000/6}')

printf '\n===== Run5 preview / 偏移网格滤波预览 =====\n'
printf 'Project:              %s\n' "$project_dir"
printf 'Pair:                 %s\n' "$pair_name"
printf 'Input azimuth:        %s\n' "$azimuth_grid"
printf 'Input range:          %s\n' "$range_grid"
printf 'Azimuth grid:         %s x %s nodes; increment %s x %s degrees\n' "$nx" "$ny" "$dx" "$dy"
printf 'Range grid:           %s x %s nodes; increment %s x %s degrees\n' \
    "$range_nx" "$range_ny" "$range_dx" "$range_dy"
printf 'Grid geometry match:  %s\n' "$grid_geometry_match"
printf 'Approx. cell size:    east-west=%s m  north-south=%s m (latitude %.4f degrees)\n' \
    "$cell_x_m" "$cell_y_m" "$center_lat"
printf 'Reference cell size:  %s m = max(east-west, north-south)\n' "$cell_ref_m"
printf 'Filter-size formula:  reference cell size x number of filter cells\n'
printf 'Input value range:    azimuth=%s to %s m; range=%s to %s m\n' \
    "$az_zmin" "$az_zmax" "$range_zmin" "$range_zmax"
printf '\nAvailable filter profiles / 可选滤波强度:\n'
printf '  %-11s %-27s %-43s %s\n' \
    'Profile' 'Median filter' 'Gaussian filter' 'Selection'
for preview_profile in mild balanced strong; do
    case $preview_profile in
        mild)     preview_median_cells=3; preview_gaussian_cells=6 ;;
        balanced) preview_median_cells=5; preview_gaussian_cells=6 ;;
        strong)   preview_median_cells=7; preview_gaussian_cells=12 ;;
    esac
    preview_median_m=$(awk -v cell="$cell_ref_m" -v count="$preview_median_cells" \
        'BEGIN {printf "%.1f",cell*count}')
    preview_gaussian_m=$(awk -v cell="$cell_ref_m" -v count="$preview_gaussian_cells" \
        'BEGIN {printf "%.1f",cell*count}')
    preview_sigma_m=$(awk -v width="$preview_gaussian_m" \
        'BEGIN {printf "%.1f",width/6}')
    preview_median_km=$(awk -v metres="$preview_median_m" \
        'BEGIN {printf "%.6g",metres/1000}')
    preview_gaussian_km=$(awk -v metres="$preview_gaussian_m" \
        'BEGIN {printf "%.6g",metres/1000}')
    selection=''
    [[ $preview_profile == "$profile" ]] && selection='<-- selected / 当前选择'
    printf '  %-11s %2s cells (~%7s m, %8s km)   %2s cells (~%7s m, %8s km; sigma~%s m) %s\n' \
        "$preview_profile" "$preview_median_cells" "$preview_median_m" \
        "$preview_median_km" "$preview_gaussian_cells" "$preview_gaussian_m" \
        "$preview_gaussian_km" "$preview_sigma_m" "$selection"
done
if [[ $profile == custom ]]; then
    printf '  %-11s %2s cells (~%7s m, %8s km)   %2s cells (~%7s m, %8s km; sigma~%s m) %s\n' \
        'custom' "$median_cells" "$median_m" "$median_km" \
        "$gaussian_cells" "$gaussian_m" "$gaussian_km" \
        "$gaussian_sigma_m" '<-- selected / 当前选择'
fi
printf '  注：中值数字是滤波窗口完整直径的网格数；高斯数字是完整宽度的网格数。\n\n'
printf 'Filter profile:       %s\n' "$profile"
printf 'Safety clipping:      '
if awk -v value="$clip_m" 'BEGIN {exit !(value > 0)}'; then
    printf -- '-%s to +%s m; outside values become NaN\n' "$clip_m" "$clip_m"
else
    printf 'disabled\n'
fi
printf 'Median filter:        %s grid cells = %.6g km (~%s m full diameter)\n' \
    "$median_cells" "$median_km" "$median_m"
printf 'Gaussian filter:      %s grid cells = %.6g km (~%s m full width; sigma~%s m)\n' \
    "$gaussian_cells" "$gaussian_km" "$gaussian_m" "$gaussian_sigma_m"
printf 'NaN handling:         -Nr (do not fill cells whose centre was originally NaN)\n'
if [[ $output_spacing == preserve ]]; then
    printf 'Output spacing:       preserve Run4 grid (%s x %s degrees)\n' "$dx" "$dy"
else
    printf 'Output spacing:       %s (GMT increment; resampling happens after filtering)\n' "$output_spacing"
fi
printf 'Output directory:     %s\n' "$output_dir"
printf 'Run folder name:      %s\n' "$run_tag"
printf '\nProcessing order / 处理顺序:\n'
printf '  clip -> spherical median filter -> light Gaussian filter -> optional resample -> maps\n'
printf '  中值滤波清除孤立噪点；高斯滤波只用于平滑剩余的小尺度纹理。\n'
printf '\nExpected final products / 预计输出:\n'
printf '  azimuth_offset_ll_m_filtered.grd\n'
printf '  range_offset_ll_m_filtered.grd\n'
printf '  azimuth_offset_ll_filtered.pdf and range_offset_ll_filtered.pdf\n'
printf '  azimuth_offset_ll_filtered_google.kmz and range_offset_ll_filtered_google.kmz\n'
printf '  README_outputs.txt\n'
if [[ -d $output_dir ]]; then
    printf '\nExisting Run5 output: YES\n'
else
    printf '\nExisting Run5 output: NO\n'
fi

if (( execute_run == 0 )); then
    printf '\nPreview only. Run4 grids were not modified.\n'
    printf 'To run this configuration:\n'
    if [[ $profile == custom ]]; then
        printf '  ./run5_filter_offset_grids.sh 1 --median-cells %s --gaussian-cells %s --clip-m %s' \
            "$median_cells" "$gaussian_cells" "$clip_m"
    else
        printf '  ./run5_filter_offset_grids.sh 1 --profile %s --clip-m %s' "$profile" "$clip_m"
    fi
    [[ $output_spacing == preserve ]] || printf ' --spacing %s' "$output_spacing"
    [[ -d $output_dir ]] && printf ' --replace'
    (( keep_intermediate == 1 )) && printf ' --keep-intermediate'
    printf '\n'
    printf '\nPreview another profile / 预览其他强度:\n'
    printf '  ./run5_filter_offset_grids.sh --profile mild\n'
    printf '  ./run5_filter_offset_grids.sh --profile balanced\n'
    printf '  ./run5_filter_offset_grids.sh --profile strong\n'
    printf '  ./run5_filter_offset_grids.sh --median-cells 4 --gaussian-cells 8\n'
    exit 0
fi

for command_name in gmt zip; do
    command -v "$command_name" >/dev/null 2>&1 || {
        printf 'ERROR: required command not found: %s\n' "$command_name" >&2
        exit 5
    }
done
if [[ -d $output_dir ]]; then
    if (( replace_existing == 0 )); then
        printf 'ERROR: Run5 output already exists and was not changed: %s\n' "$output_dir" >&2
        printf 'Use 1 --replace for an intentional Run5 rerun.\n' >&2
        exit 6
    fi
    expected_dir=$project_dir/offset/intf/$pair_name/azi_offset/offset_components/filtered/$run_tag
    if [[ $output_dir != "$expected_dir" ]]; then
        printf 'ERROR: refusing to remove unexpected path: %s\n' "$output_dir" >&2
        exit 6
    fi
    find "$output_dir" -depth -delete
fi
mkdir -p "$output_dir"
cd "$output_dir"

filter_component() {
    local source_grid=$1
    local prefix=$2
    local clipped=${prefix}_clipped.grd
    local median=${prefix}_median.grd
    local smooth=${prefix}_smooth.grd
    local final=${prefix}_filtered.grd

    if awk -v value="$clip_m" 'BEGIN {exit !(value > 0)}'; then
        gmt grdclip "$source_grid" -Sb-"$clip_m"/NaN -Sa"$clip_m"/NaN -G"$clipped"
    else
        cp -p "$source_grid" "$clipped"
    fi
    gmt grdfilter "$clipped" -D4 -Fm"$median_km" -Nr -G"$median" -V
    gmt grdfilter "$median" -D4 -Fg"$gaussian_km" -Nr -G"$smooth" -V
    if [[ $output_spacing == preserve ]]; then
        cp -p "$smooth" "$final"
    else
        gmt grdsample "$smooth" -I"$output_spacing" -fg -G"$final"
    fi
}

printf '\nFiltering azimuth component...\n'
filter_component "$azimuth_grid" azimuth_offset_ll_m
printf '\nFiltering range component...\n'
filter_component "$range_grid" range_offset_ll_m

plot_component() {
    local grid_file=$1
    local output_name=$2
    local title=$3
    local cpt_file=${output_name}.cpt
    local google_name=${output_name}_google
    local zmin zmax zabs zinc

    read -r _ _ _ _ _ zmin zmax _ < <(gmt grdinfo "$grid_file" -C)
    zabs=$(awk -v min="$zmin" -v max="$zmax" '
        BEGIN {a=(min<0?-min:min); b=(max<0?-max:max); v=(a>b?a:b); if (v<=0) v=1; printf "%.12g",v}')
    zinc=$(awk -v limit="$zabs" 'BEGIN {printf "%.12g",2*limit/30}')
    gmt makecpt -Cpolar -T-"$zabs"/"$zabs"/"$zinc" -Z -D > "$cpt_file"

    gmt begin "$output_name" pdf
        if [[ -f $dem_file ]]; then
            gmt grdimage "$dem_file" -R"$grid_file" -JM15c -Cgray -I+d
        fi
        gmt grdimage "$grid_file" -R"$grid_file" -JM15c -C"$cpt_file" -Q
        gmt basemap -R"$grid_file" -JM15c -Baf -BWSne+t"$title"
        gmt colorbar -C"$cpt_file" -DJBC+w10c/0.5c+h+e+o0/0.9c -Bxaf -By+l"m"
    gmt end

    gmt grdimage "$grid_file" -R"$grid_file" -JX15c -C"$cpt_file" -Q -E300 -A"${google_name}.png"
    gmt begin "${google_name}_colorbar" png
        gmt basemap -R0/1/0/1 -JX2.5c/9c -B0
        gmt colorbar -C"$cpt_file" -Dx1.25c/4.5c+w7c/0.55c+v+e+jMC -Baf+l"m"
    gmt end
}

make_kmz() {
    local grid_file=$1
    local output_name=$2
    local title=$3
    local google_name=${output_name}_google
    local west2 east2 south2 north2
    read -r _ west2 east2 south2 north2 _ < <(gmt grdinfo "$grid_file" -C)
    {
        printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'
        printf '%s\n' '<kml xmlns="http://www.opengis.net/kml/2.2">'
        printf '  <Document><name>%s</name>\n' "$title"
        printf '    <GroundOverlay><name>%s</name><Icon><href>%s.png</href></Icon>\n' "$title" "$google_name"
        printf '      <LatLonBox><north>%s</north><south>%s</south><east>%s</east><west>%s</west></LatLonBox>\n' "$north2" "$south2" "$east2" "$west2"
        printf '%s\n' '    </GroundOverlay>'
        printf '    <ScreenOverlay><name>%s colorbar</name><Icon><href>%s_colorbar.png</href></Icon>\n' "$title" "$google_name"
        printf '%s\n' '      <overlayXY x="1" y="0" xunits="fraction" yunits="fraction"/>'
        printf '%s\n' '      <screenXY x="0.98" y="0.05" xunits="fraction" yunits="fraction"/>'
        printf '%s\n' '      <size x="0" y="0.35" xunits="fraction" yunits="fraction"/>'
        printf '%s\n' '    </ScreenOverlay></Document></kml>'
    } > "${google_name}.kml"
    zip -q -j "${google_name}.kmz" "${google_name}.kml" "${google_name}.png" "${google_name}_colorbar.png"
}

plot_component azimuth_offset_ll_m_filtered.grd azimuth_offset_ll_filtered 'Filtered azimuth offset'
make_kmz azimuth_offset_ll_m_filtered.grd azimuth_offset_ll_filtered 'Filtered azimuth offset'
plot_component range_offset_ll_m_filtered.grd range_offset_ll_filtered 'Filtered range offset'
make_kmz range_offset_ll_m_filtered.grd range_offset_ll_filtered 'Filtered range offset'

{
    printf 'Run5 filtering products\n'
    printf 'Pair: %s\n' "$pair_name"
    printf 'Run folder: %s\n' "$run_tag"
    printf 'Profile: %s\n' "$profile"
    printf 'Input cell size: %s x %s m (approximate at latitude %s degrees)\n' "$cell_x_m" "$cell_y_m" "$center_lat"
    printf 'Clip limit: +/- %s m (0 means disabled)\n' "$clip_m"
    printf 'Median: %s cells, %s km full diameter\n' "$median_cells" "$median_km"
    printf 'Gaussian: %s cells, %s km full width, sigma approximately %s m\n' "$gaussian_cells" "$gaussian_km" "$gaussian_sigma_m"
    printf 'NaN policy: -Nr; an originally NaN centre remains NaN\n'
    printf 'Output spacing: %s\n' "$output_spacing"
    printf 'Inputs:\n  %s\n  %s\n' "$azimuth_grid" "$range_grid"
    printf 'Final grids:\n  azimuth_offset_ll_m_filtered.grd\n  range_offset_ll_m_filtered.grd\n'
} > README_outputs.txt

if (( keep_intermediate == 0 )); then
    rm -f -- \
        azimuth_offset_ll_m_clipped.grd azimuth_offset_ll_m_median.grd azimuth_offset_ll_m_smooth.grd \
        range_offset_ll_m_clipped.grd range_offset_ll_m_median.grd range_offset_ll_m_smooth.grd \
        azimuth_offset_ll_filtered.cpt range_offset_ll_filtered.cpt gmt.history
fi

printf '\n===== Run5 complete / 滤波完成 =====\n'
printf 'Output directory: %s\n' "$output_dir"
printf 'Azimuth grid:    %s/azimuth_offset_ll_m_filtered.grd\n' "$output_dir"
printf 'Range grid:      %s/range_offset_ll_m_filtered.grd\n' "$output_dir"
printf 'Azimuth KMZ:     %s/azimuth_offset_ll_filtered_google.kmz\n' "$output_dir"
printf 'Range KMZ:       %s/range_offset_ll_filtered_google.kmz\n' "$output_dir"

printf '\n===== Workflow complete / 流程完成 =====\n'
printf 'Run1-Run5 completed for this filter configuration.\n'
printf 'Compare the filtered products with the original Run4 grids before interpretation.\n'
printf 'To test another filter without overwriting this result, for example:\n'
printf '  ./run5_filter_offset_grids.sh 1 --profile mild\n'
printf '  ./run5_filter_offset_grids.sh 1 --median-cells 4 --gaussian-cells 8\n'
