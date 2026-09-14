#!/usr/bin/env bash
set -euo pipefail

# Build a reproducible checksum manifest for the AlphaFold3 reference databases.
#
# Requirements:
#   - bash >= 4
#   - GNU coreutils (sha256sum, sort, awk, wc, tr, date, realpath, mktemp,
#     dirname, basename, chmod, mv)
#   - findutils (find, xargs)
#
# Optional:
#   - tqdm CLI (progress bar; a plain counter is used when unavailable)
#
# Required arguments:
#   --root PATH
#   --parallel N
#   --email EMAIL
#   --site SITE
#
# Optional arguments:
#   --checksum-file PATH
#   --manifest-file PATH
#   --database-version VERSION
#
# Example:
#
#   ./build_alphafold3_manifest_fixed.sh \
#       --root /alphafold3 \
#       --parallel 28 \
#       --email damorales4@wisc.edu \
#       --site CHTC
#
# Database version behavior:
#
#   If --database-version is explicitly supplied, that version is used.
#
#   Otherwise, a backwards-compatible content fingerprint is compared against
#   the known AlphaFold3 database release fingerprint. If it matches, the
#   database version is:
#
#     af3-dbs-2025-01
#
#   Any other dataset is treated as a unique database snapshot and assigned:
#
#     <site>-<date>-<last8ofhash>
#
#   Example:
#
#     CHTC-2026-09-14-2f62bc41
#
# Checksum behavior:
#
#   Each dataset file is hashed individually and recorded in checksums.sha256 as
#   a mapping of SHA-256 value to root-relative file path.
#
#   The authoritative dataset checksum is then calculated from the sorted list
#   of individual SHA-256 values only. File paths are intentionally excluded
#   from the composite dataset identity. This preserves compatibility with the
#   original AlphaFold3 database fingerprinting scheme.

export LC_ALL=C


###############################################################################
# Configuration
###############################################################################

# Required arguments. These intentionally have no defaults.
ROOT=""
PARALLEL=""
EMAIL=""
SITE=""

# Optional arguments.
CHECKSUM_FILE="checksums.sha256"
MANIFEST_FILE="alphafold3-manifest.yml"
DATABASE_VERSION=""

# Fallback progress report interval when tqdm is unavailable.
PROGRESS_EVERY=10000

# Known canonical AlphaFold3 database release.
KNOWN_DATABASE_HASH="5ba00c58f7c9a36a8bb7a6b7635408ced4a35d66d177f6f0794d7246f81dc177"
KNOWN_DATABASE_VERSION="af3-dbs-2025-01"


###############################################################################
# CLI
###############################################################################

usage() {
    cat <<EOF_USAGE
Usage:
  $(basename "$0") [OPTIONS]

Build a checksum manifest for an AlphaFold3 reference database installation.

Required options:

  --root PATH
      AlphaFold3 database root directory.

  --parallel N
      Number of mmCIF files to hash concurrently.

  --email EMAIL
      Email address of the user generating the manifest.
      Written to:
        provenance.generated_by_user

  --site SITE
      Site or organization generating the manifest.
      Written to:
        provenance.generated_by

Optional options:

  --checksum-file PATH
      Output file containing individual SHA-256 checksums.
      Default:
        checksums.sha256

  --manifest-file PATH
      Output YAML manifest.
      Default:
        alphafold3-manifest.yml

  --database-version VERSION
      Explicitly set the database version.

      If omitted, a backwards-compatible content fingerprint is compared
      against:

        ${KNOWN_DATABASE_HASH}

      A matching dataset is assigned:

        ${KNOWN_DATABASE_VERSION}

      A unique dataset is assigned:

        <site>-<date>-<last8ofhash>

  -h, --help
      Show this help message and exit.

Notes:

  The checksum and manifest output files must be outside --root. This prevents
  accidental truncation or modification of database inputs and keeps generated
  metadata separate from the dataset being identified.

  The checksum file maps each individual SHA-256 to its root-relative path.
  The composite dataset checksum is calculated from the sorted list of hashes
  only; file paths are intentionally excluded from the dataset identity.

Example:

  $(basename "$0") \
      --root /alphafold3 \
      --parallel 28 \
      --email damorales4@wisc.edu \
      --site CHTC

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


reject_newlines() {
    local option="$1"
    local value="$2"

    if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
        echo "ERROR: ${option} may not contain newline or carriage-return characters." >&2
        exit 1
    fi
}


while [[ $# -gt 0 ]]; do
    case "$1" in

        --root)
            require_argument "$1" "${2:-}"
            ROOT="$2"
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

        --checksum-file)
            require_argument "$1" "${2:-}"
            CHECKSUM_FILE="$2"
            shift 2
            ;;

        --manifest-file)
            require_argument "$1" "${2:-}"
            MANIFEST_FILE="$2"
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


