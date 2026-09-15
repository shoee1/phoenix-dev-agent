# Phoenix Dev Agent

Phoenix Dev Agent is a project-scoped development/deployment service for the Phoenix Unraid server.

Only applications explicitly registered as projects are managed. Unregistered Unraid containers are not enrolled.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/shoee1/phoenix-dev-agent/main/bootstrap.sh | bash
```

The bootstrap pulls the stable release manifest, verifies the installer SHA-256, downloads the release payload, verifies its SHA-256, then installs the service.

After installation, future updates use the persisted release channel:

```bash
phoenix-dev update
```

Current stable release: **v1.0.1**.
