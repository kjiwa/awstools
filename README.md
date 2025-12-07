# AWS Shell Tools

POSIX-compliant shell scripts for AWS resource management. Connect to EC2 instances and RDS databases, run AWS commands in containers, with tag-based filtering and minimal dependencies.

## Tools

**awsenv** - Run AWS CLI and scripts in Docker without local installation. Handles credentials, mounts directories, installs packages on demand.

**ec2client** - Connect to EC2 instances via SSH or SSM. Filter by tags, select interactively, auto-connect when one match found.

**rdsclient** - Connect to RDS/Aurora databases with auto-detected authentication (IAM, Secrets Manager, or manual).

## Quick Examples

```bash
# Connect to EC2 via SSM
./ec2client.sh -t Environment -v production

# Connect to RDS with IAM
./rdsclient.sh -t Application -v api -a iam

# Run AWS commands in container
./awsenv.sh aws s3 ls
./awsenv.sh -p jq ./process-data.sh
```

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

**Benefits**: Persistent across sessions, works in all shells, available to all processes.

**Drawbacks**: Requires PATH directory access, needs sudo for system install.

#### Verify Installation

```bash
aws --version
aws s3 ls
```

## Documentation

- [awsenv](README-awsenv.md) - Container environment details, package management, mounting
- [ec2client](README-ec2client.md) - SSH/SSM connection, tag filtering, custom commands
- [rdsclient](README-rdsclient.md) - Database clients, authentication methods, SSL configuration

## Common Features

- Tag-based resource filtering
- Interactive selection when multiple matches
- Auto-connect with single match
- POSIX-compliant (sh, dash, bash, zsh)
- Docker-based isolation
