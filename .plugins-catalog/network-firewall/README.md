# network-firewall

Before a deployment: reports database, cache and queue ports (MySQL 3306, PostgreSQL 5432, Redis 6379, MongoDB 27017, Elasticsearch 9200, RabbitMQ 5672, memcached 11211) that the template would publish on all host interfaces instead of keeping them internal.

- **Category:** advanced
- **Version:** 2.0.0
- **Hooks:** `pre-deploy`
- **Tags:** firewall, ports, security

## Install

Plugins page → Install, or `POST /plugins/catalog/network-firewall/install`, then enable it.
Hooks receive the DCS context on stdin and run with the environment described in
[.plugins/README.md](../../.plugins/README.md); output and exit codes land in the plugin's execution log.
