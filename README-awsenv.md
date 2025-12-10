# awsenv

Run commands and scripts in Docker with AWS CLI and session-manager-plugin pre-installed. Handles credentials, mounts directories, installs packages as needed.

## Features

- No local AWS CLI installation required
- Automatic AWS credentials handling (files and environment variables)
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
  -m MOUNT          Mount as <local>:<docker>[:(ro|rw)] (repeatable)
  -h                Help

Environment Variables:
  AWSENV_TTY        Control TTY allocation (always|never|auto, default: auto)

Examples:
  awsenv.sh aws s3 ls
  awsenv.sh -p vim ./my-script.sh
  awsenv.sh -m $(pwd)/logs:/logs:ro -m /data:/data:rw ./process.sh
  AWSENV_TTY=never awsenv.sh aws ec2 describe-instances
```

## Installation

See [main README](README.md#install-awsenv-as-aws-cli) for wrapper script installation instructions.

## How It Works

**Image Caching**: Generates unique Docker images based on package combinations. Images are reused on subsequent runs with matching packages.

- No packages: `awsenv-cli:base`
- With packages: `awsenv-cli:<hash>` (12-char hash of sorted package list)

**AWS Credentials**: Mounts `$HOME/.aws` read-only to `/root/.aws` and passes AWS environment variables (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`, `AWS_REGION`, `AWS_PROFILE`, etc.).

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

### Directory Mounting

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
```

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
