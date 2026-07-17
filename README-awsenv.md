# awsenv

Run commands and scripts in Docker with AWS CLI and session-manager-plugin pre-installed. Handles credentials, mounts directories, installs packages as needed.

## Features

- No local AWS CLI installation required
- Automatic AWS credentials handling (files and environment variables)
- AWS SSO authentication support
- Full terminal support (paging, colors, interactive sessions)
- Package caching via Docker image layers
- Custom package installation
- Directory mounting with read-only/read-write control
- Command location and symlink resolution

## Usage

```
awsenv.sh [OPTIONS] <command> [args...]

Options:
  -p PACKAGE        Additional package (repeatable)
  -f FILE           File with packages (one per line)
  -m MOUNT          Mount a directory or file as <local>:<docker>[:(ro|rw)] (repeatable)
  -h                Help

Environment Variables:
  AWSENV_TTY            Control TTY allocation (always|never|auto, default: auto)
  AWSENV_AWS_DIR_MODE   Control AWS directory mount (ro|rw|auto, default: auto)
  AWSENV_PWD_MODE       Control current directory mount (rw|ro|off, default: rw)

Examples:
  awsenv.sh aws s3 ls
  awsenv.sh -p vim ./my-script.sh
  awsenv.sh -m $(pwd)/logs:/logs:ro -m /data:/data:rw ./process.sh
  awsenv.sh aws configure sso
  AWSENV_TTY=never awsenv.sh aws ec2 describe-instances
  AWSENV_PWD_MODE=off awsenv.sh aws --version
```

## Installation

