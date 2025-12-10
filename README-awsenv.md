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

### Using with Other Tools

Ec2client and rdsclient work seamlessly with AWS CLI available, whether via local installation or awsenv wrapper scripts:

```bash
./ec2client.sh -t Environment=prod -t Team=backend
./rdsclient.sh -t Application=api -t Environment=staging
```

**Note**: rdsclient cannot be run inside awsenv (creates Docker-in-Docker issues). Openssh-clients is required to run ec2client:

```bash
./awsenv.sh -p openssh-clients ./ec2client.sh -t Name=bastion -c ssh
```

## How It Works

**Image Caching**: Generates unique Docker images based on package combinations. Images are reused on subsequent runs with matching packages.

- No packages: `awsenv-cli:base`
- With packages: `awsenv-cli:<hash>` (12-char hash of sorted package list)

**AWS Credentials**: Mounts `$HOME/.aws` read-only to `/root/.aws` and passes AWS environment variables (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`, `AWS_REGION`, `AWS_PROFILE`, etc.).

**Terminal Handling**: Automatically detects interactive terminals and allocates pseudo-TTY when stdin is a TTY. Passes terminal environment variables (TERM, COLUMNS, LINES, PAGER, LANG, LC_*) for proper display and interaction. Can be overridden with AWSENV_TTY environment variable.

**Command Resolution**: Built-in commands (`aws`, `aws_completer`, `session-manager-plugin`) use container versions. Other commands are located on host, symlinks resolved (up to 40 levels), and mounted into container.

**Package Files**: One package per line. Lines starting with `#` and empty lines ignored.

## Terminal Support

awsenv automatically detects interactive terminals and enables full TTY support including paging, colors, and interactive sessions.

**Interactive commands work as expected:**
```bash
./awsenv.sh aws help                    # Pages through less/more
./awsenv.sh aws ssm start-session ...   # Full terminal (vim, arrows)
```

**Scripting and automation work cleanly:**
```bash
./awsenv.sh aws ec2 describe-instances | jq .   # No TTY, clean output
output=$(./awsenv.sh aws s3 ls)                 # Capture works correctly
```

**Override when needed:**
```bash
AWSENV_TTY=never ./awsenv.sh aws ...   # Force non-interactive
AWSENV_TTY=always ./awsenv.sh aws ...  # Force interactive
```

## Using awsenv Inside Scripts

When calling AWS CLI commands inside shell scripts for data retrieval, automation, or piping output, **always set `AWSENV_TTY=never`** to prevent terminal interference:

```bash
#!/bin/sh
# Get instance data for processing
instances=$(AWSENV_TTY=never awsenv aws ec2 describe-instances --query 'Reservations[].Instances[]')
echo "$instances" | jq '.[] | select(.State.Name == "running")'

# List S3 buckets
AWSENV_TTY=never awsenv aws s3api list-buckets | jq -r '.Buckets[].Name'
```

### Why `AWSENV_TTY=never` Is Required

awsenv automatically detects interactive terminals and allocates a pseudo-TTY for full terminal support (paging, colors). This behavior is necessary for a good interactive user experience.

When a script using awsenv is launched from an interactive shell, awsenv's TTY detection sees that stdin is connected to a terminal and allocates a pseudo-TTY inside the Docker container, even though the script requires clean, non-interactive output.

This limitation is inherent to the Docker TTY allocation mechanism and environment inheritance. Setting `AWSENV_TTY=never` explicitly forces non-interactive mode, preventing issues that break automation:

  * **Hanging Scripts:** Disables the AWS CLI pager, which otherwise waits for user input.
  * **Corrupted Output:** Ensures output is clean plain text, preventing ANSI escape codes from interfering with JSON/data parsers (like `jq`).
  * **Automation Failure:** Guarantees commands behave predictably for capturing output and piping.

### When to Use It

  * Capturing command output: `output=$(awsenv aws ...)`
  * Piping to processing tools: `awsenv aws ... | jq`
  * Parsing JSON responses in scripts
  * Cron jobs or CI/CD pipelines (any non-interactive automation)

### Alternative Setting

For scripts with multiple awsenv calls, set the environment variable once:

```bash
#!/bin/sh
export AWSENV_TTY=never
# All awsenv calls now use non-interactive mode
instances=$(awsenv aws ec2 describe-instances)
buckets=$(awsenv aws s3 ls)
```
