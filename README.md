# Postgres Nebula ☁️

Generic PostgreSQL DBA toolkit for AWS cloud operations - reusable scripts for database management and infrastructure automation.

## Overview

This repository contains production-ready, generic scripts and tools for managing PostgreSQL databases in AWS environments.

## Contents

### 📁 Bash Scripts (`/bash`)

**AWS Management**:
- **aws_search.sh** / **aws_search_instance.sh** - Search and discover AWS EC2 instances
- **add_ssh_inbound.sh** - Add SSH inbound rules to security groups
- **resize-ebs-vol.sh** - Resize EBS volumes with proper checks
- **increase_iops.sh** - Increase IOPS for EBS volumes

**PostgreSQL Management**:
- **pg-clone.sh** - Clone PostgreSQL instances for testing/backup
- **find_pg_same_az.sh** - Find PostgreSQL instances in the same availability zone
- **resize-cluster.sh** - Resize PostgreSQL cluster instances with safety checks (primary/secondary/DR)
- **mothballing_practical.sh** - Decommission PostgreSQL clusters (procedures template)

**AWS Tagging**:
- **verify_tags.sh** - Verify and audit AWS resource tags

**Utilities**:
- **tmux.sh** - tmux quick reference and usage guide

## Prerequisites

- PostgreSQL 12+
- AWS CLI configured with appropriate credentials
- Bash 4.0+
- jq (for JSON parsing in bash scripts)

## Usage

### AWS Operations

```bash
# Search for AWS instances
bash/aws_search_instance.sh <instance-name>

# Resize EBS volume
bash/resize-ebs-vol.sh <volume-id> <new-size>

# Clone PostgreSQL instance
bash/pg-clone.sh

# Resize cluster instance
bash/resize-cluster.sh -c 123 -r primary -t m5.2xlarge -i i-0123456789abcdef0

# Decommission cluster (procedures template)
bash/mothballing_practical.sh
```

## Configuration

Most scripts expect standard AWS and PostgreSQL environment variables:
- `AWS_REGION` - AWS region for operations
- `PGHOST` - PostgreSQL host
- `PGPORT` - PostgreSQL port
- `PGDATABASE` - PostgreSQL database name
- `PGUSER` - PostgreSQL username
- `PGPASSWORD` - PostgreSQL password

## Repository Structure

**Public Scripts**: Generic, reusable automation tools suitable for any PostgreSQL/AWS environment.

**Sensitive Folder** (not in repository): Company-specific scripts with internal hostnames, credentials, or proprietary information are kept in a local `sensitive/` folder that is gitignored.

## Safety Notes

⚠️ **Important**: Many of these scripts perform critical database and infrastructure operations:
- Always test in a non-production environment first
- Review and understand each script before execution
- Ensure proper backups are in place
- Use appropriate IAM roles and permissions
- Follow your organization's change management procedures
- Sanitize any company-specific information before sharing

## Contributing

This is a personal toolkit repository. Feel free to fork and adapt for your own use.

## License

MIT License - See LICENSE file for details

## Author

Hossam Aladdin - Database Administrator specializing in PostgreSQL and AWS infrastructure

---

*Built with ☕ and ❤️ for PostgreSQL on AWS*
