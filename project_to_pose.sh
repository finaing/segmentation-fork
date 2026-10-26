#!/usr/bin/bash -l
#SBATCH --job-name=videos_to_poses
#SBATCH --cpus-per-task=2
#SBATCH --mem=80G
#SBATCH --time=24:00:00
#SBATCH --output=%x.out
#
# Converts a project's videos (.mp4 and .mov, any case) in its share_path to
# MediaPipe pose files in <share_path>/pose/<video name>.pose. share_path per
# project is read from PROJECTS_CSV. Videos that already have a pose file are
# skipped (unless --overwrite-before says otherwise), so a job that ran out of
# time can just be resubmitted.
#
# Some projects only get poses for some camera perspectives (see the case
# statement before the conversion loop): SMILE2 only *_front, InterGaze only
# *_Camera_2 and *_Camera_3 (each its own pose file), searched in subdirectories
# too, SMILE, SMILE_2018 and SRT-2 only *_S1, using *_S1_aligned instead where
# a recording has one, and SMILE-Modellvideos only *_S1 or videos without a
# perspective suffix.
#
# Several videos are converted at once (--parallel), each by its own
# video_to_pose process, rather than with videos_to_poses, which can't write to
# a separate pose dir, only finds lowercase suffixes (.mp4, not .MP4) and asks
# for input on name collisions. A project can also be split over several jobs
# (--parts, e.g. as a Slurm array: run_estimation.sh --parts does this).
#
# Usage:
#   sbatch --job-name=SMILE2_videos_to_poses project_to_pose.sh --project SMILE2 \
#       [--csv PATH] [--workers N] [--parallel N] [--parts N [--part I]] \
#       [--overwrite-before DATE] [--additional-config CONFIG]
#
#   --project            project name as in the "project" column of PROJECTS_CSV
#   --csv                path to PROJECTS_CSV (default: ../project_dir_paths.csv,
#                        relative to the directory sbatch was run from)
#   --workers            MediaPipe Holistic instances per video (default: 1). With
#                        N > 1, frames are dealt round-robin to the instances, so
#                        each instance only tracks every Nth frame and results
#                        differ from N = 1 (unless static_image_mode=true is
#                        passed in --additional-config).
#   --parallel           videos converted at once (default: the job's
#                        --cpus-per-task divided by --workers)
#   --parts, --part      split the project's videos into N parts (every Nth
#                        video, so long and short videos mix) and convert only
#                        part I, 0-based (default: SLURM_ARRAY_TASK_ID, or 0)
#   --overwrite-before   also redo pose files last written before DATE (anything
#                        `date -d` understands, e.g. 2026-10-27 or "2026-10-27
#                        14:00"). Pose files written since are kept, so a job
#                        resubmitted with the same DATE carries on where it
#                        stopped.
#   --additional-config  passed on to video_to_pose, e.g.
#                        "model_complexity=2,refine_face_landmarks=true"

PROJECTS_CSV="../project_dir_paths.csv"
SHARE_PREFIX="/shares/sign-language.ebling.cl.uzh/"

usage() {
	echo "Usage: $0 --project PROJECT [--csv PATH] [--workers N] [--parallel N]" \
		"[--parts N [--part I]] [--overwrite-before DATE] [--additional-config CONFIG]" >&2
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

# positive_int NAME VALUE: exits with an error unless VALUE is a positive integer
positive_int() {
	case "$2" in
		''|*[!0-9]*|0) echo "$1 must be a positive integer: $2" >&2; exit 1 ;;
	esac
}

