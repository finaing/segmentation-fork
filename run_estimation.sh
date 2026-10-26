#!/usr/bin/bash -l
#
# Submits one project_to_pose.sh job per project and, with --segment, a
# project_to_segments.sh job per project that starts once the pose job has
# ended. With --segment-only, only the segmentation jobs are submitted (e.g. to
# resubmit one that ran out of time).
#
# Each job gets the QOS its time limit needs: normal up to 24 hours, medium up
# to 48 hours, long up to 7 days. With --parts, a project's pose estimation is
# split over a Slurm array of that many jobs (each with --cpus, --mem and
# --time, log <job name>_<part>.out); its segmentation job waits for all of them.
#
# Usage:
#   bash run_estimation.sh [--segment | --segment-only] [--cpus N] [--mem MEM] [--time TIME]
#       [--workers N] [--parts N] [--overwrite | --overwrite-before DATE]
#       [--seg-cpus N] [--seg-mem MEM] [--seg-time TIME] [PROJECT...]
#
#   --segment       also segment the pose files into EAFs once pose estimation
#                   has ended (whether or not every video succeeded: the
#                   segmentation job segments whatever pose files exist)
#   --segment-only  only segment the projects' existing pose files
#   --cpus          CPUs per pose job (default: 2). The job converts --cpus /
#                   --workers videos at once.
#   --mem           memory per pose job, as for sbatch --mem (default: 40G)
#   --time          time limit per pose job, as for sbatch --time (default: 12:00:00)
#   --workers       MediaPipe instances per video, passed on to project_to_pose.sh
#                   (default: 1; more than 1 changes the results, see there)
#   --parts         split each project's pose estimation over N array jobs
#                   (default: 1)
#   --overwrite     redo the projects' existing pose files (and so their EAFs).
#                   Prints the --overwrite-before time it uses: pass that instead
#                   when resubmitting, so files redone since are kept.
#   --overwrite-before DATE
#                   redo pose files (and EAFs) last written before DATE, passed on
#                   to project_to_pose.sh
#   --seg-cpus      CPUs per segmentation job (default: 2)
#   --seg-mem       memory per segmentation job (default: 16G)
#   --seg-time      time limit per segmentation job (default: 2:00:00)
#   PROJECT         project name as in the "project" column of PROJECTS_CSV (quote
#                   names with spaces, e.g. "Noah David"). Default: all projects
#                   in PROJECTS_CSV except those in EXCLUDED_PROJECTS below.
#
# Examples:
#   bash run_estimation.sh --cpus 8 --mem 200G --time 72:00:00 SMILE2 "Noah David"
#   bash run_estimation.sh --segment --cpus 8 --mem 32G --time 72:00:00 \
#       --seg-mem 64G --seg-time 12:00:00 SMILE2
#   bash run_estimation.sh --segment-only --seg-mem 16G SMILE2 "Noah David"
#   bash run_estimation.sh --segment --cpus 8 --mem 32G --time 12:00:00 --parts 10 \
#       --seg-cpus 8 --seg-mem 32G --seg-time 12:00:00 SMILE2
#   bash run_estimation.sh --segment --cpus 8 --mem 16G --time 1:00:00 --overwrite \
#       --seg-mem 4G --seg-time 1:00:00 SRT-1-Modellvideos
#
# Extra arguments for project_to_pose.sh (e.g. --additional-config) can be put
# in POSE_ARGS below.

# Run from this script's directory, so the relative paths below (and the
# ../project_dir_paths.csv default in project_to_pose.sh) resolve.
cd "$(dirname "$0")" || exit 1

module load miniforge3
source activate segamega || { echo "Could not activate conda env segamega" >&2; exit 1; }
# Ignore packages in ~/.local: its tensorflow needs protobuf >= 5, mediapipe
# 0.10.21 needs protobuf < 5, and mediapipe fails to import a broken tensorflow.
export PYTHONNOUSERSITE=1

PROJECTS_CSV="../project_dir_paths.csv"
POSE_ARGS=()
# Projects in PROJECTS_CSV left out when no PROJECT is given (they can still be
# named explicitly)
EXCLUDED_PROJECTS=(Justisigns)

usage() {
	echo "Usage: $0 [--segment | --segment-only] [--cpus N] [--mem MEM] [--time TIME]" \
		"[--workers N] [--parts N] [--overwrite | --overwrite-before DATE]" \
		"[--seg-cpus N] [--seg-mem MEM] [--seg-time TIME] [PROJECT...]" >&2
	exit 1
}

