# AWS Shell Tools

POSIX-compliant shell scripts for AWS resource management. Connect to EC2 instances and RDS databases, run AWS commands in containers, with tag-based filtering and minimal dependencies.

## Tools

**[awsenv](README-awsenv.md)** - Run AWS CLI and scripts in Docker without local installation. Handles credentials, mounts directories, installs packages on demand.

**[ec2client](README-ec2client.md)** - Connect to EC2 instances via SSH or SSM. Filter by tags, select interactively, auto-connect when one match found.

**[rdsclient](README-rdsclient.md)** - Connect to RDS/Aurora databases with auto-detected authentication (IAM, Secrets Manager, or manual).

## Quick Examples

```bash
# Connect to EC2 via SSM
./ec2client.sh -t Environment=production

# Multiple tag filters (AND logic)
./ec2client.sh -t Environment=prod -t Team=backend

# Connect to RDS with IAM
./rdsclient.sh -t Application=api -a iam

# Multiple database filters
./rdsclient.sh -t Environment=prod -t Application=analytics

# Run AWS commands in container
./awsenv.sh aws s3 ls
./awsenv.sh -p jq ./process-data.sh
```

## Common Features

- Multiple tag-based filtering (AND logic)
- Interactive selection when multiple matches
- Auto-connect with single match
- POSIX-compliant (sh, dash, bash, zsh)
- Docker-based isolation

## Installation

### Prerequisites
- Docker
- AWS credentials (for ec2client and rdsclient)

### Basic Setup

```bash
chmod +x awsenv.sh ec2client.sh rdsclient.sh
```

### Install awsenv as AWS CLI

#### Wrapper Scripts

Creates executable scripts in PATH that invoke awsenv.

```bash
# System-wide (requires sudo)
INSTALL_DIR=/usr/local/bin
AWSENV_PATH="$(realpath awsenv.sh)"

for cmd in aws aws_completer session-manager-plugin; do
  sudo tee $INSTALL_DIR/$cmd > /dev/null << EOF
#!/bin/sh
exec $AWSENV_PATH "\$(basename "\$0")" "\$@"
EOF
  sudo chmod +x $INSTALL_DIR/$cmd
done
```

#### Enable Completion (Optional)

**Bash** (`~/.bashrc`):
```bash
complete -C aws_completer aws
```

**Zsh** (`~/.zshrc`):
```zsh
autoload -Uz compinit && compinit
complete -C aws_completer aws
```

#### Verify Installation

```bash
aws --version
aws s3 ls
```
