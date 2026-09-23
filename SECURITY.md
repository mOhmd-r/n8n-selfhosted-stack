# Security policy

## Reporting a vulnerability

Please do not disclose a suspected vulnerability in a public issue. Use GitHub's
private vulnerability-reporting flow for this repository. Include the affected
revision, prerequisites, impact, and a minimal reproduction when possible.

## Supported version

Security fixes are applied to the current default branch. Deployments should pin
reviewed application releases, keep the host and Docker Engine patched, and test
backups and restores before and after upgrades.

## Trust boundaries

This project does not secure the host, Docker daemon, DNS, certificate issuer,
remote SSH server, or object store. Treat `.env`, private keys, application state,
and every backup as sensitive. Hashes detect accidental corruption; they do not
authenticate data against an attacker who can replace both content and hashes.
