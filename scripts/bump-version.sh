#!/bin/bash
# Bump the app version and open a pull request for it.
#
# The version lives in the VERSION file at the repo root (the single source of
# truth; scripts/make-app.sh reads it into CFBundleShortVersionString and
# CFBundleVersion). Merging the resulting PR into main triggers
# .github/workflows/release.yml, which builds the .app and publishes a GitHub
# Release tagged v<version>.
#
# Usage:
#   scripts/bump-version.sh <new-version>   # e.g. 0.2.0
#   scripts/bump-version.sh patch|minor|major
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="${ROOT_DIR}/VERSION"
MAIN_BRANCH="main"

usage() {
	echo "Usage: $0 <new-version | patch | minor | major>" >&2
	exit 2
}

[ "$#" -eq 1 ] || usage
ARG="$1"

# --- Preconditions ---------------------------------------------------------
command -v gh >/dev/null 2>&1 || { echo "error: gh (GitHub CLI) is required" >&2; exit 1; }

CURRENT_BRANCH="$(git -C "${ROOT_DIR}" rev-parse --abbrev-ref HEAD)"
if [ "${CURRENT_BRANCH}" != "${MAIN_BRANCH}" ]; then
	echo "error: must be on '${MAIN_BRANCH}' (currently on '${CURRENT_BRANCH}')" >&2
	exit 1
fi

if ! git -C "${ROOT_DIR}" diff --quiet || ! git -C "${ROOT_DIR}" diff --cached --quiet; then
	echo "error: working tree is not clean; commit or stash changes first" >&2
	exit 1
fi

# --- Compute the new version ----------------------------------------------
CURRENT="$(tr -d '[:space:]' < "${VERSION_FILE}")"

case "${ARG}" in
	patch | minor | major)
		IFS='.' read -r MAJOR MINOR PATCH <<<"${CURRENT}"
		case "${ARG}" in
			major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
			minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
			patch) PATCH=$((PATCH + 1)) ;;
		esac
		NEW="${MAJOR}.${MINOR}.${PATCH}"
		;;
	*)
		if [[ ! "${ARG}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
			echo "error: '${ARG}' is not a valid version (expected X.Y.Z) or bump keyword" >&2
			usage
		fi
		NEW="${ARG}"
		;;
esac

if [ "${NEW}" = "${CURRENT}" ]; then
	echo "error: new version equals current version (${CURRENT})" >&2
	exit 1
fi

BRANCH="bump-version-v${NEW}"
if git -C "${ROOT_DIR}" rev-parse --verify "${BRANCH}" >/dev/null 2>&1; then
	echo "error: branch '${BRANCH}' already exists" >&2
	exit 1
fi

echo "==> Bumping version ${CURRENT} -> ${NEW}"

# --- Apply the change on a new branch -------------------------------------
git -C "${ROOT_DIR}" checkout -b "${BRANCH}"

printf '%s\n' "${NEW}" > "${VERSION_FILE}"

git -C "${ROOT_DIR}" add "${VERSION_FILE}"
git -C "${ROOT_DIR}" commit -m "chore: bump version to ${NEW}"

git -C "${ROOT_DIR}" push -u origin "${BRANCH}"

# --- Open the PR -----------------------------------------------------------
gh pr create \
	--base "${MAIN_BRANCH}" \
	--head "${BRANCH}" \
	--title "chore: bump version to ${NEW}" \
	--body "Bump version to \`${NEW}\`.

Merging this PR tags \`v${NEW}\` and publishes a GitHub Release via the release workflow."

echo "==> Done. Review and merge the PR to release v${NEW}."
