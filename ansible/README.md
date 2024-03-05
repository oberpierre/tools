
# Ansible Playbooks

This directory contains a set of Ansible playbooks designed to automate the initial setup and configuration of servers.
The playbooks are designed to be run with a non-root user being able to elevate his privileges. The exception being [`create_users.yml`](./create_users.yml), as it the expecation is that such a user will be created using it first. Find more information and instructions on how to run as a non-root user in the playbook file.

## Getting started

You need to install ansible on your control node (the one you intend to execute playbooks from and manage your servers). See [Ansible installation guide](https://docs.ansible.com/ansible/latest/installation_guide/intro_installation.html#control-node-requirements).

## Features

- **User Management** ([`create_users.yml`](./create_users.yml)): Create users and set up SSH keys for secure login.

## Usage

1. **Set Up Ansible Inventory**: Create an inventory file (see [`example_inventory.yml`](./example_inventory.yml)) with the details of the servers you wish to manage.
1. **Define Host Variables**: Use the `host_vars` directory to define variables specific to each host (see [`example.com.yml`](./host_vars/example.com.yml)), such as user details and SSH keys.
1. **Create Ansible Vault** (optional): Create a ansible vault file in the `vars` directory (see [`example_user_vault.yml`](./vars/example_user_vault.yml)), required if you want to use [`create_users.yml`](./create_users.yml) to set up users with passwords.
1. **Run Playbooks**: Execute the Ansible playbooks to perform the desired administration tasks, replacing `example_inventory.yml` with the path to your ansible inventory file.

    - [`create_users.yml`](./create_users.yml): Make sure you have prepared a vault file (see [`example_user_vault.yml`](./vars/example_user_vault.yml) for instructions) storing the password for your users, afterwards you may execute the script like this:
        - When executing as root:
            ```
            ansible-playbook -i example_inventory.yml --user root --ask-vault-pass --ask-pass create_users.yml
            ```
        - Or when executing as a user with privileged access (i.e. admin):
            ```
            ansible-playbook -i example_inventory.yml --user admin --ask-vault-pass --ask-become-pass create_users.yml
            ```
            **NOTE:** Uncomment the `become: true` directives in the playbook.
