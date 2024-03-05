
# Ansible Playbooks

This directory contains a set of Ansible playbooks designed to automate the initial setup and configuration of servers. 

## Getting started

You need to install ansible on your control node (the one you intend to execute playbooks from and manage your servers). See [Ansible installation guide](https://docs.ansible.com/ansible/latest/installation_guide/intro_installation.html#control-node-requirements).

## Features

- **User Management** ([`create_users.yml`](./create_users.yml)): Create users and set up SSH keys for secure login.

## Usage

1. **Set Up Ansible Inventory**: Create an inventory file with the details of the servers you wish to manage.
1. **Define Host Variables**: Use the `host_vars` directory to define variables specific to each host, such as user details and SSH keys.
1. **Create Ansible Vault** (optional): Create a ansible vault file in the `vars` directory, required if you want to use [`create_users.yml`](./create_users.yml) to set up users with passwords.
1. **Run Playbooks**: Execute the Ansible playbooks to perform the desired administration tasks.

Example:

```bash
ansible-playbook -i ansible_inventory.yml create_users.yml
```
