# rdsclient

Connect to RDS and Aurora databases with automatic authentication detection. Supports IAM, Secrets Manager, and manual authentication.

## Features

- Multiple tag-based filtering with AND logic
- Auto-detection of authentication methods
- RDS and Aurora (reader/writer endpoints)
- Multiple authentication types
- SSL/TLS connections (configurable)
- Docker-based clients (no local installation)
- PostgreSQL, MySQL, Oracle, SQL Server support

## Supported Databases

| Engine | Client | Auth Support |
|--------|--------|--------------|
| PostgreSQL / Aurora PostgreSQL | psql | IAM, Secret, Manual |
| MySQL / Aurora MySQL / MariaDB | mysql | IAM, Secret, Manual |
| Oracle (EE, SE2, CDB variants) | sqlplus | Secret, Manual |
| SQL Server (EE, SE, EX, Web) | sqlcmd | Secret, Manual |

All clients run in Docker containers with SSL enabled by default.

## Usage

```
rdsclient.sh [OPTIONS]

Options:
  -t TAG=VALUE      Tag filter (can be specified multiple times for AND logic)
  -p PROFILE        AWS profile
  -r REGION         AWS region (default: us-east-2)
  -e ENDPOINT_TYPE  Aurora endpoint: reader or writer
  -a AUTH_TYPE      Authentication: iam, secret, or manual
  -u DB_USER        Database user (sets auth to manual)
  -s SSL_MODE       Use SSL: true or false (default: true)

Environment Variables:
  AWS_PROFILE, AWS_REGION, AWS_DEFAULT_REGION
  AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_SESSION_TOKEN

Examples:
  rdsclient.sh
  rdsclient.sh -t Environment=prod
  rdsclient.sh -t Environment=prod -t Application=api -a iam
  rdsclient.sh -t Environment=staging -e writer
  rdsclient.sh -u myuser -a manual
  rdsclient.sh -t Environment=dev -s false
```
## Examples

### Basic Usage

```
$ ./rdsclient.sh -t Environment=production -t Application=analytics
Searching for databases with 2 tag filters...

1. [Aurora] analytics-cluster (aurora-postgresql): analytics-cluster.cluster-abc.us-east-2.rds.amazonaws.com
2. [Aurora] analytics-cluster (aurora-postgresql): analytics-cluster.cluster-ro-abc.us-east-2.rds.amazonaws.com
3. [RDS] reports-db (postgres): reports-db.ghi789.us-east-2.rds.amazonaws.com

Select database (1-3): 1
Auto-detecting authentication method...
Connecting to analytics-cluster as admin...
```

### Auto-Authentication

```bash
# All databases
./rdsclient.sh

# Single tag filter
./rdsclient.sh -t Environment=production

# Multiple tag filters (AND logic)
./rdsclient.sh -t Environment=production -t Application=api

# Writer endpoint only with multiple tags
./rdsclient.sh -t Application=analytics -t Team=data -e writer
```

### Specify Authentication

```bash
# IAM authentication with multiple tags
./rdsclient.sh -t Environment=prod -t Name=main-db -a iam

# Manual authentication
./rdsclient.sh -u appuser -a manual

# Secrets Manager with tag filter
./rdsclient.sh -t Application=api -a secret
```

### Aurora Endpoints

```bash
# Writer only with multiple tags
./rdsclient.sh -t Environment=prod -t Application=web -e writer

# Reader only with multiple tags
./rdsclient.sh -t Environment=prod -t Team=analytics -e reader

# Both endpoints (default)
./rdsclient.sh -t Environment=prod
```

### Multiple Tag Combinations

```bash
# Two tags
./rdsclient.sh -t Environment=prod -t Application=api

# Three tags for precise filtering
./rdsclient.sh -t Environment=prod -t Application=web -t Region=us-east-1

# Tags with special characters
./rdsclient.sh -t Team=backend-api -t Owner='Platform Team'
```

### Disable SSL

```bash
./rdsclient.sh -t Environment=dev -s false
```

### With awsenv

If wrapper scripts are installed, rdsclient works directly:

```bash
./rdsclient.sh -t Environment=prod -t Application=api
```

**Important**: rdsclient cannot be run inside awsenv container (`./awsenv.sh ./rdsclient.sh`) because rdsclient creates its own Docker containers, resulting in Docker-in-Docker issues. Use wrapper script installation method instead.

## Authentication Methods

### Auto-detect (Default)
Priority: IAM if enabled → Secrets Manager if available → Manual prompt

### IAM
- Generates temporary token (15 minutes)
- Requires IAM database authentication enabled
- No stored credentials

**Requirements**:
- Database has IAM authentication enabled
- IAM user/role has `rds-db:connect` permission
- Database user configured for IAM

### Secrets Manager
- Retrieves credentials from AWS Secrets Manager
- Supports automatic rotation
- Used automatically if `MasterUserSecret` configured

**Requirements**:
- Database has associated secret
- IAM user/role has `secretsmanager:GetSecretValue` permission

### Manual
- Interactive password prompt
- Password not stored or logged

## Tag Filtering

### Syntax
- Format: `-t key=value`
- Multiple filters: `-t key1=value1 -t key2=value2`
- Logic: All tags must match (AND operation)

### Character Handling
- First `=` separates key from value
- Values can contain `=`: `-t Config=key=value` → key: `Config`, value: `key=value`
- Keys with `=` not supported (extremely rare in practice)
- Use quotes for spaces: `-t Name='Production DB'`
- Tag matching is case-sensitive

## Notes

- Auto-connects with single match
- Database clients run in Docker (auto-managed)
- SSL enabled by default
- Containers auto-cleaned on exit
- Cannot run inside awsenv container (use wrapper scripts)
- Tag filtering is case-sensitive
- IAM tokens expire after 15 minutes
