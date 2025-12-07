# ec2client

Connect to EC2 instances via SSH or SSM. Filter by tags, select interactively, auto-connect with single match.

## Features

- Tag-based filtering
- SSH and SSM connection methods
- Works with private instances (SSM)
- Auto-connects with single match
- Custom SSM commands

## Usage

```
ec2client.sh [OPTIONS]

Options:
  -t TAG_KEY        Tag key to filter
  -v TAG_VALUE      Tag value to filter
  -p PROFILE        AWS profile
  -r REGION         AWS region (default: us-east-2)
  -c METHOD         Connection method: ssh or ssm (default: ssm)
  -u USER           SSH user (default: ec2-user)
  -k KEYFILE        SSH private key path
  -s COMMAND        SSM command (default: sh)

Environment Variables:
  AWS_PROFILE, AWS_REGION, AWS_DEFAULT_REGION
  AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_SESSION_TOKEN

Note: Tag key and value must be specified together

Examples:
  ec2client.sh
  ec2client.sh -t Environment -v prod
  ec2client.sh -t Name -v bastion -c ssh -k ~/.ssh/key.pem
  ec2client.sh -t Name -v web -s "cd /var/log; bash -l"
```

## Examples

### SSM Connection (Default)

```bash
# All running instances
./ec2client.sh

# Filter by tag
./ec2client.sh -t Environment -v production
./ec2client.sh -t Name -v web-server
```

Output:
```
Searching for EC2 instances with Environment=production...

1. api-server-01 (i-0123456789abcdef0): 54.123.45.67
2. api-server-02 (i-0fedcba987654321): 54.123.45.68
3. worker-node-01 (i-0a1b2c3d4e5f6g7h8): no-public-ip

Select instance (1-3): 3
Connecting to i-0a1b2c3d4e5f6g7h8 via SSM...
```

### SSH Connection

```bash
# With key file
./ec2client.sh -t Name -v bastion -c ssh -k ~/.ssh/prod.pem

# Different user
./ec2client.sh -t Name -v ubuntu-server -c ssh -u ubuntu
```

### Custom SSM Commands

```bash
# Start bash login shell
./ec2client.sh -t Name -v web -s "bash -l"

# Change directory and start shell
./ec2client.sh -t Name -v app -s "cd /var/log; bash -l"

# Custom profile
./ec2client.sh -t Name -v dev -s "cd; bash --rcfile ~/.custom_profile"
```

### With awsenv

If wrapper scripts are installed, ec2client works directly:

```bash
./ec2client.sh -t Environment -v prod
```

Install openssh-clients when executing inside an awsenv container:

```bash
./awsenv.sh -p openssh-clients ./ec2client.sh -t Name -v bastion -c ssh -k ~/.ssh/key.pem
```

## Connection Methods

### SSM
- No public IP required
- Uses AWS Systems Manager
- Requires SSM agent on instance
- Instance needs IAM role with `AmazonSSMManagedInstanceCore`
- Starts POSIX shell (`sh` by default, configurable with `-s`)
- Works with private VPC instances

**Requirements**:
- SSM agent running
- Instance IAM role with SSM permissions
- `session-manager-plugin` installed locally (automatic via awsenv)

### SSH
- Requires public IP
- Requires SSH key
- Port 22 must be accessible
- Uses agent forwarding (`-A`)

**Requirements**:
- Instance has public IP
- Security group allows SSH (port 22)
- SSH key file accessible
- `ssh` command available

## Notes

- Only running instances displayed
- Auto-connects with single match
- Tag filtering is case-sensitive
- SSH uses agent forwarding for convenience
- Custom SSM commands support complex syntax (semicolons, pipes, quotes)
