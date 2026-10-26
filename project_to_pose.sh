#!/usr/bin/bash -l
#SBATCH --job-name=videos_to_poses
#SBATCH --cpus-per-task=2
#SBATCH --mem=80G
#SBATCH --time=24:00:00
#SBATCH --output=%x_%j.out
#
# Converts a project's videos (.mp4 and .mov, any case) in its share_path to
# MediaPipe pose files in <share_path>/pose/<video name>.pose. share_path per
# project is read from PROJECTS_CSV. Videos that already have a pose file are
# skipped, so a job that ran out of time can just be resubmitted.
#
# Usage:
#   sbatch --job-name=SMILE2_videos_to_poses project_to_pose.sh --project SMILE2 [--csv PATH]
#
#   --project  project name as in the "project" column of PROJECTS_CSV
#   --csv      path to PROJECTS_CSV (default: project_dir_paths.csv in the
#              directory sbatch was run from)

PROJECTS_CSV="project_dir_paths.csv"
SHARE_PREFIX="/shares/sign-language.ebling.cl.uzh/"

usage() {
	echo "Usage: $0 --project PROJECT [--csv PATH]" >&2
	exit 1
}

# hms SECONDS: prints SECONDS as H:MM:SS
hms() {
	printf '%d:%02d:%02d' $(($1 / 3600)) $(($1 % 3600 / 60)) $(($1 % 60))
}

# csv_field PROJECT COLUMN: prints column COLUMN of PROJECT's row
csv_field() {
	awk -F, -v p="$1" -v c="$2" '{ sub(/\r$/, "") } NR > 1 && $1 == p { print $c; exit }' "$PROJECTS_CSV"
}

project=""
while [ $# -gt 0 ]; do
	case "$1" in
		--project) [ $# -ge 2 ] || usage; project="$2"; shift 2 ;;
		--csv) [ $# -ge 2 ] || usage; PROJECTS_CSV="$2"; shift 2 ;;
		*) usage ;;
	esac
done
[ -n "$project" ] || usage
[ -f "$PROJECTS_CSV" ] || { echo "Missing $PROJECTS_CSV" >&2; exit 1; }

share_path=$(csv_field "$project" 2)
if [ -z "$share_path" ]; then
	echo "Project not in $PROJECTS_CSV: $project" >&2
	exit 1
fi
video_dir=$(printf '%s/%s/' "$SHARE_PREFIX" "$share_path" | sed 's#//*#/#g')
pose_dir="${video_dir}pose"
if [ ! -d "$video_dir" ]; then
	echo "Not a directory: $video_dir" >&2
	exit 1
fi
mkdir -p "$pose_dir" || exit 1

module load miniforge3
source activate spoter-pose

echo "$project: $video_dir -> $pose_dir/"
done_count=0
skip_count=0
fail_count=0
# Time spent in video_to_pose on successful conversions, for the average
convert_seconds=0
start_time=$(date +%s)
while IFS= read -r -d '' video; do
	name=$(basename "$video")
	pose="$pose_dir/${name%.*}.pose"
	if [ -s "$pose" ]; then
		skip_count=$((skip_count + 1))
		continue
	fi
	video_start=$(date +%s)
	# Write to a temp file first, so a run killed mid-video doesn't leave a
	# partial .pose that would be skipped next time.
	if video_to_pose --format mediapipe -i "$video" -o "$pose.tmp" && mv "$pose.tmp" "$pose"; then
		elapsed=$(($(date +%s) - video_start))
		convert_seconds=$((convert_seconds + elapsed))
		done_count=$((done_count + 1))
		echo "$(hms "$elapsed")  $name"
	else
		echo "FAILED after $(hms $(($(date +%s) - video_start))): $video" >&2
		rm -f "$pose.tmp"
		fail_count=$((fail_count + 1))
	fi
done < <(find "$video_dir" -maxdepth 1 -type f \( -iname '*.mp4' -o -iname '*.mov' \) -print0 | LC_ALL=C sort -z)

echo "$project: $done_count converted, $skip_count already done, $fail_count failed"
echo "Total time: $(hms $(($(date +%s) - start_time)))"
if [ "$done_count" -gt 0 ]; then
	echo "Average per converted video: $(hms $((convert_seconds / done_count)))"
fi
[ "$fail_count" -eq 0 ]
