#!/bin/bash

set -eo pipefail
set -o xtrace

# --- Configuration and Initialization ---
DRY_RUN=false
SKIP_CONFIRMATION=false
STORAGE_CLASS=""

# Displays usage information
usage() {
    echo "Usage: $0 --storage-class <sc-name> [--dry-run] [--yes]"
    echo
    echo "A script to find and delete Kubernetes Persistent Volumes (PVs) in the 'Released' state for a specific storage class."
    echo
    echo "Options:"
    echo "  --storage-class <sc-name>   The name of the storage class to target (required)."
    echo "  --dry-run                   List the PVs that would be deleted without actually deleting them."
    echo "  --yes                       Skip the interactive confirmation prompt. Use with caution."
    echo
    echo "WARNING: This script deletes Kubernetes resources. The underlying cloud storage"
    echo "         (e.g., Azure File Share) is NOT deleted and must be cleaned up manually."
}

# --- Argument Parsing ---
while [ "$#" -gt 0 ]; do
    case "$1" in
        --storage-class)
        STORAGE_CLASS="$2"
        shift 2
        ;;
        --dry-run)
        DRY_RUN=true
        shift
        ;;
        --yes)
        SKIP_CONFIRMATION=true
        shift
        ;;
        --help)
        usage
        exit 0
        ;;
        *)
        # Unknown option
        echo "Unknown option: $1"
        usage
        exit 1
        ;;
    esac
done

main() {
    # Check if the storage class was provided
    if [ -z "$STORAGE_CLASS" ]; then
        echo "ERROR: Storage class not specified. Use the --storage-class option."
        usage
        exit 1
    fi

    echo "INFO: Searching for Persistent Volumes in 'Released' state for storage class: ${STORAGE_CLASS}..."

    # Get the list of PVs in 'Released' state for the specified storage class.
    # We use --arg to safely pass the shell variable into the jq query.
    released_pvs=$(kubectl get pv -o json | jq --arg sc_name "$STORAGE_CLASS" -r '.items[] | select((.status.phase == "Released") and (.spec.storageClassName == $sc_name)) | .metadata.name')

    if [ -z "$released_pvs" ]; then
        echo "INFO: No PVs in 'Released' state found for storage class '${STORAGE_CLASS}'. Exiting."
        exit 0
    fi

    # Count the number of PVs found
    pv_count=$(echo "$released_pvs" | wc -l | tr -d ' ')

    echo "FOUND: ${pv_count} PV(s) in 'Released' state for storage class '${STORAGE_CLASS}':"
    echo "$released_pvs" | sed 's/^/ - /'
    echo

    if [ "$DRY_RUN" = "true" ]; then
        echo "DRY RUN: No PVs will be deleted. Exiting."
        exit 0
    fi

    if [ "$SKIP_CONFIRMATION" = "false" ]; then
        # Prompt for confirmation.
        printf "Are you sure you want to delete these %s PV(s)? This action cannot be undone. (y/N) " "$pv_count"
        read -r REPLY
        echo
        # Check if the reply does not start with 'y' or 'Y'
        if [[ ! "$REPLY" =~ ^[Yy] ]]; then
            echo "Aborted by user. Exiting."
            exit 1
        fi
    fi

    echo "INFO: Proceeding with deletion..."
    local deleted_count=0

    # Use process substitution to avoid the subshell problem.
    while IFS= read -r pv_name; do
        if [ -n "$pv_name" ]; then
            echo " -> Deleting PV: ${pv_name}..."
            if kubectl delete pv "$pv_name"; then
                deleted_count=$((deleted_count + 1))
            else
                echo "ERROR: Failed to delete PV: ${pv_name}. Please check manually."
            fi
        fi
    done < <(echo "$released_pvs")

    echo
    echo "SUMMARY: Successfully deleted ${deleted_count} of ${pv_count} PV(s)."
}

# --- Script Execution ---
main
