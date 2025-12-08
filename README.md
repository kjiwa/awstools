# AWS Shell Tools

POSIX-compliant shell scripts for AWS resource management. Connect to EC2 instances and RDS databases, run AWS commands in containers, with tag-based filtering and minimal dependencies.

## Tools

**[awsenv](README-awsenv.md)** - Run AWS CLI and scripts in Docker without local installation. Handles credentials, mounts directories, installs packages on demand.

**[ec2client](README-ec2client.md)** - Connect to EC2 instances via SSH or SSM. Filter by tags, select interactively, auto-connect when one match found.

**[rdsclient](README-rdsclient.md)** - Connect to RDS/Aurora databases with auto-detected authentication (IAM, Secrets Manager, or manual).

## Common Features

- Multiple tag-based filtering (AND logic)
- Interactive selection when multiple matches
- Auto-connect with single match
- POSIX-compliant (sh, dash, bash, zsh)
- Docker-based isolation

## Quick Start

```bash
# Use directly without installation
./ec2client.sh -t Environment=prod
./rdsclient.sh -t Application=api
./awsenv.sh aws s3 ls

# Or install for system-wide access
sudo ./install.sh -d /usr/local/bin -c bash
aws --version
```

## Examples

```bash
# Connect to EC2 via SSM
ec2client -t Environment=production

# Multiple tag filters (AND logic)
ec2client -t Environment=prod -t Team=backend

# Connect to RDS with IAM
rdsclient -t Application=api -a iam

# Multiple database filters
rdsclient -t Environment=prod -t Application=analytics

# Run AWS commands in container
awsenv aws s3 ls
awsenv -p jq ./process-data.sh
```

## Usage

### Run Without Installation

The scripts work directly without installation:

```bash
chmod +x *.sh
./ec2client.sh -t Environment=staging
./rdsclient.sh -t Team=backend -a iam
./awsenv.sh aws ec2 describe-instances
```

### Install for System-Wide Access (Optional)

Installation makes the tools available system-wide and provides AWS CLI wrapper functionality.

### Prerequisites
- Docker
- AWS credentials (for ec2client and rdsclient)

### Quick Install

```bash
# System-wide installation (requires sudo)
sudo ./install.sh -d /usr/local/bin -c bash

# User installation (no sudo required)
./install.sh -d ~/.local/bin -c bash
export PATH="$HOME/.local/bin:$PATH"  # Add to ~/.bashrc
```

The install script:
- Copies tools to target directory without `.sh` extension
- Creates AWS CLI wrapper scripts (aws, aws_completer, session-manager-plugin)
- Optionally configures shell completion for bash or zsh

### Manual Installation

```bash
# Copy scripts
sudo cp awsenv.sh /usr/local/bin/awsenv
sudo cp ec2client.sh /usr/local/bin/ec2client
sudo cp rdsclient.sh /usr/local/bin/rdsclient
sudo chmod +x /usr/local/bin/{awsenv,ec2client,rdsclient}

# Create AWS CLI wrappers
for cmd in aws aws_completer session-manager-plugin; do
  sudo tee /usr/local/bin/$cmd > /dev/null << 'EOF'
#!/bin/sh
exec /usr/local/bin/awsenv "$(basename "$0")" "$@"
EOF
  sudo chmod +x /usr/local/bin/$cmd
done
```

### Shell Completion

**Bash** (`~/.bashrc`):
```bash
complete -C aws_completer aws
```

**Zsh** (`~/.zshrc`):
```zsh
autoload -Uz compinit && compinit
complete -C aws_completer aws
```

## Uninstall

```bash
# Remove installed files
sudo rm -f /usr/local/bin/{awsenv,ec2client,rdsclient,aws,aws_completer,session-manager-plugin}

# Remove completion (edit ~/.bashrc or ~/.zshrc manually)
```
