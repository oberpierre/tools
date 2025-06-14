# Tools Collection

This repository is a collection of tools and scripts designed to simplify and automate various tasks. Currently, it focuses on system administration automation using Ansible.

## Structure

The project is organized into subdirectories, each dedicated to a specific type of tool or utility. Here is an overview of the current structure:

- [`/ansible`](./ansible/) - Contains Ansible playbooks and roles for initial server setup and configuration.

## Getting Started

To use the tools in this repository, clone it to your machine and refer to the getting started sections in the subdirectories README.

## Formatting

This project uses Prettier to enforce consistent styling. To format the code, run the following commands from the repository root:

```bash
npm install
npm run format
```

> Note: For YAML files, Prettier does not reformat content within literal blocks (indicated by `|`). This means inline Jinja templates or shell commands using pipes within these blocks will require manual formatting. For inline Jinja templates, they may be extracted into separate `.j2` template files for better manageability and to enable formatting.
