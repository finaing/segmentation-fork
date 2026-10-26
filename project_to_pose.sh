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
# Videos are converted one at a time with video_to_pose rather than with
# videos_to_poses, which can't write to a separate pose dir, only finds
# lowercase suffixes (.mp4, not .MP4) and asks for input on name collisions.
#
# Usage:
#   sbatch --job-name=SMILE2_videos_to_poses project_to_pose.sh --project SMILE2 \
#       [--csv PATH] [--workers N] [--additional-config CONFIG]
#
#   --project            project name as in the "project" column of PROJECTS_CSV
#   --csv                path to PROJECTS_CSV (default: ../project_dir_paths.csv,
#                        relative to the directory sbatch was run from)
#   --workers            parallel MediaPipe Holistic instances per video (default:
#                        the job's --cpus-per-task). Frames are dealt round-robin
#                        to the instances, so with N > 1 each instance only tracks
#                        every Nth frame; pass static_image_mode=true in
#                        --additional-config for results that don't depend on N.
#   --additional-config  passed on to video_to_pose, e.g.
#                        "model_complexity=2,refine_face_landmarks=true"

PROJECTS_CSV="../project_dir_paths.csv"
SHARE_PREFIX="/shares/sign-language.ebling.cl.uzh/"

usage() {
	echo "Usage: $0 --project PROJECT [--csv PATH] [--workers N] [--additional-config CONFIG]" >&2
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
# Not video_to_pose's own default of 0 (= all CPUs): that counts every CPU on
# the node, not just the ones allocated to the job.
workers="${SLURM_CPUS_PER_TASK:-1}"
additional_config=""
while [ $# -gt 0 ]; do
	case "$1" in
		--project) [ $# -ge 2 ] || usage; project="$2"; shift 2 ;;
		--csv) [ $# -ge 2 ] || usage; PROJECTS_CSV="$2"; shift 2 ;;
		--workers) [ $# -ge 2 ] || usage; workers="$2"; shift 2 ;;
		--additional-config) [ $# -ge 2 ] || usage; additional_config="$2"; shift 2 ;;
		*) usage ;;
	esac
done
[ -n "$project" ] || usage
case "$workers" in
	''|*[!0-9]*|0) echo "--workers must be a positive integer: $workers" >&2; exit 1 ;;
esac
pose_args=(--format mediapipe --workers "$workers")
[ -n "$additional_config" ] && pose_args+=(--additional-config "$additional_config")
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
echo "video_to_pose ${pose_args[*]}"
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
	if video_to_pose "${pose_args[@]}" -i "$video" -o "$pose.tmp" && mv "$pose.tmp" "$pose"; then
		elapsed=$(($(date +%s) - video_start))
		convert_seconds=$((convert_seconds + elapsed))
		done_count=$((done_count + 1))
		echo "$(hms "$elapsed")  $name"
	else
		echo "FAILED after $(hms $(($(date +%s) - video_start))): $video" >&2
		rm -f "$pose.tmp"
		fail_count=$((fail_count + 1))
	fi
# -xtype, not -type: the videos are mostly symlinks, and -xtype f matches both
# regular files and symlinks to them. Pose files are named after the link.
done < <(find "$video_dir" -maxdepth 1 -xtype f \( -iname '*.mp4' -o -iname '*.mov' \) -print0 | LC_ALL=C sort -z)

# Symlinks whose target is missing (-xtype l) can't be converted
broken_count=0
while IFS= read -r -d '' video; do
	echo "BROKEN LINK: $video -> $(readlink "$video")" >&2
	broken_count=$((broken_count + 1))
done < <(find "$video_dir" -maxdepth 1 -xtype l \( -iname '*.mp4' -o -iname '*.mov' \) -print0 | LC_ALL=C sort -z)

echo "$project: $done_count converted, $skip_count already done, $fail_count failed, $broken_count broken links"
echo "Total time: $(hms $(($(date +%s) - start_time)))"
if [ "$done_count" -gt 0 ]; then
	echo "Average per converted video: $(hms $((convert_seconds / done_count)))"
fi
[ "$fail_count" -eq 0 ]
