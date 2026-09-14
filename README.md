# alphafold3-database-onboarding

## Installing the databases with `run_and_capture.sh`

`run_and_capture.sh` is a small wrapper that:

1. prompts for the required metadata inputs,
2. runs `fetch_databases.sh` to download/install the databases, and
3. runs `alphafold3-database-metadata-capture.sh` to generate the checksum and manifest files.

### Prerequisites

Before you start, make sure:

- Bash is available
- this repository contains `run_and_capture.sh`, `fetch_databases.sh`, and `alphafold3-database-metadata-capture.sh`
- you have enough disk space for the AlphaFold 3 databases
- the commands required by the helper scripts are installed (for example `wget`, `tar`, `zstd`, `find`, `xargs`, `sha256sum`, `awk`, `sort`, `date`, `wc`, and `tr`)

### Run it

From the repository root, you can pass required flags directly:

```bash
bash ./run_and_capture.sh --root /data/alphafold3 --parallel 8 --email you@example.com --site WISCPATH
```

If the script is executable, `./run_and_capture.sh` works too.

If any required flag is omitted and you are in an interactive terminal, the script will prompt for it.

### Prompts you will see

The script prompts for any values you did not pass as flags:

- `Database root (--root)`: required; where the databases will be installed
- `Parallel workers (--parallel)`: required; must be a positive integer for metadata capture
- `Contact email (--email)`: required
- `Site/organization (--site)`: required
- `Manifest output (--manifest-file)`: optional; press Enter to use `<root>/alphafold3-manifest.yml`
- `Checksum output (--checksum-file)`: optional; press Enter to use `<root>/checksums.sha256`
- `Database version (--database-version, optional)`: optional; leave blank to let the metadata script determine it

Example prompt flow:

```text
Database root (--root): /data/alphafold3
Parallel workers (--parallel): 8
Contact email (--email): you@example.com
Site/organization (--site): My Lab
Manifest output (--manifest-file) [/data/alphafold3/alphafold3-manifest.yml]:
Checksum output (--checksum-file) [/data/alphafold3/checksums.sha256]:
Database version (--database-version, optional):
```

### What happens during execution

After you answer the prompts:

1. `fetch_databases.sh` downloads and unpacks the databases into the `--root` directory you provided.
2. If that succeeds, `alphafold3-database-metadata-capture.sh` runs with the same `--root`, `--parallel`, `--email`, and `--site` values, plus the manifest/checksum paths you selected.
3. If you entered a database version, it is passed through as `--database-version`; otherwise it is omitted.
4. On success, the script prints: `Success: fetch and metadata capture completed.`

### Default output files

Unless you enter different paths, metadata capture writes:

- `<root>/alphafold3-manifest.yml`
- `<root>/checksums.sha256`

### Important notes

- `--root`, `--parallel`, `--email`, and `--site` are required. If any are blank, the script exits before starting the download.
- The helper scripts are resolved relative to the location of `run_and_capture.sh`, so you can invoke it from any working directory.
- The manifest and checksum paths are passed through exactly as entered. Relative output paths are resolved from your current working directory; use absolute paths if you want them written somewhere specific.
- Output files may be written under `--root`, but cannot overwrite required AlphaFold3 input files or be placed inside `mmcif_files/`.
