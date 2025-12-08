# ec2client

Connect to EC2 instances via SSH or SSM. Filter by tags, select interactively, auto-connect with single match.

## Features

- Multiple tag-based filtering with AND logic
- Auto-connects with single match
- SSH and SSM connection methods
- Works with private instances (SSM)
- Custom SSM commands

## Usage

```
ec2client.sh [OPTIONS]

Options:
  -t TAG=VALUE      Tag filter (can be specified multiple times for AND logic)
  -p PROFILE        AWS profile
  -r REGION         AWS region (default: us-east-2)
  -c METHOD         Connection method: ssh or ssm (default: ssm)
  -u USER           SSH user (default: ec2-user)
  -k KEYFILE        SSH private key path
  -s COMMAND        SSM command (default: sh)

Environment Variables:
  AWS_PROFILE, AWS_REGION, AWS_DEFAULT_REGION
  AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_SESSION_TOKEN

Examples:
  ec2client.sh
  ec2client.sh -t Environment=prod
  ec2client.sh -t Environment=prod -t Team=backend
  ec2client.sh -t Name=bastion -c ssh -k ~/.ssh/key.pem
  ec2client.sh -t Environment=staging -s "cd; bash -l"
```

## Examples

### Basic Usage

```
$ ./ec2client.sh -t Environment=production -t Lifecycle=managed
Searching for EC2 instances with 2 tag filters...

1. api-server-01 (i-0123456789abcdef0): 54.123.45.67
2. api-server-02 (i-0fedcba987654321): 54.123.45.68
3. worker-node-01 (i-0a1b2c3d4e5f6g7h8): no-public-ip

Select instance (1-3): 3
Connecting to i-0a1b2c3d4e5f6g7h8 via SSM...
```

### SSM Connection (Default)

```bash
# All running instances
./ec2client.sh

# Single tag filter
./ec2client.sh -t Environment=production

# Multiple tag filters (AND logic)
./ec2client.sh -t Environment=production -t Team=backend
./ec2client.sh -t Name=web -t Role=api -t Region=us-east-1
```

### SSH Connection

```bash
# With key file
./ec2client.sh -t Name=bastion -c ssh -k ~/.ssh/prod.pem

# Different user with multiple tags
./ec2client.sh -t Environment=prod -t Name=ubuntu-server -c ssh -u ubuntu

# Multiple tags for precise selection
./ec2client.sh -t Team=platform -t Role=bastion -t Environment=prod -c ssh
```

### Custom SSM Commands

```bash
# Start bash login shell
./ec2client.sh -t Name=web -s "bash -l"

# Multiple tags with custom command
./ec2client.sh -t Environment=prod -t Role=worker -s "cd /var/log; bash -l"

# Custom profile
./ec2client.sh -t Name=dev -s "cd; bash --rcfile ~/.custom_profile"
```

### With awsenv

If wrapper scripts are installed, ec2client works directly:

```bash
./ec2client.sh -t Environment=prod
```

Install openssh-clients to execute ec2client inside an awsenv container:

```bash
./awsenv.sh -p openssh-clients ./ec2client.sh -t Name=bastion -c ssh -k ~/.ssh/key.pem
```

## Connection Methods

### SSM (AWS Systems Manager Session Manager)

* Connects to instances **without public IP** addresses.
* Utilizes the AWS Systems Manager (SSM) service and the **SSM Agent** running on the instance.
* Requires the instance to have an **IAM role with the `AmazonSSMManagedInstanceCore` policy**.
* Starts a **POSIX shell** (default is `sh`, configurable with the `-s` flag).
* Requires the **`session-manager-plugin`** to be installed locally (handled automatically by `awsenv`).
* **Ideal for private VPC instances** with no direct internet access.

### SSH (Secure Shell)

* Connects using the standard Secure Shell protocol.
* Requires the instance to have a **public IP address** or reachable private IP (via VPN, for example).
* Requires a **security group rule allowing inbound traffic on TCP Port 22**.
* Supports **agent forwarding** (using the `-A` flag).

## Tag Filtering

### Syntax
- Format: `-t key=value`
- Multiple filters: `-t key1=value1 -t key2=value2`
- Logic: All tags must match (AND operation)

### Character Handling
- First `=` separates key from value
- Values can contain `=`: `-t Config=key=value` → key: `Config`, value: `key=value`
- Keys with `=` not supported (extremely rare in practice)
- Use quotes for spaces: `-t Name='Web Server'`
- Tag matching is case-sensitive