# qos TIME: prints the QOS a job with time limit TIME (as for sbatch --time:
# [D-]HH:MM:SS, [D-]HH:MM, D-HH, MM:SS or MM) needs, or fails if TIME is
# malformed or over 7 days
qos() {
	local t="$1" days=0 h=0 m=0 s=0 minutes
	if [[ $t == *-* ]]; then
		days="${t%%-*}"
		t="${t#*-}"
		IFS=: read -r h m s <<< "$t"
	else
		# Without days, one field is minutes and two are minutes:seconds
		case "$t" in
			*:*:*) IFS=: read -r h m s <<< "$t" ;;
			*:*) IFS=: read -r m s <<< "$t" ;;
			*) m="$t" ;;
		esac
	fi
	for n in "$days" "${h:-0}" "${m:-0}" "${s:-0}"; do
		[[ $n =~ ^[0-9]+$ ]] || return 1
	done
	minutes=$(( (10#$days * 24 + 10#${h:-0}) * 60 + 10#${m:-0} + (10#${s:-0} > 0) ))
	if [ "$minutes" -le $((24 * 60)) ]; then
		echo normal
	elif [ "$minutes" -le $((48 * 60)) ]; then
		echo medium
	elif [ "$minutes" -le $((7 * 24 * 60)) ]; then
		echo long
	else
		return 1
	fi
}

cpus=2
mem=40G
time=12:00:00
seg_cpus=2
seg_mem=16G
seg_time=2:00:00
workers=1
parts=1
overwrite=""
overwrite_before=""
segment=""
segment_only=""
projects=()
while [ $# -gt 0 ]; do
	case "$1" in
		--cpus) [ $# -ge 2 ] || usage; cpus="$2"; shift 2 ;;
		--mem) [ $# -ge 2 ] || usage; mem="$2"; shift 2 ;;
		--time) [ $# -ge 2 ] || usage; time="$2"; shift 2 ;;
		--workers) [ $# -ge 2 ] || usage; workers="$2"; shift 2 ;;
		--parts) [ $# -ge 2 ] || usage; parts="$2"; shift 2 ;;
		--overwrite) overwrite=1; shift ;;
		--overwrite-before) [ $# -ge 2 ] || usage; overwrite_before="$2"; shift 2 ;;
		--seg-cpus) [ $# -ge 2 ] || usage; seg_cpus="$2"; shift 2 ;;
		--seg-mem) [ $# -ge 2 ] || usage; seg_mem="$2"; shift 2 ;;
		--seg-time) [ $# -ge 2 ] || usage; seg_time="$2"; shift 2 ;;
		--segment) segment=1; shift ;;
		--segment-only) segment_only=1; shift ;;
		-*) usage ;;
		*) projects+=("$1"); shift ;;
	esac
done
for n in "$cpus" "$seg_cpus" "$workers" "$parts"; do
	case "$n" in
		''|*[!0-9]*|0) echo "--cpus, --seg-cpus, --workers and --parts must be positive integers: $n" >&2; exit 1 ;;
	esac
done
if [ -n "$overwrite" ] && [ -n "$overwrite_before" ]; then
	echo "--overwrite and --overwrite-before can't be combined" >&2
	exit 1
fi
if [ -n "$overwrite" ]; then
	overwrite_before=$(date '+%Y-%m-%d %H:%M:%S')
	echo "Redoing pose files written before $overwrite_before;" \
		"to resubmit, use --overwrite-before \"$overwrite_before\" instead of --overwrite"
fi
if [ -n "$overwrite_before" ] && ! date -d "$overwrite_before" > /dev/null 2>&1; then
	echo "--overwrite-before isn't a date: $overwrite_before" >&2
	exit 1
fi
pose_args=(--workers "$workers")
[ -n "$overwrite_before" ] && pose_args+=(--overwrite-before "$overwrite_before")
array=()
if [ "$parts" -gt 1 ]; then
	# One log per part; the default %x.out would have all parts write to one file
	array=(--array="0-$((parts - 1))" --output="%x_%a.out")
	pose_args+=(--parts "$parts")
fi
if [ -n "$segment" ] && [ -n "$segment_only" ]; then
	echo "--segment and --segment-only can't be combined" >&2
	exit 1
fi
qos=$(qos "$time") || { echo "--time must be a Slurm time of at most 7 days: $time" >&2; exit 1; }
seg_qos=$(qos "$seg_time") || { echo "--seg-time must be a Slurm time of at most 7 days: $seg_time" >&2; exit 1; }

if [ ${#projects[@]} -eq 0 ]; then
	mapfile -t projects < <(awk -F, -v excluded="$(printf '%s\n' "${EXCLUDED_PROJECTS[@]}")" '
		BEGIN { n = split(excluded, e, "\n"); for (i = 1; i <= n; i++) skip[e[i]] = 1 }
		{ sub(/\r$/, "") }
		NR > 1 && $1 != "" && !($1 in skip) { print $1 }' "$PROJECTS_CSV")
fi

status=0
for project in "${projects[@]}"; do
	pose_job=""
	if [ -z "$segment_only" ]; then
		# --parsable prints just the job ID (plus ";cluster" on multi-cluster setups)
		pose_job=$(sbatch --parsable "${array[@]}" --job-name="${project// /_}_videos_to_poses" \
			--cpus-per-task="$cpus" --mem="$mem" --time="$time" --qos="$qos" \
			project_to_pose.sh --project "$project" --csv "$PROJECTS_CSV" \
			"${pose_args[@]}" "${POSE_ARGS[@]}") || { status=1; continue; }
		pose_job="${pose_job%%;*}"
		echo "$project: pose job $pose_job ($qos${array:+, $parts parts})"
	fi
	if [ -n "$segment" ] || [ -n "$segment_only" ]; then
		# afterany, not afterok: the pose job also fails when a single video
		# fails or it runs out of time, and the pose files it did write should
		# still be segmented. For an array, it waits for every part.
		dependency=()
		[ -n "$pose_job" ] && dependency=(--dependency="afterany:$pose_job")
		seg_job=$(sbatch --parsable "${dependency[@]}" --job-name="${project// /_}_poses_to_segments" \
			--cpus-per-task="$seg_cpus" --mem="$seg_mem" --time="$seg_time" --qos="$seg_qos" \
			project_to_segments.sh --project "$project" --csv "$PROJECTS_CSV") || { status=1; continue; }
		echo "$project: segmentation job ${seg_job%%;*} ($seg_qos)${pose_job:+ after $pose_job}"
	fi
done
exit $status
