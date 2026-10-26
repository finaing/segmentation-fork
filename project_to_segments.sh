#!/usr/bin/bash -l
#SBATCH --job-name=poses_to_segments
#SBATCH --cpus-per-task=2
#SBATCH --mem=16G
#SBATCH --time=12:00:00
#SBATCH --output=%x.out
#
# Segments a project's pose files (from project_to_pose.sh) into signs and
# sentences with pose_to_segments, writing one ELAN file per pose file to
# <share_path>/pose/auto_segmented/<name>.eaf. share_path per project is read
# from PROJECTS_CSV. Each EAF links the pose file and, if found, the video it
# was estimated from (<share_path>/<name>.mp4 or .mov, any case). Pose files
# that already have an EAF are skipped, so a job that ran out of time can just
# be resubmitted.
#
# Usage:
#   sbatch --job-name=SMILE2_poses_to_segments project_to_segments.sh --project SMILE2 \
#       [--csv PATH] [--model PATH]
#
#   --project  project name as in the "project" column of PROJECTS_CSV
#   --csv      path to PROJECTS_CSV (default: ../project_dir_paths.csv,
#              relative to the directory sbatch was run from)
#   --model    model directory (safetensors) or .ckpt file, passed on to
#              pose_to_segments (default: the model shipped with the package)

PROJECTS_CSV="../project_dir_paths.csv"
SHARE_PREFIX="/shares/sign-language.ebling.cl.uzh/"

usage() {
	echo "Usage: $0 --project PROJECT [--csv PATH] [--model PATH]" >&2
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
segment_args=()
while [ $# -gt 0 ]; do
	case "$1" in
		--project) [ $# -ge 2 ] || usage; project="$2"; shift 2 ;;
		--csv) [ $# -ge 2 ] || usage; PROJECTS_CSV="$2"; shift 2 ;;
		--model) [ $# -ge 2 ] || usage; segment_args+=(--model "$2"); shift 2 ;;
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
eaf_dir="$pose_dir/auto_segmented"
if [ ! -d "$pose_dir" ]; then
	echo "Not a directory: $pose_dir (run project_to_pose.sh first)" >&2
	exit 1
fi
mkdir -p "$eaf_dir" || exit 1

module load miniforge3
source activate segamega || { echo "Could not activate conda env segamega" >&2; exit 1; }
# Ignore packages in ~/.local: its tensorflow needs protobuf >= 5, mediapipe
# 0.10.21 needs protobuf < 5, and mediapipe fails to import a broken tensorflow.
export PYTHONNOUSERSITE=1

echo "$project: $pose_dir/ -> $eaf_dir/"
done_count=0
skip_count=0
fail_count=0
no_video_count=0
# Time spent in pose_to_segments on successful segmentations, for the average
segment_seconds=0
start_time=$(date +%s)
while IFS= read -r -d '' pose; do
	name=$(basename "$pose" .pose)
	eaf="$eaf_dir/$name.eaf"
	if [ -s "$eaf" ]; then
		skip_count=$((skip_count + 1))
		continue
	fi

	# The video the pose was estimated from (pose files are named after it)
	video=$(find "$video_dir" -maxdepth 1 -xtype f \( -iname "$name.mp4" -o -iname "$name.mov" \) -print -quit)
	video_args=()
	if [ -n "$video" ]; then
		video_args=(--video "$video")
	else
		echo "No video found for $name, EAF links only the pose file" >&2
		no_video_count=$((no_video_count + 1))
	fi

	file_start=$(date +%s)
	# Write to a temp file first, so a run killed mid-file doesn't leave a
	# partial .eaf that would be skipped next time.
	if pose_to_segments "${segment_args[@]}" "${video_args[@]}" --pose "$pose" --elan "$eaf.tmp" &&
		mv "$eaf.tmp" "$eaf"; then
		elapsed=$(($(date +%s) - file_start))
		segment_seconds=$((segment_seconds + elapsed))
		done_count=$((done_count + 1))
		echo "$(hms "$elapsed")  $name"
	else
		echo "FAILED after $(hms $(($(date +%s) - file_start))): $pose" >&2
		rm -f "$eaf.tmp"
		fail_count=$((fail_count + 1))
	fi
done < <(find "$pose_dir" -maxdepth 1 -type f -name '*.pose' -print0 | LC_ALL=C sort -z)

echo "$project: $done_count segmented, $skip_count already done, $fail_count failed, $no_video_count without video"
echo "Total time: $(hms $(($(date +%s) - start_time)))"
if [ "$done_count" -gt 0 ]; then
	echo "Average per segmented pose file: $(hms $((segment_seconds / done_count)))"
fi
[ "$fail_count" -eq 0 ]
