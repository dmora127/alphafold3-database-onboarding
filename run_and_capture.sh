#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FETCH_SCRIPT="$ROOT_DIR/fetch_databases.sh"
CAPTURE_SCRIPT="$ROOT_DIR/alphafold3-database-metadata-capture.sh"

DB_DIR=""
PARALLEL=""
EMAIL=""
SITE=""
METADATA_OUT=""
CHECKSUM_OUT=""
DATABASE_VERSION=""

usage() {
    cat <<EOF_USAGE
Usage:
  $(basename "$0") [OPTIONS]

Run database fetch and metadata capture in sequence.

Required options:
  --root PATH
  --parallel N
  --email EMAIL
  --site SITE

Optional options:
  --manifest-file PATH
  --checksum-file PATH
  --database-version VERSION
  -h, --help

If required options are omitted in an interactive terminal, you will be prompted.
EOF_USAGE
}

require_argument() {
    local option="$1"
    local value="${2:-}"

    if [[ -z "$value" || "$value" == --* ]]; then
        echo "ERROR: ${option} requires an argument." >&2
        exit 1
    fi
}

require_script() {
    local path="$1"
    local name="$2"

    if [[ ! -f "$path" ]]; then
        echo "ERROR: ${name} not found at: ${path}" >&2
        exit 1
    fi

    if [[ ! -r "$path" ]]; then
        echo "ERROR: ${name} is not readable: ${path}" >&2
        exit 1
    fi

    if [[ ! -x "$path" ]]; then
        echo "WARN: ${name} is not executable; invoking with bash: ${path}" >&2
    fi
}

require_script "$FETCH_SCRIPT" "fetch_databases.sh"
require_script "$CAPTURE_SCRIPT" "alphafold3-database-metadata-capture.sh"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --root)
            require_argument "$1" "${2:-}"
            DB_DIR="$2"
            shift 2
            ;;
        --parallel)
            require_argument "$1" "${2:-}"
            PARALLEL="$2"
            shift 2
            ;;
        --email)
            require_argument "$1" "${2:-}"
            EMAIL="$2"
            shift 2
            ;;
        --site)
            require_argument "$1" "${2:-}"
            SITE="$2"
            shift 2
            ;;
        --manifest-file)
            require_argument "$1" "${2:-}"
            METADATA_OUT="$2"
            shift 2
            ;;
        --checksum-file)
            require_argument "$1" "${2:-}"
            CHECKSUM_OUT="$2"
            shift 2
            ;;
        --database-version)
            require_argument "$1" "${2:-}"
            DATABASE_VERSION="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: unknown option: $1" >&2
            echo >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [[ -t 0 ]]; then
    echo "[run_and_capture] Capturing metadata inputs..."
    [[ -z "$DB_DIR" ]] && read -rp "Database root (--root): " DB_DIR
    [[ -z "$PARALLEL" ]] && read -rp "Parallel workers (--parallel): " PARALLEL
    [[ -z "$EMAIL" ]] && read -rp "Contact email (--email): " EMAIL
    [[ -z "$SITE" ]] && read -rp "Site/organization (--site): " SITE
fi

if [[ -z "$DB_DIR" || -z "$PARALLEL" || -z "$EMAIL" || -z "$SITE" ]]; then
    echo "ERROR: --root, --parallel, --email, and --site inputs are required." >&2
    exit 1
fi

if [[ -z "$METADATA_OUT" ]]; then
    default_manifest="${DB_DIR}/alphafold3-manifest.yml"
    if [[ -t 0 ]]; then
        read -rp "Manifest output (--manifest-file) [${default_manifest}]: " METADATA_OUT
    fi
    METADATA_OUT="${METADATA_OUT:-$default_manifest}"
fi

if [[ -z "$CHECKSUM_OUT" ]]; then
    default_checksum="${DB_DIR}/checksums.sha256"
    if [[ -t 0 ]]; then
        read -rp "Checksum output (--checksum-file) [${default_checksum}]: " CHECKSUM_OUT
    fi
    CHECKSUM_OUT="${CHECKSUM_OUT:-$default_checksum}"
fi

if [[ -t 0 && -z "$DATABASE_VERSION" ]]; then
    read -rp "Database version (--database-version, optional): " DATABASE_VERSION
fi

echo "[run_and_capture] Running fetch_databases.sh..."
bash "$FETCH_SCRIPT" "$DB_DIR"

echo "[run_and_capture] Running alphafold3-database-metadata-capture.sh..."
capture_cmd=(
    bash "$CAPTURE_SCRIPT"
    --root "$DB_DIR"
    --parallel "$PARALLEL"
    --email "$EMAIL"
    --site "$SITE"
    --manifest-file "$METADATA_OUT"
    --checksum-file "$CHECKSUM_OUT"
)

if [[ -n "$DATABASE_VERSION" ]]; then
    capture_cmd+=(--database-version "$DATABASE_VERSION")
fi

"${capture_cmd[@]}"

echo "[run_and_capture] Success: fetch and metadata capture completed."
