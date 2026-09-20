#!/usr/bin/env bash
# Author: Wang Xin
# Date: 2026-09-20
# Affiliation: University of Science and Technology of China (USTC)
# Contact: xinw11@mail.ustc.edu.cn
# Purpose: Create geocoded range/azimuth offset grids, maps, and KMZ files.

set -euo pipefail

execute_run=0
replace_existing=0
keep_intermediate=0
factor_argument=''
if [[ ${1:-} == 1 ]]; then
    execute_run=1
    shift
fi
while (( $# > 0 )); do
    case $1 in
        --replace)
            replace_existing=1
            shift
            ;;
        --keep-intermediate)
            keep_intermediate=1
            shift
            ;;
        --factor)
            if (( $# < 2 )); then
                printf 'ERROR: --factor requires a positive integer.\n' >&2
                exit 2
            fi
            factor_argument=$2
            shift 2
            ;;
        *)
            printf 'ERROR: unknown argument: %s\n' "$1" >&2
            printf 'Usage: %s [1] [--factor N] [--keep-intermediate] [--replace]\n' "$0" >&2
            exit 2
            ;;
    esac
done
if (( replace_existing == 1 && execute_run == 0 )); then
    printf 'ERROR: --replace is valid only together with execution argument 1.\n' >&2
    exit 2
fi
if [[ -n $factor_argument && ! $factor_argument =~ ^[1-9][0-9]*$ ]]; then
    printf 'ERROR: --factor must be a positive integer.\n' >&2
    exit 2
fi
if (( $# != 0 )); then
    printf 'Usage: %s [1] [--factor N] [--keep-intermediate] [--replace]\n' "$0" >&2
    printf '  no argument: preview only\n' >&2
    printf '  1: generate range and azimuth grids/maps\n' >&2
    printf '  --factor N: choose the block aggregation factor (default 4)\n' >&2
    printf '  --keep-intermediate: retain pixel/radar grids and processing tables\n' >&2
    printf '  1 --replace: replace only the Run4 output subdirectory\n' >&2
    exit 2
fi

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

read_config() {
    local wanted=$1
    awk -F= -v wanted="$wanted" '$1 == wanted {sub(/^[^=]*=/, ""); print; exit}' \
        "$config_file"
}

is_positive_integer() {
    [[ $1 =~ ^[1-9][0-9]*$ ]]
}

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
offset_dir=$script_dir
project_dir=$(dirname "$offset_dir")
config_file=$offset_dir/offset_run.conf

if [[ ! -f $config_file ]]; then
    printf 'ERROR: Run2 parameter file not found: %s\n' "$config_file" >&2
    printf 'Run ./run2_recommend_grid.sh 1 first.\n' >&2
    exit 3
fi

pair_name=$(read_config PAIR_NAME)
master_prm=$(read_config MASTER_PRM)
nx=$(read_config NX)
ny=$(read_config NY)
for name in pair_name master_prm nx ny; do
    if [[ -z ${!name} ]]; then
        printf 'ERROR: %s is missing in %s\n' "$name" "$config_file" >&2
        exit 3
    fi
done
if [[ ! $pair_name =~ ^[A-Za-z0-9._-]+$ ||
      ! $master_prm =~ ^[A-Za-z0-9._-]+$ ]] ||
      ! is_positive_integer "$nx" || ! is_positive_integer "$ny"; then
    printf 'ERROR: invalid pair, PRM, nx, or ny in %s\n' "$config_file" >&2
    exit 3
fi

azi_dir=$offset_dir/intf/$pair_name/azi_offset
freq_file=$azi_dir/freq_xcorr.dat
trans_file=$azi_dir/trans.dat
dem_file=$azi_dir/dem.grd
master_path=$azi_dir/$master_prm
output_dir=$azi_dir/offset_components

for required_file in "$freq_file" "$trans_file" "$dem_file" "$master_path"; do
    if [[ ! -f $required_file ]]; then
        printf 'ERROR: required file not found: %s\n' "$required_file" >&2
        exit 4
    fi
done

aggregate_factor=${factor_argument:-${RUN4_AGGREGATE_FACTOR:-4}}
# Column 5 of GMTSAR freq_xcorr.dat is the SNR used for quality filtering.
# Keep RUN4_MIN_CORR as a backward-compatible alias for older copies.
min_corr=${RUN4_MIN_SNR:-${RUN4_MIN_CORR:-10}}
max_abs_offset=${RUN4_MAX_ABS_OFFSET:-5}
prf=$(read_prm_value "$master_path" PRF)
sc_vel=$(read_prm_value "$master_path" SC_vel)
earth_radius=$(read_prm_value "$master_path" earth_radius)
sc_height=$(read_prm_value "$master_path" SC_height)
rng_samp_rate=$(read_prm_value "$master_path" rng_samp_rate)
azi_pixel_size=$(awk \
    -v vel="$sc_vel" -v radius="$earth_radius" \
    -v height="$sc_height" -v prf="$prf" '
    BEGIN {
        if (vel+0 > 0 && radius+0 > 0 && prf+0 > 0) {
            ground_vel=vel/sqrt(1+height/radius)
            printf "%.12g", ground_vel/prf
        }
    }')
range_pixel_size=$(awk -v rate="$rng_samp_rate" '
    BEGIN {
        if (rate+0 > 0) printf "%.12g", 299792458/(2*rate)
    }')
azi_pixel_size_display='unavailable'
range_pixel_size_display='unavailable'
if [[ -n $azi_pixel_size ]]; then
    azi_pixel_size_display=$(awk -v value="$azi_pixel_size" \
        'BEGIN {printf "%.3f", value}')
fi
if [[ -n $range_pixel_size ]]; then
    range_pixel_size_display=$(awk -v value="$range_pixel_size" \
        'BEGIN {printf "%.3f", value}')
fi
if ! is_positive_integer "$aggregate_factor"; then
    printf 'ERROR: RUN4_AGGREGATE_FACTOR must be a positive integer.\n' >&2
    exit 4
fi
if ! awk -v value="$min_corr" 'BEGIN {exit !(value ~ /^[-+]?[0-9]*\.?[0-9]+([eE][-+]?[0-9]+)?$/)}'; then
    printf 'ERROR: RUN4_MIN_SNR must be numeric.\n' >&2
    exit 4
fi
if ! awk -v value="$max_abs_offset" 'BEGIN {exit !(value ~ /^[-+]?[0-9]*\.?[0-9]+([eE][-+]?[0-9]+)?$/)}'; then
    printf 'ERROR: RUN4_MAX_ABS_OFFSET must be numeric.\n' >&2
    exit 4
fi

line_count=$(wc -l < "$freq_file")
read -r preview_range_count preview_azimuth_count < <(
    awk -v min_corr="$min_corr" -v max_abs="$max_abs_offset" '
        function abs(v) { return v < 0 ? -v : v }
        NF >= 5 && $5 > min_corr {
            if (max_abs <= 0 || abs($2) <= max_abs) range_count++
            if (max_abs <= 0 || abs($4) <= max_abs) azimuth_count++
        }
        END {print range_count+0, azimuth_count+0}
    ' "$freq_file"
)
estimated_grid_nx=$(((nx + aggregate_factor - 1) / aggregate_factor))
estimated_grid_ny=$(((ny + aggregate_factor - 1) / aggregate_factor))
estimated_grid_total=$((estimated_grid_nx * estimated_grid_ny))
aggregate_area_factor=$((aggregate_factor * aggregate_factor))
keep_option=''
if (( keep_intermediate == 1 )); then
    keep_option=' --keep-intermediate'
fi
image_range_pixels=$(read_prm_value "$master_path" num_rng_bins)
image_azimuth_pixels=$(read_prm_value "$master_path" num_valid_az)
base_spacing_range='unknown'
base_spacing_azimuth='unknown'
aggregate_spacing_range='unknown'
aggregate_spacing_azimuth='unknown'
if [[ $image_range_pixels =~ ^[0-9]+$ &&
      $image_azimuth_pixels =~ ^[0-9]+$ ]]; then
    base_spacing_range=$(awk -v pixels="$image_range_pixels" -v count="$nx" \
        'BEGIN {printf "%.2f", pixels/count}')
    base_spacing_azimuth=$(awk -v pixels="$image_azimuth_pixels" -v count="$ny" \
        'BEGIN {printf "%.2f", pixels/count}')
    aggregate_spacing_range=$(awk -v spacing="$base_spacing_range" \
        -v factor="$aggregate_factor" 'BEGIN {printf "%.2f", spacing*factor}')
    aggregate_spacing_azimuth=$(awk -v spacing="$base_spacing_azimuth" \
        -v factor="$aggregate_factor" 'BEGIN {printf "%.2f", spacing*factor}')
fi
printf '\n===== Run4 preview / 双分量制图预览 =====\n'
printf 'Project:             %s\n' "$project_dir"
printf 'Pair:                %s\n' "$pair_name"
printf 'Input:               %s\n' "$freq_file"
printf 'Input rows:          %s\n' "$line_count"
printf 'Rows after filters:  range=%s  azimuth=%s\n' \
    "$preview_range_count" "$preview_azimuth_count"
printf 'Grid source:         nx=%s  ny=%s\n' "$nx" "$ny"
printf 'Aggregation factor:  %s (default 4; factor 1 keeps the nx/ny sampling density)\n' \
    "$aggregate_factor"
printf 'Estimated grid:      %s x %s = %s nodes before filtering\n' \
    "$estimated_grid_nx" "$estimated_grid_ny" "$estimated_grid_total"
printf 'Source spacing:      range=%s px  azimuth=%s px\n' \
    "$base_spacing_range" "$base_spacing_azimuth"
printf 'Output spacing:      range~%s px  azimuth~%s px after aggregation\n' \
    "$aggregate_spacing_range" "$aggregate_spacing_azimuth"
printf 'Aggregation meaning: factor %s makes each direction ~%sx coarser and nodes ~1/%s of factor 1\n' \
    "$aggregate_factor" "$aggregate_factor" "$aggregate_area_factor"
printf 'Factor explanation:  factor=1 保留原采样密度；factor=%s 在两个方向上都将网格间距扩大%s倍\n' \
    "$aggregate_factor" "$aggregate_factor"
printf 'Aggregation purpose: 对相邻偏移点做 blockmedian，减少噪声、网格体积和制图量；只影响 Run4，不会重跑 xcorr\n'
printf '\nRecommended aggregation factors / 建议聚合系数:\n'
for recommended_factor in 1 4 12; do
    recommended_nx=$(((nx + recommended_factor - 1) / recommended_factor))
    recommended_ny=$(((ny + recommended_factor - 1) / recommended_factor))
    recommended_total=$((recommended_nx * recommended_ny))
    recommended_range_spacing=$(awk -v spacing="$base_spacing_range" \
        -v factor="$recommended_factor" \
        'BEGIN {if (spacing=="unknown") print "unknown"; else printf "%.2f",spacing*factor}')
    recommended_azimuth_spacing=$(awk -v spacing="$base_spacing_azimuth" \
        -v factor="$recommended_factor" \
        'BEGIN {if (spacing=="unknown") print "unknown"; else printf "%.2f",spacing*factor}')
    case $recommended_factor in
        1) recommendation='保留互相关点的原始采样密度，细节最多、噪声也最明显' ;;
        4) recommendation='默认推荐，细节、平滑程度和文件大小较均衡' ;;
        12) recommendation='粗密度概览，聚合更强、散点更少，但空间细节会损失' ;;
    esac
    printf '  factor=%-2s -> %s x %s = %s nodes; spacing~%s x %s px; %s\n' \
        "$recommended_factor" "$recommended_nx" "$recommended_ny" \
        "$recommended_total" "$recommended_range_spacing" \
        "$recommended_azimuth_spacing" "$recommendation"
done
printf '  Note: factor only changes Run4 blockmedian/gridding; it does not change freq_xcorr.dat.\n\n'
printf 'Minimum SNR:         %s (freq_xcorr.dat column 5)\n' "$min_corr"
if awk -v value="$max_abs_offset" 'BEGIN {exit !(value > 0)}'; then
    printf 'Maximum abs offset:  %s pixels\n' "$max_abs_offset"
else
    printf 'Maximum abs offset:  disabled\n'
fi
printf 'Pixel size / 单像素大小:\n'
printf '  azimuth:           %s m/pixel\n' "$azi_pixel_size_display"
printf '  slant range:       %s m/pixel\n' "$range_pixel_size_display"
printf 'Output subdirectory: %s\n' "$output_dir"
if (( keep_intermediate == 1 )); then
    printf 'Output mode:         full (final products plus intermediate files)\n'
else
    printf 'Output mode:         compact (final products only)\n'
fi
printf '\nComponents read from freq_xcorr.dat:\n'
printf '  column 2 -> range offset (pixels)\n'
printf '  column 4 -> azimuth offset (pixels)\n'
printf '  column 5 -> SNR used as threshold and block weight\n'
printf '\nExpected final products / 预计保留的最终文件:\n'
printf '  azimuth_offset_ll_m.grd          azimuth displacement in metres\n'
printf '  range_offset_ll_m.grd            slant-range displacement in metres\n'
printf '  PDF maps:                azimuth_offset_ll.pdf, range_offset_ll.pdf\n'
printf '  Google Earth azimuth:    azimuth_offset_ll_google.png/.kml/.kmz plus vertical colorbar\n'
printf '  Google Earth range:      range_offset_ll_google.png/.kml/.kmz plus vertical colorbar\n'
printf '  Processing notes:        README_outputs.txt\n'
if (( keep_intermediate == 1 )); then
    printf '  Intermediate files:      radar/pixel grids, filtered tables, projected XYZ and CPT files\n'
else
    printf '  Intermediate files:      removed after successful completion (use --keep-intermediate to retain)\n'
fi

if [[ -d $output_dir ]]; then
    printf '\nExisting Run4 output: YES\n'
else
    printf '\nExisting Run4 output: NO\n'
fi

if (( execute_run == 0 )); then
    printf '\nPreview only. freq_xcorr.dat was not modified.\n'
    if [[ -d $output_dir ]]; then
        printf 'To replace only the existing Run4 products, run:\n'
        printf '  ./run4_make_range_azimuth_grids_and_plots.sh 1 --factor %s --replace%s\n' \
            "$aggregate_factor" "$keep_option"
    else
        printf 'To generate both component maps, run:\n'
        printf '  ./run4_make_range_azimuth_grids_and_plots.sh 1 --factor %s%s\n' \
            "$aggregate_factor" "$keep_option"
    fi
    exit 0
fi

for command_name in gmt proj_ra2ll_ascii.csh zip; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        printf 'ERROR: required command not found: %s\n' "$command_name" >&2
        exit 5
    fi
done

if [[ -d $output_dir ]]; then
    if (( replace_existing == 0 )); then
        printf 'ERROR: Run4 output already exists and was not changed:\n' >&2
        printf '  %s\n' "$output_dir" >&2
        printf 'Use 1 --replace only for an intentional Run4 rerun.\n' >&2
        exit 6
    fi
    expected_output_dir=$project_dir/offset/intf/$pair_name/azi_offset/offset_components
    if [[ $output_dir != "$expected_output_dir" ]]; then
        printf 'ERROR: refusing to remove unexpected path: %s\n' "$output_dir" >&2
        exit 6
    fi
    find "$output_dir" -depth -delete
fi
mkdir -p "$output_dir"
cd "$output_dir"

printf '\nExtracting range and azimuth components...\n'
awk -v range_out=range_offset_points.dat \
    -v azimuth_out=azimuth_offset_points.dat \
    -v min_corr="$min_corr" \
    -v max_abs="$max_abs_offset" '
    function abs(v) { return v < 0 ? -v : v }
    NF >= 5 && $1 == $1 && $2 == $2 && $3 == $3 && $4 == $4 && $5 == $5 {
        if ($5 <= min_corr) next
        if (max_abs <= 0 || abs($2) <= max_abs)
            print $1, $3, $2, $5 > range_out
        if (max_abs <= 0 || abs($4) <= max_abs)
            print $1, $3, $4, $5 > azimuth_out
    }
' "$freq_file"

kept_range=$(wc -l < range_offset_points.dat)
kept_azimuth=$(wc -l < azimuth_offset_points.dat)
if (( kept_range == 0 || kept_azimuth == 0 )); then
    printf 'ERROR: no points remain after filtering.\n' >&2
    exit 7
fi
printf 'Retained points: range=%d  azimuth=%d\n' \
    "$kept_range" "$kept_azimuth"

read -r xmin xmax ymin ymax _ < <(
    gmt info range_offset_points.dat azimuth_offset_points.dat -C
)
base_xinc=$(awk -v max="$xmax" -v min="$xmin" -v count="$nx" \
    'BEGIN {v=int((max-min)/(count-1)); if (v < 1) v=1; print v}')
base_yinc=$(awk -v max="$ymax" -v min="$ymin" -v count="$ny" \
    'BEGIN {v=int((max-min)/(count-1)); if (v < 1) v=1; print v}')
xinc=$((base_xinc * aggregate_factor))
yinc=$((base_yinc * aggregate_factor))
radar_region=$(gmt info range_offset_points.dat azimuth_offset_points.dat \
    -I"$xinc"/"$yinc")
printf 'Radar grid increment: x=%s  y=%s pixels\n' "$xinc" "$yinc"
printf 'Radar grid region:    %s\n' "$radar_region"

gmt blockmedian range_offset_points.dat $radar_region \
    -I"$xinc"/"$yinc" -Wi | \
    awk '{print $1, $2, $3}' > range_offset_blockmedian.dat
gmt blockmedian azimuth_offset_points.dat $radar_region \
    -I"$xinc"/"$yinc" -Wi | \
    awk '{print $1, $2, $3}' > azimuth_offset_blockmedian.dat

gmt xyz2grd range_offset_blockmedian.dat $radar_region \
    -I"$xinc"/"$yinc" -Grange_offset_ra_px.grd
gmt xyz2grd azimuth_offset_blockmedian.dat $radar_region \
    -I"$xinc"/"$yinc" -Gazimuth_offset_ra_px.grd

printf 'Projecting block-median points to longitude/latitude...\n'
project_ra_points() {
    local input_file=$1
    local output_file=$2
    local project_status

    set +e
    proj_ra2ll_ascii.csh "$trans_file" "$input_file" "$output_file"
    project_status=$?
    set -e

    # Some GMTSAR/csh versions return nonzero after successful grdtrack because
    # their final cleanup glob has no matches ("rm: No match.").  The actual
    # output file is the reliable success criterion.
    if [[ ! -s $output_file ]]; then
        printf 'ERROR: geocoding did not create a non-empty file: %s\n' \
            "$output_file" >&2
        printf 'proj_ra2ll_ascii.csh exit status: %s\n' "$project_status" >&2
        exit 8
    fi
    if (( project_status != 0 )); then
        printf 'WARNING: proj_ra2ll_ascii.csh returned %s after creating %s; continuing.\n' \
            "$project_status" "$output_file" >&2
    fi
}

project_ra_points range_offset_blockmedian.dat range_offset_ll.xyz
project_ra_points azimuth_offset_blockmedian.dat azimuth_offset_ll.xyz

read -r lon_min lon_max lat_min lat_max _ < <(
    gmt info range_offset_ll.xyz azimuth_offset_ll.xyz -C -fg
)
radar_cells_x=$(awk -v max="$xmax" -v min="$xmin" -v inc="$xinc" \
    'BEGIN {v=int((max-min)/inc+0.5); if (v < 1) v=1; print v}')
radar_cells_y=$(awk -v max="$ymax" -v min="$ymin" -v inc="$yinc" \
    'BEGIN {v=int((max-min)/inc+0.5); if (v < 1) v=1; print v}')
lon_inc=$(awk -v max="$lon_max" -v min="$lon_min" -v n="$radar_cells_x" \
    'BEGIN {printf "%.12g", (max-min)/n}')
lat_inc=$(awk -v max="$lat_max" -v min="$lat_min" -v n="$radar_cells_y" \
    'BEGIN {printf "%.12g", (max-min)/n}')
geo_region=$(gmt info range_offset_ll.xyz azimuth_offset_ll.xyz \
    -I"$lon_inc"/"$lat_inc" -fg)
geo_radius=$(awk -v x="$lon_inc" -v y="$lat_inc" \
    'BEGIN {m=(x>y?x:y); printf "%.12g", 1.8*m}')

gmt nearneighbor range_offset_ll.xyz $geo_region -fg \
    -I"$lon_inc"/"$lat_inc" -S"$geo_radius"d -N1 \
    -Grange_offset_ll_px.grd
gmt nearneighbor azimuth_offset_ll.xyz $geo_region -fg \
    -I"$lon_inc"/"$lat_inc" -S"$geo_radius"d -N1 \
    -Gazimuth_offset_ll_px.grd

if [[ -n $azi_pixel_size ]]; then
    gmt grdmath azimuth_offset_ra_px.grd "$azi_pixel_size" MUL \
        = azimuth_offset_ra_m.grd
    gmt grdmath azimuth_offset_ll_px.grd "$azi_pixel_size" MUL \
        = azimuth_offset_ll_m.grd
fi
if [[ -n $range_pixel_size ]]; then
    gmt grdmath range_offset_ra_px.grd "$range_pixel_size" MUL \
        = range_offset_ra_m.grd
    gmt grdmath range_offset_ll_px.grd "$range_pixel_size" MUL \
        = range_offset_ll_m.grd
fi

plot_component() {
    local grid_file=$1
    local output_name=$2
    local title=$3
    local unit_label=$4
    local cpt_file=${output_name}.cpt
    local google_name=${output_name}_google
    local zmin zmax zabs zinc

    read -r _ _ _ _ _ zmin zmax _ < <(gmt grdinfo "$grid_file" -C)
    zabs=$(awk -v min="$zmin" -v max="$zmax" '
        BEGIN {
            a=(min<0?-min:min); b=(max<0?-max:max); v=(a>b?a:b)
            if (v <= 0) v=1
            printf "%.12g", v
        }')
    zinc=$(awk -v limit="$zabs" 'BEGIN {printf "%.12g", 2*limit/30}')
    gmt makecpt -Cpolar -T-"$zabs"/"$zabs"/"$zinc" -Z -D > "$cpt_file"

    # Publication/viewing map: axes, title, DEM background, and bottom colorbar.
    gmt begin "$output_name" pdf
        gmt grdimage "$dem_file" -R"$grid_file" -JM15c -Cgray -I+d
        gmt grdimage "$grid_file" -R"$grid_file" -JM15c -C"$cpt_file" -Q
        gmt basemap -R"$grid_file" -JM15c -Baf -BWSne+t"$title"
        gmt colorbar -C"$cpt_file" -DJBC+w10c/0.5c+h+e+o0/0.9c \
            -Bxaf -By+l"$unit_label"
    gmt end

    # Google Earth overlay: geographic image only, with NaN cells transparent.
    # A linear lon/lat projection makes the raster match a KML LatLonBox.
    gmt grdimage "$grid_file" -R"$grid_file" -JX15c \
        -C"$cpt_file" -Q -E300 -A"${google_name}.png"

    # Standalone vertical legend for a KML ScreenOverlay.  It stays fixed on
    # the Google Earth screen and is not baked into the geographic PNG.
    gmt begin "${google_name}_colorbar" png
        gmt basemap -R0/1/0/1 -JX2.5c/9c -B0
        gmt colorbar -C"$cpt_file" \
            -Dx1.25c/4.5c+w7c/0.55c+v+e+jMC \
            -Baf+l"$unit_label"
    gmt end
}

make_google_earth_product() {
    local grid_file=$1
    local output_name=$2
    local title=$3
    local description=$4
    local google_name=${output_name}_google
    local west east south north

    read -r _ west east south north _ < <(gmt grdinfo "$grid_file" -C)
    {
        printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'
        printf '%s\n' '<kml xmlns="http://www.opengis.net/kml/2.2">'
        printf '  <Document><name>%s</name>\n' "$title"
        printf '    <description>%s</description>\n' "$description"
        printf '    <GroundOverlay><name>%s</name><visibility>1</visibility>\n' "$title"
        printf '      <Icon><href>%s.png</href></Icon>\n' "$google_name"
        printf '%s\n' '      <LatLonBox>'
        printf '        <north>%s</north><south>%s</south>\n' "$north" "$south"
        printf '        <east>%s</east><west>%s</west>\n' "$east" "$west"
        printf '%s\n' '      </LatLonBox>'
        printf '%s\n' '    </GroundOverlay>'
        printf '    <ScreenOverlay><name>%s colorbar</name><visibility>1</visibility>\n' "$title"
        printf '      <Icon><href>%s_colorbar.png</href></Icon>\n' "$google_name"
        printf '%s\n' '      <overlayXY x="1" y="0" xunits="fraction" yunits="fraction"/>'
        printf '%s\n' '      <screenXY x="0.98" y="0.05" xunits="fraction" yunits="fraction"/>'
        printf '%s\n' '      <size x="0" y="0.35" xunits="fraction" yunits="fraction"/>'
        printf '%s\n' '    </ScreenOverlay>'
        printf '%s\n' '  </Document>'
        printf '%s\n' '</kml>'
    } > "${google_name}.kml"

    zip -q -j "${google_name}.kmz" \
        "${google_name}.kml" \
        "${google_name}.png" \
        "${google_name}_colorbar.png"
}

if [[ -f azimuth_offset_ll_m.grd ]]; then
    plot_component azimuth_offset_ll_m.grd azimuth_offset_ll \
        'Azimuth offset' 'm'
    make_google_earth_product azimuth_offset_ll_m.grd azimuth_offset_ll \
        'Azimuth offset' 'Azimuth offset in metres.'
else
    plot_component azimuth_offset_ll_px.grd azimuth_offset_ll \
        'Azimuth offset' 'pixel'
fi
if [[ -f range_offset_ll_m.grd ]]; then
    plot_component range_offset_ll_m.grd range_offset_ll \
        'Range offset' 'm'
    make_google_earth_product range_offset_ll_m.grd range_offset_ll \
        'Range offset' 'Slant-range offset in metres.'
else
    plot_component range_offset_ll_px.grd range_offset_ll \
        'Range offset' 'pixel'
fi
{
    printf 'Run4 source: %s\n' "$freq_file"
    printf 'Input columns: range_position range_offset azimuth_position azimuth_offset SNR\n'
    printf 'Retained points: %s\n' "$kept_range"
    printf 'Minimum SNR (column 5): %s\n' "$min_corr"
    printf 'Maximum absolute offset filter: %s (0 means disabled)\n' "$max_abs_offset"
    printf 'Aggregation factor: %s\n' "$aggregate_factor"
    if (( keep_intermediate == 1 )); then
        printf 'Output mode: full; intermediate files retained\n'
    else
        printf 'Output mode: compact; reproducible intermediate files removed\n'
    fi
    printf 'Radar increment: %s x %s pixels\n' "$xinc" "$yinc"
    printf 'Azimuth pixel size: %s m\n' "${azi_pixel_size:-unavailable}"
    printf 'Range pixel size: %s m (slant range)\n\n' \
        "${range_pixel_size:-unavailable}"
    printf 'Final grids:\n'
    printf '  azimuth_offset_ll_m.grd (when PRM values are available)\n'
    printf '  range_offset_ll_m.grd (slant range; when rng_samp_rate is available)\n'
    printf '  azimuth_offset_ll.pdf and range_offset_ll.pdf\n'
    printf '  azimuth_offset_ll_google.png/.kml/.kmz and azimuth_offset_ll_google_colorbar.png\n'
    printf '  range_offset_ll_google.png/.kml/.kmz and range_offset_ll_google_colorbar.png\n'
} > README_outputs.txt

if (( keep_intermediate == 0 )); then
    printf 'Removing reproducible intermediate files...\n'
    rm -f -- \
        range_offset_points.dat \
        azimuth_offset_points.dat \
        range_offset_blockmedian.dat \
        azimuth_offset_blockmedian.dat \
        range_offset_ll.xyz \
        azimuth_offset_ll.xyz \
        raln \
        ralt \
        raln.grd \
        ralt.grd \
        gmt.history \
        range_offset_ra_px.grd \
        azimuth_offset_ra_px.grd \
        azimuth_offset_ra_m.grd \
        range_offset_ra_m.grd \
        azimuth_offset_ll.cpt \
        range_offset_ll.cpt

    # Retain pixel-unit geographic grids only as fallbacks when the equivalent
    # metre grid could not be created from the PRM values.
    if [[ -f azimuth_offset_ll_m.grd ]]; then
        rm -f -- azimuth_offset_ll_px.grd
    fi
    if [[ -f range_offset_ll_m.grd ]]; then
        rm -f -- range_offset_ll_px.grd
    fi
fi

printf '\n===== Run4 complete / 完成 =====\n'
printf 'Output directory: %s\n' "$output_dir"
printf 'Azimuth PDF:      %s/azimuth_offset_ll.pdf\n' "$output_dir"
printf 'Range PDF:        %s/range_offset_ll.pdf\n' "$output_dir"
printf 'Azimuth KMZ:      %s/azimuth_offset_ll_google.kmz\n' "$output_dir"
printf 'Range KMZ:        %s/range_offset_ll_google.kmz\n' "$output_dir"
printf 'Output notes:     %s/README_outputs.txt\n' "$output_dir"

printf '\n===== Next step / 下一步：Run5 =====\n'
printf 'Preview the actual GRD cell size and all recommended filter profiles:\n'
printf '  ./run5_filter_offset_grids.sh\n'
printf 'After choosing a profile, for example run the balanced default:\n'
printf '  ./run5_filter_offset_grids.sh 1 --profile balanced\n'
