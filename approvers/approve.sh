#!/bin/bash

# This script will determine if a pull request of the
# given severity should be merging into a a specific
# target branch of a specific repository at this time.

if [[ $# -ne 3 ]]; then
	echo "[ERROR] Usage: $0 REPO BRANCH SEVERITY"
	exit 127
else
	repo="$1"
	branch="$2"
	severity="$3"
	if [[ ! -f "/var/lib/jenkins/approvers/openshift/${repo}/${branch}/approver" ]]; then
		echo "[ERROR] No approval criteria are configured for '${branch}' branch of '${repo}' repo." | tee -a "/var/lib/jenkins/approvers/denials.log"
		exit 0
	else
		if ! "/var/lib/jenkins/approvers/openshift/${repo}/${branch}/approver" "${severity}"; then
			result='approved'
		fi
		echo "[INF0] Pull request of '${severity}' severity would be ${result:-rejected} for merge into '${branch}' branch of '${repo}' repo." | tee -a "/var/lib/jenkins/approvers/denials.log"
		exit 0
	fi
fi
