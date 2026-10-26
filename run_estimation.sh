#!/usr/bin/bash -l
#
# Submits one project_to_pose.sh job per project, or with --segment one
# project_to_segments.sh job per project.
#
# Usage:
#   ./run_estimation.sh [--segment] [--cpus N] [--mem MEM] [--time TIME] [PROJECT...]
#
#   --segment  segment the projects' existing pose files into EAFs
#              (project_to_segments.sh) instead of estimating poses
#   --cpus     CPUs per job, also used as project_to_pose.sh --workers (default: 2)
#   --mem      memory per job, as for sbatch --mem (default: 40G)
#   --time     time limit per job, as for sbatch --time (default: 12:00:00)
#   PROJECT    project name as in the "project" column of PROJECTS_CSV (quote
#              names with spaces, e.g. "Noah David"). Default: all projects
#              in PROJECTS_CSV.
#
# Examples:
#   ./run_estimation.sh --cpus 8 --mem 200G --time 72:00:00 SMILE2 "Noah David"
#   ./run_estimation.sh --segment --mem 16G SMILE2 "Noah David"
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

usage() {
	echo "Usage: $0 [--segment] [--cpus N] [--mem MEM] [--time TIME] [PROJECT...]" >&2
	exit 1
}

cpus=2
mem=40G
time=12:00:00
segment=""
projects=()
while [ $# -gt 0 ]; do
	case "$1" in
		--cpus) [ $# -ge 2 ] || usage; cpus="$2"; shift 2 ;;
		--mem) [ $# -ge 2 ] || usage; mem="$2"; shift 2 ;;
		--time) [ $# -ge 2 ] || usage; time="$2"; shift 2 ;;
		--segment) segment=1; shift ;;
		-*) usage ;;
		*) projects+=("$1"); shift ;;
	esac
done
case "$cpus" in
	''|*[!0-9]*|0) echo "--cpus must be a positive integer: $cpus" >&2; exit 1 ;;
esac

if [ ${#projects[@]} -eq 0 ]; then
	mapfile -t projects < <(awk -F, '{ sub(/\r$/, "") } NR > 1 && $1 != "" { print $1 }' "$PROJECTS_CSV")
fi

for project in "${projects[@]}"; do
	if [ -n "$segment" ]; then
		sbatch --job-name="${project// /_}_poses_to_segments" \
			--cpus-per-task="$cpus" --mem="$mem" --time="$time" \
			project_to_segments.sh --project "$project" --csv "$PROJECTS_CSV"
	else
		sbatch --job-name="${project// /_}_videos_to_poses" \
			--cpus-per-task="$cpus" --mem="$mem" --time="$time" \
			project_to_pose.sh --project "$project" --csv "$PROJECTS_CSV" \
			--workers "$cpus" "${POSE_ARGS[@]}"
	fi
done