project=""
workers=1
parallel=""
parts=1
part="${SLURM_ARRAY_TASK_ID:-0}"
overwrite_before=""
additional_config=""
while [ $# -gt 0 ]; do
	case "$1" in
		--project) [ $# -ge 2 ] || usage; project="$2"; shift 2 ;;
		--csv) [ $# -ge 2 ] || usage; PROJECTS_CSV="$2"; shift 2 ;;
		--workers) [ $# -ge 2 ] || usage; workers="$2"; shift 2 ;;
		--parallel) [ $# -ge 2 ] || usage; parallel="$2"; shift 2 ;;
		--parts) [ $# -ge 2 ] || usage; parts="$2"; shift 2 ;;
		--part) [ $# -ge 2 ] || usage; part="$2"; shift 2 ;;
		--overwrite-before) [ $# -ge 2 ] || usage; overwrite_before="$2"; shift 2 ;;
		--additional-config) [ $# -ge 2 ] || usage; additional_config="$2"; shift 2 ;;
		*) usage ;;
	esac
done
[ -n "$project" ] || usage
positive_int --workers "$workers"
positive_int --parts "$parts"
case "$part" in
	''|*[!0-9]*) echo "--part must be a number from 0 to $((parts - 1)): $part" >&2; exit 1 ;;
esac
[ "$part" -lt "$parts" ] || { echo "--part must be a number from 0 to $((parts - 1)): $part" >&2; exit 1; }
# Not video_to_pose's own default of 0 (= all CPUs) for anything: that counts
# every CPU on the node, not just the ones allocated to the job.
if [ -z "$parallel" ]; then
	parallel=$(( ${SLURM_CPUS_PER_TASK:-1} / workers ))
	[ "$parallel" -ge 1 ] || parallel=1
fi
positive_int --parallel "$parallel"
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

# Logs of the running video_to_pose processes, the results they report, and the
# --overwrite-before timestamp
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/project_to_pose.XXXXXX") || exit 1
trap 'rm -rf "$tmp_dir"' EXIT
results="$tmp_dir/results"
: > "$results"
if [ -n "$overwrite_before" ]; then
	stamp="$tmp_dir/overwrite_before"
	touch -d "$overwrite_before" "$stamp" 2>/dev/null ||
		{ echo "--overwrite-before isn't a date: $overwrite_before" >&2; exit 1; }
fi

# Which videos get poses: depth limits the search to share_path itself unless a
# project keeps its videos in subdirectories, select narrows it to camera
# perspectives. Pose files are named after the video, so each perspective gets
# its own. With prefer_aligned, a video that also has an _aligned version
# (X_S1.mp4 next to X_S1_aligned.mp4) is skipped in favour of that version.
depth=(-maxdepth 1)
select=()
prefer_aligned=""
case "$project" in
	SMILE2) select=(-iname '*_front.*') ;;
	InterGaze)
		depth=()
		select=(\( -iname '*_Camera_2.*' -o -iname '*_Camera_3.*' \))
		;;
	SMILE|SMILE_2018|SRT-2)
		select=(\( -iname '*_S1.*' -o -iname '*_S1_aligned.*' \))
		prefer_aligned=1
		;;
	SMILE-Modellvideos)
		# Recordings filmed from several perspectives have _S1/_S2/_S7 videos,
		# the others a single video without a perspective suffix: keep both
		# kinds, drop every perspective but _S1.
		select=(\( -iname '*_S1.*' -o ! -iname '*_S[0-9]*.*' \))
		;;
esac

# find_videos TYPE: prints the selected videos, NUL-separated and sorted, that
# are (or link to) regular files (TYPE f) or are broken symlinks (TYPE l).
# -xtype, not -type: the videos are mostly symlinks, and -xtype f matches both
# regular files and symlinks to them.
find_videos() {
	find "$video_dir" "${depth[@]}" -path "$pose_dir" -prune -o \
		-xtype "$1" \( -iname '*.mp4' -o -iname '*.mov' \) "${select[@]}" -print0 |
		LC_ALL=C sort -z
}

