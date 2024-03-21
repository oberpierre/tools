# Ansible Playbooks

This directory contains a set of Ansible playbooks designed to automate the initial setup and configuration of servers.
The playbooks are designed to be run with a non-root user being able to elevate his privileges. The exception being [`create_users.yml`](./create_users.yml), as the expectation is that you will run it with root after provisioning your server, to create such a user first. Find more information and instructions on how to run as a non-root user in the playbook file or in the [Usage](#usage) section below.

## Getting started

You need to install Ansible on your control node (the one you intend to execute playbooks from and manage your servers). See [Ansible installation guide](https://docs.ansible.com/ansible/latest/installation_guide/intro_installation.html#control-node-requirements).

## Features

- **User Management** ([`create_users.yml`](./create_users.yml)): Create users and set up SSH keys for secure login.
- **Security**: 
  - [`enable_ufw_ssh.yml`](./enable_ufw_ssh.yml): Enables UFW firewall with allow rule for SSH connections
  - [`disable_pw_auth.yml`](./disable_pw_auth.yml): Disallows empty passwords and password authentication using sshd config.
    > You will lose access to the server, if you have not yet set up a user with SSH keys (using [`create_users.yml`](./create_users.yml) or otherwise)!
- **Kubernetes**:
  - [`k8s_setup.yml`](./k8s_setup.yml): Satisfying Kubernetes prerequisites by installing container runtime, open required ports, etc.
  - [`k8s_setup_controller.yml`](./k8s_setup_controller.yml): Initializing cluster using kubeadm and installing container network interface (CNI) 
  - [`k8s_setup_worker.yml`](./k8s_setup_worker.yml): Joining the cluster for worker nodes. If a control plane is also serving as a worker, by being defined in the controller and worker list of your inventory file, it will "untaint" the control plane so it may be targeted by the scheduler to schedule pods.
    > Make sure you understand the security implications if you want to use you control plane as a worker! See: https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/#control-plane-node-isolation

## Usage

1. **Set Up Ansible Inventory**: Create an inventory file containing "controller" and "worker" host lists (see [`example_inventory.yml`](./example_inventory.yml)) with the details of the servers you wish to manage.
1. **Define Host Variables**: Use the `host_vars` directory to define variables specific to each host (see [`example.com.yml`](./host_vars/example.com.yml)), such as user details and SSH keys.
1. **Create Ansible Vault** (optional): Create an Ansible Vault file in the `vars` directory (see [`example_user_vault.yml`](./vars/example_user_vault.yml)), required if you want to use [`create_users.yml`](./create_users.yml) to set up users with passwords.
1. **Run Playbooks**: Execute the Ansible playbooks to perform the desired administration tasks, replacing `example_inventory.yml` with the path to your Ansible inventory file. It is advisable to review the different playbooks files before executing them, as they may provide further hints and considerations, and ultimately for the security of your servers as they may change configuration, create files, install packages, etc.. Here is a short overview of the different playbooks and their use:

    - [`create_users.yml`](./create_users.yml): Make sure you have prepared an Ansible Vault file (see [`example_user_vault.yml`](./vars/example_user_vault.yml) for instructions) storing the password for your users, afterwards you may execute the script like this:
        - When executing as root:
            ```
            ansible-playbook -i example_inventory.yml --user root --ask-vault-pass --ask-pass create_users.yml
            ```
        - Or when executing as a user with privileged access (i.e. admin):
            ```
            ansible-playbook -i example_inventory.yml --user admin --ask-vault-pass --ask-become-pass create_users.yml
            ```
            **NOTE:** Uncomment the `become: true` directives in the playbook.

    - [`enable_ufw_ssh.yml`](./enable_ufw_ssh.yml):
        ```
        ansible-playbook -i example_inventory.yml --user admin --ask-become-pass enable_ufw_ssh.yml
        ```

    - [`disable_pw_auth.yml`](./disable_pw_auth.yml):
        > :warning: Only execute this after you have set up a user with SSH keys, otherwise you will lose access to your server!
        ```
        ansible-playbook -i example_inventory.yml --user admin --ask-become-pass disable_pw_auth.yml
        ```

    - [`k8s_setup.yml`](./k8s_setup.yml):
        ```
        ansible-playbook -i example_inventory.yml --user admin --ask-become-pass k8s_setup.yml
        ```

    - [`k8s_setup_controller.yml`](./k8s_setup_controller.yml):
        > To install prerequisites, run `k8s_setup.yml` first!
        ```
        ansible-playbook -i example_inventory.yml --user admin --ask-become-pass k8s_setup_controller.yml
        ```

    - [`k8s_setup_worker.yml`](./k8s_setup_worker.yml):
        > Only run this after running `k8s_setup.yml` and `k8s_setup_controller.yml`!
        ```
        ansible-playbook -i example_inventory.yml --user admin --ask-become-pass k8s_setup_worker.yml
        ```