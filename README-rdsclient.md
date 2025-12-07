# rdsclient

Connect to RDS and Aurora databases with automatic authentication detection. Supports IAM, Secrets Manager, and manual authentication.

## Features

- Tag-based filtering
- Auto-detection of authentication methods
- RDS and Aurora (reader/writer endpoints)
- Multiple authentication types
- SSL/TLS connections (configurable)
- Docker-based clients (no local installation)
- PostgreSQL, MySQL, Oracle, SQL Server support

## Usage

```
rdsclient.sh [OPTIONS]

Options:
  -t TAG_KEY        Tag key to filter
  -v TAG_VALUE      Tag value to filter
  -p PROFILE        AWS profile
  -r REGION         AWS region (default: us-east-2)
  -e ENDPOINT_TYPE  Aurora endpoint: reader or writer
  -a AUTH_TYPE      Authentication: iam, secret, or manual
  -u DB_USER        Database user (sets auth to manual)
  -s SSL_MODE       Use SSL: true or false (default: true)

Environment Variables:
  AWS_PROFILE, AWS_REGION, AWS_DEFAULT_REGION
  AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_SESSION_TOKEN

Note: Tag key and value must be specified together

Examples:
  rdsclient.sh
  rdsclient.sh -t Environment -v prod -a iam
  rdsclient.sh -t Environment -v staging -e writer
  rdsclient.sh -u myuser -a manual
  rdsclient.sh -t Environment -v dev -s false
```

## Examples

### Auto-Authentication

```bash
# Auto-detect method
./rdsclient.sh -t Environment -v production

# Writer endpoint only
./rdsclient.sh -t Application -v api -e writer
```

Output:
```
Searching for databases with Environment=production...

1. [Aurora] analytics-cluster (aurora-postgresql): analytics-cluster.cluster-abc.us-east-2.rds.amazonaws.com
2. [Aurora] analytics-cluster (aurora-postgresql): analytics-cluster.cluster-ro-abc.us-east-2.rds.amazonaws.com
3. [RDS] reports-db (postgres): reports-db.ghi789.us-east-2.rds.amazonaws.com

Select database (1-3): 1
Auto-detecting authentication method...
Connecting to analytics-cluster as admin...
```

### Specify Authentication

```bash
# IAM authentication
./rdsclient.sh -t Name -v prod-db -a iam

# Manual authentication
./rdsclient.sh -u appuser -a manual

# Secrets Manager
./rdsclient.sh -t Application -v api -a secret
```

### Aurora Endpoints

```bash
# Writer only
./rdsclient.sh -t Environment -v prod -e writer

# Reader only
./rdsclient.sh -t Environment -v prod -e reader

# Both (default)
./rdsclient.sh -t Environment -v prod
```

### Disable SSL

```bash
./rdsclient.sh -t Environment -v dev -s false
```

### With awsenv

If wrapper scripts are installed, rdsclient works directly:

```bash
./rdsclient.sh -t Environment -v prod
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
- Requires `-u` flag for username
- Password not stored or logged

**Requirements**:
- Valid database username via `-u`

## Supported Databases

| Engine | Client | Auth Support |
|--------|--------|--------------|
| PostgreSQL / Aurora PostgreSQL | psql | IAM, Secret, Manual |
| MySQL / Aurora MySQL / MariaDB | mysql | IAM, Secret, Manual |
| Oracle (EE, SE2, CDB variants) | sqlplus | Secret, Manual |
| SQL Server (EE, SE, EX, Web) | sqlcmd | Secret, Manual |

All clients run in Docker containers with SSL enabled by default.

## Notes

- Auto-connects with single match
- Database clients run in Docker (auto-managed)
- SSL enabled by default
- Containers auto-cleaned on exit
- Cannot run inside awsenv container (use wrapper scripts)
- Tag filtering is case-sensitive
- IAM tokens expire after 15 minutes
