# rdsclient

Connect to RDS and Aurora databases with automatic authentication detection. Supports IAM, Secrets Manager, and manual authentication.

## Features

- Multiple tag-based filtering with AND logic
- Auto-connects with single match
- Auto-detection of authentication methods
- RDS and Aurora (reader/writer endpoints)
- Multiple authentication types
- SSL/TLS connections (configurable)
- Docker-based clients (no local installation)

## Prerequisites

- **AWS CLI**
- **Docker**
- **AWS credentials** with appropriate permissions
  - `rds:DescribeDBInstances` and `rds:DescribeDBClusters` for querying databases
  - `rds-db:connect` for IAM authentication
  - `secretsmanager:GetSecretValue` for Secrets Manager authentication

**Important**: rdsclient cannot be run inside awsenv containers (`awsenv rdsclient ...`) as it creates Docker-in-Docker issues. If awsenv wrapper scripts are installed, rdsclient works directly with the system-wide AWS CLI.

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

## Authentication Methods

### Auto-detect (Default)

**Priority:** IAM $\rightarrow$ Secrets Manager $\rightarrow$ Manual prompt.

### IAM (Identity and Access Management)

* Generates a **temporary token (15 minutes)** for connection.
* **No stored credentials** (token is temporary).
* Database must have **IAM database authentication enabled**.
* IAM user/role must have the `rds-db:connect` permission.
* Corresponding database user must be configured for IAM.

### Secrets Manager

* Retrieves credentials from **AWS Secrets Manager**.
* Supports automatic credential rotation.
* Used automatically if a `MasterUserSecret` is configured for the database.
* Database must have an associated secret in Secrets Manager.
* IAM user/role must have the `secretsmanager:GetSecretValue` permission.

### Manual

* Uses an **interactive password prompt**.
* Password is **not stored or logged**.

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

# Tags with equals sign
./rdsclient.sh -t Team=backend-api -t Config=pool=enabled
```

### Disable SSL

```bash
./rdsclient.sh -t Environment=dev -s false
```
