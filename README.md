# Tools &middot; [![CI](https://github.com/oberpierre/tools/actions/workflows/code-quality.yml/badge.svg)](https://github.com/oberpierre/tools/actions/workflows/code-quality.yml)

This repository is a collection of tools and scripts designed to simplify and automate various tasks. It focuses on system administration automation using Ansible and provides a reusable GitHub workflow to deploy containerized applications to Kubernetes clusters via CI/CD pipelines.

## Quick Links

- **[Ansible Infrastructure Setup](ansible/README.md)** - Server setup and Kubernetes cluster management
- **[Deployment Guide](DEPLOYMENT.md)** - Deploy applications to Kubernetes via GitHub reusable workflow

## Structure

The project is organized into subdirectories, each dedicated to a specific type of tool or utility:

- **[`/ansible`](./ansible/)** - Contains Ansible playbooks and roles for initial server setup and configuration.

## Getting Started

Clone the repository to your machine and refer to the [Quick Links](#quick-links) section to get detailed instructions based on what you'd like to use.

## Formatting

This project uses Prettier to enforce consistent styling. To format the code, run the following commands from the repository root:

```bash
npm install
npm run format
```

> Note: For YAML files, Prettier does not reformat content within literal blocks (indicated by `|`). This means inline Jinja templates or shell commands using pipes within these blocks will require manual formatting. For inline Jinja templates, they may be extracted into separate `.j2` template files for better manageability and to enable formatting.