###############################################################################
# Validate required CLI arguments
###############################################################################

MISSING_ARGS=()

[[ -z "$ROOT" ]]     && MISSING_ARGS+=("--root")
[[ -z "$PARALLEL" ]] && MISSING_ARGS+=("--parallel")
[[ -z "$EMAIL" ]]    && MISSING_ARGS+=("--email")
[[ -z "$SITE" ]]     && MISSING_ARGS+=("--site")

if (( ${#MISSING_ARGS[@]} > 0 )); then
    echo "ERROR: missing required argument(s): ${MISSING_ARGS[*]}" >&2
    echo >&2
    usage >&2
    exit 1
fi


###############################################################################
# Validate argument values
###############################################################################

if ! [[ "$PARALLEL" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: --parallel must be a positive integer." >&2
    exit 1
fi

reject_newlines "--root" "$ROOT"
reject_newlines "--email" "$EMAIL"
reject_newlines "--site" "$SITE"
reject_newlines "--checksum-file" "$CHECKSUM_FILE"
reject_newlines "--manifest-file" "$MANIFEST_FILE"
reject_newlines "--database-version" "$DATABASE_VERSION"


###############################################################################
# Validate requirements
###############################################################################

for cmd in find xargs bash sha256sum awk sort date wc tr realpath mktemp dirname basename chmod mv; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: required command not found: $cmd" >&2
        exit 1
    fi
done

# tqdm is optional. Without it, progress is reported as a periodic counter.
if command -v tqdm >/dev/null 2>&1; then
    HAVE_TQDM=1
else
    HAVE_TQDM=0
    echo "NOTE: tqdm not found - falling back to plain progress counter." >&2
fi


###############################################################################
# Validate database and canonicalize paths
###############################################################################

if [[ ! -d "$ROOT" ]]; then
    echo "ERROR: AlphaFold3 database root not found: $ROOT" >&2
    exit 1
fi

ROOT_ABS=$(realpath -e -- "$ROOT")
MMCIF_DIR="${ROOT_ABS}/mmcif_files"

if [[ ! -d "$MMCIF_DIR" ]]; then
    echo "ERROR: mmCIF directory not found: $MMCIF_DIR" >&2
    exit 1
fi

# Existing output symlinks are rejected explicitly. Atomic replacement of a
# symlink can otherwise be surprising and makes output-path validation harder to
# reason about.
if [[ -L "$CHECKSUM_FILE" ]]; then
    echo "ERROR: --checksum-file may not be an existing symbolic link: $CHECKSUM_FILE" >&2
    exit 1
fi

if [[ -L "$MANIFEST_FILE" ]]; then
    echo "ERROR: --manifest-file may not be an existing symbolic link: $MANIFEST_FILE" >&2
    exit 1
fi

CHECKSUM_ABS=$(realpath -m -- "$CHECKSUM_FILE")
MANIFEST_ABS=$(realpath -m -- "$MANIFEST_FILE")

if [[ "$CHECKSUM_ABS" == "$MANIFEST_ABS" ]]; then
    echo "ERROR: --checksum-file and --manifest-file resolve to the same path." >&2
    exit 1
fi

# Generated metadata must not be written inside the database root. This avoids
# accidental truncation of input files and prevents generated files from
# becoming part of the dataset being identified.
for output_path in "$CHECKSUM_ABS" "$MANIFEST_ABS"; do
    if [[ "$output_path" == "$ROOT_ABS" || "$output_path" == "$ROOT_ABS/"* ]]; then
        echo "ERROR: output files must be outside the AlphaFold3 database root." >&2
        echo "       Database root: $ROOT_ABS" >&2
        echo "       Output path:   $output_path" >&2
        exit 1
    fi
done

CHECKSUM_DIR=$(dirname -- "$CHECKSUM_ABS")
MANIFEST_DIR=$(dirname -- "$MANIFEST_ABS")

if [[ ! -d "$CHECKSUM_DIR" ]]; then
    echo "ERROR: checksum output directory does not exist: $CHECKSUM_DIR" >&2
    exit 1
fi

if [[ ! -d "$MANIFEST_DIR" ]]; then
    echo "ERROR: manifest output directory does not exist: $MANIFEST_DIR" >&2
    exit 1
fi


###############################################################################
# AlphaFold3 database files
###############################################################################

# Top-level AlphaFold3 database files.
#
# mmcif_files/ is handled separately because it contains many individual files.
DB_FILES=(
    "bfd-first_non_consensus_sequences.fasta"
    "mgy_clusters_2022_05.fa"
    "pdb_seqres_2022_09_28.fasta"
    "rnacentral_active_seq_id_90_cov_80_linclust.fasta"
    "rfam_14_9_clust_seq_id_90_cov_80_rep_seq.fasta"
    "nt_rna_2023_02_23_clust_seq_id_90_cov_80_rep_seq.fasta"
    "uniref90_2022_05.fa"
    "uniprot_all_2021_04.fa"
)

for relpath in "${DB_FILES[@]}"; do
    if [[ ! -f "${ROOT_ABS}/${relpath}" ]]; then
        echo "ERROR: database file not found: ${ROOT_ABS}/${relpath}" >&2
        exit 1
    fi
done


###############################################################################
# Temporary files and cleanup
###############################################################################

CHECKSUM_TMP=""
MANIFEST_TMP=""
MMCIF_RAW_TMP=""
MMCIF_SORTED_TMP=""
COMBINED_RAW_TMP=""

cleanup() {
    local status=$?

    [[ -n "$CHECKSUM_TMP" && -e "$CHECKSUM_TMP" ]] && rm -f -- "$CHECKSUM_TMP"
    [[ -n "$MANIFEST_TMP" && -e "$MANIFEST_TMP" ]] && rm -f -- "$MANIFEST_TMP"
    [[ -n "$MMCIF_RAW_TMP" && -e "$MMCIF_RAW_TMP" ]] && rm -f -- "$MMCIF_RAW_TMP"
    [[ -n "$MMCIF_SORTED_TMP" && -e "$MMCIF_SORTED_TMP" ]] && rm -f -- "$MMCIF_SORTED_TMP"
    [[ -n "$COMBINED_RAW_TMP" && -e "$COMBINED_RAW_TMP" ]] && rm -f -- "$COMBINED_RAW_TMP"

    return "$status"
}

trap cleanup EXIT

CHECKSUM_TMP=$(mktemp "${CHECKSUM_DIR}/.$(basename -- "$CHECKSUM_ABS").tmp.XXXXXX")
MANIFEST_TMP=$(mktemp "${MANIFEST_DIR}/.$(basename -- "$MANIFEST_ABS").tmp.XXXXXX")
MMCIF_RAW_TMP=$(mktemp "${CHECKSUM_DIR}/.alphafold3-mmcif-raw.tmp.XXXXXX")
MMCIF_SORTED_TMP=$(mktemp "${CHECKSUM_DIR}/.alphafold3-mmcif-sorted.tmp.XXXXXX")
COMBINED_RAW_TMP=$(mktemp "${CHECKSUM_DIR}/.alphafold3-checksums-raw.tmp.XXXXXX")


###############################################################################
# Hash mmCIF files
###############################################################################

echo "Counting mmCIF files..." >&2

total=$(
    cd "$ROOT_ABS"
    find "mmcif_files" \
        -maxdepth 1 \
        -type f \
        -printf '.' \
        | wc -c
)

if (( total == 0 )); then
    echo "ERROR: no regular files found in $MMCIF_DIR" >&2
    exit 1
fi

echo "Found ${total} mmCIF files." >&2
echo "Hashing mmCIF files with ${PARALLEL} parallel workers..." >&2

# File descriptor 3 carries one newline per successfully hashed file to the
# progress reporter: tqdm when available, otherwise an awk counter that reports
# every PROGRESS_EVERY files.
if (( HAVE_TQDM )); then
    exec 3> >(
        tqdm \
            --total "$total" \
            --unit files \
            > /dev/null
    )
else
    exec 3> >(
        awk -v total="$total" -v every="$PROGRESS_EVERY" '
            {
                count++
                if (every > 0 && count % every == 0) {
                    printf("  hashed %d/%d files\n", count, total) > "/dev/stderr"
                }
            }
            END {
                printf("  hashed %d/%d files\n", count, total) > "/dev/stderr"
            }
        '
    )
fi

# Hash from ROOT_ABS so sha256sum records root-relative paths. The worker only
# reports progress after sha256sum succeeds. This is important: without the
# explicit failure propagation, a failed sha256sum followed by a successful
# echo could make xargs report success and leave an incomplete checksum set.
if ! (
    cd "$ROOT_ABS"
    find "mmcif_files" \
        -maxdepth 1 \
        -type f \
        -print0 \
        | xargs \
            -0 \
            -r \
            -n 1 \
            -P "$PARALLEL" \
            bash -c '
                set -e
                sha256sum -- "$1"
                echo >&3
            ' _
) > "$MMCIF_RAW_TMP"; then
    exec 3>&-
    wait || true
    echo "ERROR: failed while hashing one or more mmCIF files." >&2
    exit 1
fi

# Closing FD 3 allows the progress reporter to terminate cleanly.
exec 3>&-
wait

MMCIF_HASHED_COUNT=$(wc -l < "$MMCIF_RAW_TMP" | tr -d '[:space:]')

if [[ "$MMCIF_HASHED_COUNT" != "$total" ]]; then
    echo "ERROR: expected ${total} mmCIF checksums but generated ${MMCIF_HASHED_COUNT}." >&2
    exit 1
fi

# Parallel workers finish in nondeterministic order. Sort by root-relative path
# so the checksum file itself is reproducible across runs.
sort -k2 "$MMCIF_RAW_TMP" > "$MMCIF_SORTED_TMP"

# The mmCIF component checksum is calculated from the sorted list of individual
# mmCIF SHA-256 values. File paths are intentionally excluded.
MMCIF_HASH=$(
    awk '{print $1}' "$MMCIF_SORTED_TMP" \
        | sort \
        | sha256sum \
        | awk '{print $1}'
)

echo "mmCIF composite SHA-256: $MMCIF_HASH" >&2


###############################################################################
# Hash top-level database files
###############################################################################

declare -A DB_HASHES

echo "Hashing top-level AlphaFold3 database files..." >&2

# Begin the combined checksum set with all mmCIF entries.
cat "$MMCIF_SORTED_TMP" > "$COMBINED_RAW_TMP"

for relpath in "${DB_FILES[@]}"; do
    echo "  ${relpath}" >&2

    line=$(
        cd "$ROOT_ABS"
        sha256sum -- "$relpath"
    )

    printf '%s\n' "$line" >> "$COMBINED_RAW_TMP"
    DB_HASHES["$relpath"]="${line%% *}"
done


###############################################################################
# Build deterministic checksum file and calculate dataset identities
###############################################################################

# Sort the complete checksum set by root-relative path. The resulting file is
# directly compatible with:
#
#   (cd "$ROOT_ABS" && sha256sum --check "$CHECKSUM_ABS")
#
# for verification after it is published.
sort -k2 "$COMBINED_RAW_TMP" > "$CHECKSUM_TMP"

FILE_COUNT=$(wc -l < "$CHECKSUM_TMP" | tr -d '[:space:]')
EXPECTED_FILE_COUNT=$(( total + ${#DB_FILES[@]} ))

if [[ "$FILE_COUNT" != "$EXPECTED_FILE_COUNT" ]]; then
    echo "ERROR: expected ${EXPECTED_FILE_COUNT} total checksums but generated ${FILE_COUNT}." >&2
    exit 1
fi

# Authoritative dataset identity.
#
# Extract each individual file hash from the checksum mapping, sort the hashes,
# and hash that stream. File paths are intentionally excluded.
DATASET_HASH=$(
    awk '{print $1}' "$CHECKSUM_TMP" \
        | sort \
        | sha256sum \
        | awk '{print $1}'
)

echo "Dataset composite SHA-256: $DATASET_HASH" >&2


###############################################################################
# Provenance metadata
###############################################################################

GENERATED_DATE=$(date -u +%Y-%m-%d)
GENERATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)

SHA256SUM_VERSION=$(sha256sum --version)
SHA256SUM_VERSION="${SHA256SUM_VERSION%%$'\n'*}"


###############################################################################
# Determine database version
###############################################################################

# If the user explicitly supplied --database-version, preserve it.
#
# Otherwise:
#
#   known dataset hash -> af3-dbs-2025-01
#   unknown dataset    -> <site>-<date>-<last8ofhash>
VERSION_BASIS=""

if [[ -z "$DATABASE_VERSION" ]]; then
    if [[ "$DATASET_HASH" == "$KNOWN_DATABASE_HASH" ]]; then
        DATABASE_VERSION="$KNOWN_DATABASE_VERSION"
        VERSION_BASIS="known_dataset_hash"

        echo "Known AlphaFold3 database detected." >&2
        echo "Database version set to: ${DATABASE_VERSION}" >&2
    else
        HASH_SUFFIX="${DATASET_HASH: -8}"
        DATABASE_VERSION="${SITE}-${GENERATED_DATE}-${HASH_SUFFIX}"
        VERSION_BASIS="identity_hash"

        echo >&2
        echo "WARNING: unique dataset detected - database version set to ${DATABASE_VERSION}" >&2
        echo >&2
    fi
else
    VERSION_BASIS="explicit"
    echo "Using explicitly supplied database version: ${DATABASE_VERSION}" >&2
fi


###############################################################################
# YAML helpers
###############################################################################

# Emit a YAML single-quoted scalar. In YAML, a literal single quote inside a
# single-quoted scalar is represented by two consecutive single quotes.
yaml_quote() {
    local value="$1"
    value=${value//\'/\'\'}
    printf "'%s'" "$value"
}

ROOT_YAML=$(yaml_quote "$ROOT_ABS")
CHECKSUM_YAML=$(yaml_quote "$CHECKSUM_ABS")
DATABASE_VERSION_YAML=$(yaml_quote "$DATABASE_VERSION")
SITE_YAML=$(yaml_quote "$SITE")
EMAIL_YAML=$(yaml_quote "$EMAIL")
SOFTWARE_YAML=$(yaml_quote "$SHA256SUM_VERSION")
GENERATED_AT_YAML=$(yaml_quote "$GENERATED_AT")
VERSION_BASIS_YAML=$(yaml_quote "$VERSION_BASIS")

# Shell-escaped values for executable verification commands embedded in the
# YAML block scalars.
printf -v ROOT_SHELL_Q '%q' "$ROOT_ABS"
printf -v CHECKSUM_SHELL_Q '%q' "$CHECKSUM_ABS"
printf -v DATASET_HASH_SHELL_Q '%q' "$DATASET_HASH"


###############################################################################
# Write YAML manifest
###############################################################################

echo "Writing manifest: $MANIFEST_ABS" >&2

cat > "$MANIFEST_TMP" <<EOF_MANIFEST
manifest_version: '1.1'

dataset:
  name: 'AlphaFold3 Reference Databases'
  identifier: 'alphafold3'
  description: >
    Reference sequence and structural databases used by the AlphaFold3
    data pipeline.

  database_version: ${DATABASE_VERSION_YAML}
  database_version_basis: ${VERSION_BASIS_YAML}

checksum:
  algorithm: 'sha256'
  value: '${DATASET_HASH}'
  scope: 'entire_dataset'
  type: 'composite'

  derivation:
    description: >
      Composite checksum generated from the SHA-256 checksums of every file in
      the dataset. Individual file hashes are sorted lexicographically before
      computing the final dataset checksum. File paths are intentionally
      excluded from the composite identity.
    individual_file_algorithm: 'sha256'
    ordering: 'lexicographic_by_checksum'
    includes_filenames: false
    checksum_file_paths_are_root_relative: true

contents:
  root_directory: ${ROOT_YAML}

  databases:
    - name: 'BFD'
      path: 'bfd-first_non_consensus_sequences.fasta'
      checksum: '${DB_HASHES[bfd-first_non_consensus_sequences.fasta]}'

    - name: 'MGnify'
      path: 'mgy_clusters_2022_05.fa'
      checksum: '${DB_HASHES[mgy_clusters_2022_05.fa]}'

    - name: 'PDB mmCIF'
      path: 'mmcif_files/'
      checksum: '${MMCIF_HASH}'
      checksum_type: 'composite'

    - name: 'PDB SeqRes'
      path: 'pdb_seqres_2022_09_28.fasta'
      checksum: '${DB_HASHES[pdb_seqres_2022_09_28.fasta]}'

    - name: 'RNAcentral'
      path: 'rnacentral_active_seq_id_90_cov_80_linclust.fasta'
      checksum: '${DB_HASHES[rnacentral_active_seq_id_90_cov_80_linclust.fasta]}'

    - name: 'Rfam'
      path: 'rfam_14_9_clust_seq_id_90_cov_80_rep_seq.fasta'
      checksum: '${DB_HASHES[rfam_14_9_clust_seq_id_90_cov_80_rep_seq.fasta]}'

    - name: 'NT RNA'
      path: 'nt_rna_2023_02_23_clust_seq_id_90_cov_80_rep_seq.fasta'
      checksum: '${DB_HASHES[nt_rna_2023_02_23_clust_seq_id_90_cov_80_rep_seq.fasta]}'

    - name: 'UniRef90'
      path: 'uniref90_2022_05.fa'
      checksum: '${DB_HASHES[uniref90_2022_05.fa]}'

    - name: 'UniProt'
      path: 'uniprot_all_2021_04.fa'
      checksum: '${DB_HASHES[uniprot_all_2021_04.fa]}'

provenance:
  generated_at: ${GENERATED_AT_YAML}
  generated_by: ${SITE_YAML}
  generated_by_user: ${EMAIL_YAML}
  software: ${SOFTWARE_YAML}
  file_count: ${FILE_COUNT}

validation:
  checksum_file: ${CHECKSUM_YAML}

  file_verification_command: >
    (cd ${ROOT_SHELL_Q} && sha256sum --check ${CHECKSUM_SHELL_Q})

  dataset_identity_verification_command: >
    test "\$(awk '{print \$1}' ${CHECKSUM_SHELL_Q} | sort | sha256sum | awk '{print \$1}')" = ${DATASET_HASH_SHELL_Q}

  full_verification_command: >
    (cd ${ROOT_SHELL_Q} && sha256sum --check ${CHECKSUM_SHELL_Q}) &&
    test "\$(awk '{print \$1}' ${CHECKSUM_SHELL_Q} | sort | sha256sum | awk '{print \$1}')" = ${DATASET_HASH_SHELL_Q}
EOF_MANIFEST


###############################################################################
# Publish outputs atomically
###############################################################################

# mktemp creates files mode 0600. These manifests are intended to be readable
# metadata artifacts, so normalize them to 0644 before publication.
chmod 0644 "$CHECKSUM_TMP" "$MANIFEST_TMP"

# Each rename is atomic within its destination filesystem. The checksum file is
# published first because the manifest references it.
mv -f -- "$CHECKSUM_TMP" "$CHECKSUM_ABS"
CHECKSUM_TMP=""

mv -f -- "$MANIFEST_TMP" "$MANIFEST_ABS"
MANIFEST_TMP=""


###############################################################################
# Summary
###############################################################################

echo >&2
echo "Done." >&2
echo "  Database:                    $ROOT_ABS" >&2
echo "  Database version:            $DATABASE_VERSION" >&2
echo "  Version basis:               $VERSION_BASIS" >&2
echo "  Site:                        $SITE" >&2
echo "  User:                        $EMAIL" >&2
echo "  Parallel mmCIF workers:      $PARALLEL" >&2
echo "  Files:                       $FILE_COUNT" >&2
echo "  Checksums:                   $CHECKSUM_ABS" >&2
echo "  Manifest:                    $MANIFEST_ABS" >&2
echo "  Dataset composite SHA-256:   $DATASET_HASH" >&2