See [main README](README.md#install-awsenv-as-aws-cli) for wrapper script installation instructions.

## How It Works

**Image Caching**: Generates unique Docker images based on package combinations. Images are reused on subsequent runs with matching packages.

- No packages: `awsenv-cli:base`
- With packages: `awsenv-cli:<tag>`, where `<tag>` is a `cksum` checksum of the sorted package list (falls back to `sum`, then a byte count, if `cksum` isn't available)

**AWS Credentials**: Mounts `$HOME/.aws` to `/root/.aws` with automatic read-only/read-write mode detection, and forwards every environment variable whose name starts with `AWS_` (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`, `AWS_REGION`, `AWS_PROFILE`, `AWS_PAGER`, `AWS_ENDPOINT_URL*`, `AWS_CA_BUNDLE`, `AWS_MAX_ATTEMPTS`, `AWS_RETRY_MODE`, `AWS_ROLE_ARN`, `AWS_WEB_IDENTITY_TOKEN_FILE`, etc.) that is set and non-empty. Configuration and SSO commands automatically receive write access for credential caching.

**Note**: `AWS_CONFIG_FILE`, `AWS_SHARED_CREDENTIALS_FILE`, `AWS_CA_BUNDLE`, and `AWS_WEB_IDENTITY_TOKEN_FILE` hold host filesystem paths. Forwarding the variable does not make the file available inside the container — mount the referenced path explicitly with `-m` (e.g. `-m $AWS_WEB_IDENTITY_TOKEN_FILE:$AWS_WEB_IDENTITY_TOKEN_FILE:ro`) if the command needs it.

**Working Directory**: The current directory is mounted into the container at the same path and set as the working directory, so commands can read and write files relative to `$(pwd)` without an explicit `-m`. Controlled by `AWSENV_PWD_MODE` (`rw` by default, or `ro`/`off`).

**Command Resolution**: Built-in commands (`aws`, `aws_completer`, `session-manager-plugin`) use container versions. Other commands are located on host, symlinks resolved (up to 40 levels), and mounted into container.

**Package Files**: One package per line. Lines starting with `#` and empty lines ignored.

**Terminal Handling**: Automatically detects interactive terminals using `[ -t 0 ]` and allocates pseudo-TTY when stdin is a TTY. Passes terminal environment variables (TERM, COLUMNS, LINES, PAGER, LANG, LC_*) for proper display and interaction.

Interactive mode enables:
- AWS CLI pager (less/more)
- Full terminal support for SSM sessions
- Colors and formatted output

Non-interactive mode provides:
- Clean output for parsing
- No pager interference
- Suitable for automation

Override automatic detection with `AWSENV_TTY` environment variable (always|never|auto). When using awsenv inside scripts for data processing, set `AWSENV_TTY=never` to prevent TTY allocation issues.

## Examples

### AWS Commands

```bash
./awsenv.sh aws ec2 describe-instances
./awsenv.sh aws s3 sync s3://bucket ./local
./awsenv.sh aws ssm start-session --target i-1234567890abcdef0
```

### AWS SSO Authentication

```bash
# Interactive browser-based authentication
./awsenv.sh aws configure sso

# Device code authentication (for environments with restricted browser access)
./awsenv.sh aws configure sso --use-device-code

# Re-authenticate existing SSO profile
./awsenv.sh aws sso login --profile my-sso-profile
```

**macOS Docker Desktop note**: `aws configure sso` and `aws sso login` need `--network host` to receive the browser's OAuth callback. On Docker Desktop for macOS, host networking requires enabling the "Enable host networking" feature (Settings → Resources → Network) and is not available on all versions. If host networking isn't available, pass `--use-device-code` instead — it doesn't need a local callback port and works everywhere:

```bash
./awsenv.sh aws configure sso --use-device-code
```

### Local Scripts

```bash
./awsenv.sh ./generate-reports.sh
```

### Package Installation

```bash
# Single package
./awsenv.sh -p jq ./process-data.sh

# Multiple packages
./awsenv.sh -p vim -p htop -p curl ./debug.sh
```

### Package Files

Create `packages.txt`:
```
vim
jq
curl
htop
```

Use with:
```bash
./awsenv.sh -f packages.txt ./deploy.sh
```

### Directory and File Mounting

`-m` accepts either a directory or a single file as `<local_path>`:

```bash
# Read-only
./awsenv.sh -m $(pwd)/config:/config:ro ./process.sh

# Read-write (explicit or default)
./awsenv.sh -m $(pwd)/data:/data:rw ./transform.sh
./awsenv.sh -m $(pwd)/output:/output ./generate.sh

# Multiple mounts
./awsenv.sh -m $(pwd)/input:/input:ro \
            -m $(pwd)/output:/output:rw \
            ./pipeline.sh

# Mounting a single file (e.g. an SSH key for ec2client -c ssh)
./awsenv.sh -m ~/.ssh/key.pem:/keys/key.pem:ro ec2client -t Name=bastion -c ssh -k /keys/key.pem
```

The current directory is already mounted by default (see **Working Directory** above); `-m` is for mounting *other* paths.

### Complex Commands

```bash
# Special characters preserved
aws ssm start-session --target i-123456 \
  --document-name AWS-StartInteractiveCommand \
  --parameters '{"command":["cd /var/log; bash -l"]}'

# Complex queries
aws ec2 describe-instances \
  --query 'Reservations[].Instances[].[InstanceId,State.Name]' \
  --output table
```

## Integration with Other Tools

ec2client and rdsclient work seamlessly when AWS CLI is available, whether via local installation or awsenv wrapper scripts:

```bash
# Direct usage with wrapper scripts installed
ec2client -t Environment=prod -t Team=backend
rdsclient -t Application=api -t Environment=staging

# Or with explicit awsenv.sh
./awsenv.sh ./ec2client.sh -t Environment=prod
./awsenv.sh -p openssh-clients ./ec2client.sh -t Name=bastion -c ssh
```

**Important**: rdsclient cannot be run inside awsenv (`./awsenv.sh ./rdsclient.sh`) as it creates Docker-in-Docker issues. Use wrapper script installation instead.

## Using awsenv in Shell Scripts

Scripts can call awsenv to run AWS commands without requiring local AWS CLI installation. For automation and data processing, use `AWSENV_TTY=never` to prevent terminal interference:

```bash
#!/bin/sh
# Get instance data for processing
instances=$(AWSENV_TTY=never awsenv aws ec2 describe-instances)
echo "$instances" | jq '.Reservations[].Instances[] | select(.State.Name == "running")'

# Process S3 buckets
AWSENV_TTY=never awsenv aws s3api list-buckets | jq -r '.Buckets[].Name' | while read bucket; do
  echo "Processing: $bucket"
done
```

For scripts with multiple AWS calls, set the environment variable once:

```bash
#!/bin/sh
export AWSENV_TTY=never

instances=$(awsenv aws ec2 describe-instances)
buckets=$(awsenv aws s3 ls)
# All awsenv calls use non-interactive mode
```

### Why This Is Required

awsenv automatically detects interactive terminals and allocates a pseudo-TTY for full terminal support (paging, colors). This behavior is necessary for a good interactive user experience.

When a script is launched from an interactive shell, awsenv's TTY detection sees that stdin is connected to a terminal and allocates a pseudo-TTY inside the Docker container, even though the script requires clean, non-interactive output. This limitation is inherent to Docker's TTY allocation mechanism. Setting `AWSENV_TTY=never` explicitly forces non-interactive mode, preventing issues that break automation:

  * **Hanging Scripts:** Disables the AWS CLI pager, which otherwise waits for user input.
  * **Corrupted Output:** Ensures output is clean plain text, preventing ANSI escape codes from interfering with JSON/data parsers (like `jq`).
  * **Automation Failure:** Guarantees commands behave predictably for capturing output and piping.

### When to Use It

  * Capturing command output: `output=$(awsenv aws ...)`
  * Piping to processing tools: `awsenv aws ... | jq`
  * Parsing JSON responses in scripts
  * Cron jobs or CI/CD pipelines (any non-interactive automation)