# convert VIDEO POSE: runs video_to_pose on VIDEO, prints its time and frame
# count (from video_to_pose's progress bar) and appends "ok SECONDS" or "fail"
# to the results file. Runs in the background, so its output goes to a log
# that is only shown when it fails.
convert() {
	local video="$1" pose="$2" name start elapsed log frames
	name=$(basename "$video")
	log="$tmp_dir/$name.log"
	start=$(date +%s)
	# Write to a temp file first, so a run killed mid-video doesn't leave a
	# partial .pose that would be skipped next time.
	if video_to_pose "${pose_args[@]}" -i "$video" -o "$pose.tmp" > "$log" 2>&1 &&
		mv "$pose.tmp" "$pose"; then
		elapsed=$(($(date +%s) - start))
		frames=$(tr '\r' '\n' < "$log" | sed -n 's/^\([0-9][0-9]*\)it \[.*/\1/p' | tail -n 1)
		echo "$(hms "$elapsed")  $name${frames:+  ($frames frames)}"
		echo "ok $elapsed" >> "$results"
	else
		# With the last lines of the log, without progress bars and MediaPipe's
		# repeated feedback-tensor warning, printed at once so other videos'
		# output doesn't end up in between
		printf 'FAILED after %s: %s\n%s\n' "$(hms $(($(date +%s) - start)))" "$video" \
			"$(tr '\r' '\n' < "$log" | grep -v -e 'it \[' -e 'inference_feedback_manager' |
				tail -n 20 | sed 's/^/    /')" >&2
		rm -f "$pose.tmp"
		echo "fail" >> "$results"
	fi
	rm -f "$log"
}

module load miniforge3
source activate segamega || { echo "Could not activate conda env segamega" >&2; exit 1; }

label="$project"
[ "$parts" -gt 1 ] && label="$project (part $part of 0-$((parts - 1)))"
echo "$label: $video_dir -> $pose_dir/"
echo "video_to_pose ${pose_args[*]}, $parallel at once${overwrite_before:+, redoing pose files written before $overwrite_before}"
skip_count=0
aligned_count=0
index=-1
running=0
start_time=$(date +%s)
while IFS= read -r -d '' video; do
	index=$((index + 1))
	[ $((index % parts)) -eq "$part" ] || continue
	name=$(basename "$video")
	if [ -n "$prefer_aligned" ] && [ -n "$(find "$(dirname "$video")" -maxdepth 1 -xtype f \
		\( -iname "${name%.*}_aligned.mp4" -o -iname "${name%.*}_aligned.mov" \) -print -quit)" ]; then
		echo "Using _aligned version instead of $name"
		aligned_count=$((aligned_count + 1))
		continue
	fi
	# Pose files are named after the link, not its target
	pose="$pose_dir/${name%.*}.pose"
	if [ -s "$pose" ] && { [ -z "$overwrite_before" ] || [ "$pose" -nt "$stamp" ]; }; then
		skip_count=$((skip_count + 1))
		continue
	fi
	if [ "$running" -ge "$parallel" ]; then
		wait -n
		running=$((running - 1))
	fi
	convert "$video" "$pose" &
	running=$((running + 1))
done < <(find_videos f)
wait

# Symlinks whose target is missing (-xtype l) can't be converted. Reported by
# part 0 only, so a split project lists them once.
broken_count=0
if [ "$part" -eq 0 ]; then
	while IFS= read -r -d '' video; do
		echo "BROKEN LINK: $video -> $(readlink "$video")" >&2
		broken_count=$((broken_count + 1))
	done < <(find_videos l)
fi

done_count=$(grep -c '^ok ' "$results")
fail_count=$(grep -c '^fail' "$results")
# Time spent in video_to_pose on successful conversions, for the average
convert_seconds=$(awk '/^ok / { s += $2 } END { print s + 0 }' "$results")
echo "$label: $done_count converted, $skip_count already done, $fail_count failed, $broken_count broken links"
if [ -n "$prefer_aligned" ]; then
	echo "$aligned_count videos skipped for their _aligned version"
fi
echo "Total time: $(hms $(($(date +%s) - start_time)))"
if [ "$done_count" -gt 0 ]; then
	echo "Average per converted video: $(hms $((convert_seconds / done_count))) ($parallel at once)"
fi
[ "$fail_count" -eq 0 ]
