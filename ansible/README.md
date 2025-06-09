# Ansible Playbooks

This directory contains a set of Ansible playbooks designed to automate the initial setup and configuration of servers.
The playbooks are designed to be run with a non-root user being able to elevate his privileges. The exception being [`create_users.yml`](./create_users.yml), as the expectation is that you will run it with root after provisioning your server, to create the initial non-root administrative user. This user can then be used for subsequent playbook executions. Find more information and instructions on how to run as a non-root user in the playbook file or in the [Usage](#usage) section below.

## Getting started

### Prerequisites

- Python 3.x
- `pip` (Python package installer)

### Venv setup (Recommended)

Using a Python virtual environment is highly recommended to manage project dependencies and avoid conflicts with other Python projects or your system's global Python packages.

**Steps:**

1.  **Create a virtual environment:**
    Ensure you are in the `ansible` directory and run:

    ```bash
    cd ansible
    python3 -m venv .venv
    ```

    This will create a `.venv` directory in your project.

2.  **Activate the virtual environment:**

    - On macOS and Linux:
      ```bash
      source .venv/bin/activate
      ```
    - On Windows (Git Bash or WSL):
      ```bash
      # Git bash or WSL
      source .venv/Scripts/activate
      # CMD or PowerShell
      .\.venv\Scripts\activate
      ```
      Your shell prompt should change to indicate that the virtual environment is active.

3.  **Install Ansible and other dependencies:**
    With the virtual environment active, install the required packages using the `requirements.txt` file:
    ```bash
    pip install -r requirements.txt
    ```

### Global installation

You may also install Ansible globally on the machine you intend to run the playbook from to manage your servers. See [Ansible installation guide](https://docs.ansible.com/ansible/latest/installation_guide/intro_installation.html#control-node-requirements).

## Features

- **User Management** ([`create_users.yml`](./create_users.yml)): Create users and set up SSH keys for secure login.
- **Security**:
  - [`enable_ufw_ssh.yml`](./enable_ufw_ssh.yml): Enables UFW firewall with allow rule for SSH connections
  - [`disable_pw_auth.yml`](./disable_pw_auth.yml): Disallows empty passwords and password authentication using sshd config.
    > You will lose access to the server if you have not yet set up a user with SSH keys (using [`create_users.yml`](./create_users.yml) or otherwise)!
- **Kubernetes**:
  - [`k8s_setup.yml`](./k8s_setup.yml): Satisfies Kubernetes prerequisites by installing the container runtime, opening required ports, etc.
  - [`k8s_init_cluster.yml`](./k8s_init_cluster.yml): Initializing cluster using kubeadm and installing container network interface (CNI)
  - [`k8s_join_cluster.yml`](./k8s_join_cluster.yml): Joining the cluster for additional control plane and worker nodes. If a control plane is also serving as a worker, by being defined in the controller and worker list of your inventory file, it will "untaint" the control plane so it may be targeted by the scheduler to schedule pods.
    > Make sure you understand the security implications if you want to use your control plane as a worker! See: https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/#control-plane-node-isolation
  - [`k8s_setup_metallb.yml`](./k8s_setup_metallb.yml): Enabling LoadBalancer type resources using [MetalLB](https://metallb.universe.tf/) implementation. This may be needed if you run a baremetal node or if your cluster is running on a cloud platform that is not supported by Kubernetes, expressed by resources of type LoadBalancer remaining in "pending" state indefinitely when created.
  - [`k8s_setup_nginx.yml`](./k8s_setup_nginx.yml): Installing [Ingress NGINX Controller](https://kubernetes.github.io/ingress-nginx/) to manage [Kubernetes Ingress resources](https://kubernetes.io/docs/concepts/services-networking/ingress/) enabling external access to services in your cluster.
  - [`k8s_deploy_cert_manager.yml`](./k8s_deploy_cert_manager.yml): Installing [cert-manager](https://cert-manager.io/docs/) to issue and renew TLS certificates using Let's Encrypt certificate authority. (Other certificate authorities are supported as well. See [cert-manager docs](https://cert-manager.io/docs/configuration/))

## Usage

1. **Set Up Ansible Inventory**: Create an inventory file (e.g., `my_inventory.yml`) defining your "controller" and "worker" host groups. Refer to [`example_inventory.yml`](./example_inventory.yml) for structure and examples.
1. **Define Host Variables**: Customize variables for each host in the `host_vars` directory. See [`example.com.yml`](./host_vars/example.com.yml) for an example. This is where you'd typically define user details, SSH keys, and other host-specific settings.
1. **Create Ansible Vault** (optional but recommended for sensitive data): If [`create_users.yml`](./create_users.yml) will be used to set up users with passwords, or if you have other sensitive variables, create an Ansible Vault file (e.g., in the `vars` directory). See [`example_user_vault.yml`](./vars/example_user_vault.yml) for guidance on creating and using vault files.
1. **Run Playbooks**: Execute the desired Ansible playbooks. Replace `example_inventory.yml` with your actual inventory file path. It is crucial to review each playbook before execution, as they modify server configurations, install software, and manage security settings. The playbooks often contain comments with further hints and considerations. Here's an overview of the different playbooks and their use:

   - [`create_users.yml`](./create_users.yml): Make sure you have prepared an Ansible Vault file (see [`example_user_vault.yml`](./vars/example_user_vault.yml) for instructions) storing the password for your users. Afterwards, you may execute the script like this:

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

     > :warning: Execute this only after having set up a user with SSH keys. You will lose access to your server otherwise!

     ```
     ansible-playbook -i example_inventory.yml --user admin --ask-become-pass disable_pw_auth.yml
     ```

   - [`k8s_setup.yml`](./k8s_setup.yml):

     ```
     ansible-playbook -i example_inventory.yml --user admin --ask-become-pass k8s_setup.yml
     ```

   - [`k8s_init_cluster.yml`](./k8s_init_cluster.yml):

     > To install prerequisites, run `k8s_setup.yml` first!

     ```
     ansible-playbook -i example_inventory.yml --user admin --ask-become-pass k8s_init_cluster.yml
     ```

   - [`k8s_join_cluster.yml`](./k8s_join_cluster.yml):

     > Only run this after running `k8s_setup.yml` and `k8s_init_cluster.yml`!

     ```
     ansible-playbook -i example_inventory.yml --user admin --ask-become-pass k8s_join_cluster.yml
     ```

   - [`k8s_setup_metallb.yml`](./k8s_setup_metallb.yml):

     > The control plane running this job (init_controller) must be part of the kubernetes cluster! Configure metallb_addresses var in the vars or host_vars (see [`example.com.yml`](./host_vars/example.com.yml)).

     ```
     ansible-playbook -i example_inventory.yml --user admin --ask-become-pass k8s_setup_metallb.yml
     ```

   - [`k8s_setup_nginx.yml`](./k8s_setup_nginx.yml):

     > This playbook requires resources of type LoadBalancer to be supported to enable Ingress to route external traffic to your cluster's services. Ensure they are supported, and if necessary, enable them using `k8s_setup_metallb.yml`. You may also change the configuration in the playbook to support [NodePort services](https://kubernetes.github.io/ingress-nginx/deploy/baremetal/#over-a-nodeport-service), but this is not recommended except for testing or learning purposes.

     ```
     ansible-playbook -i example_inventory.yml --user admin --ask-become-pass k8s_setup_nginx.yml
     ```

   - [`k8s_deploy_cert_manager.yml`](./k8s_deploy_cert_manager.yml):
     ```
     ansible-playbook -i example_inventory.yml --user admin --ask-become-pass k8s_deploy_cert_manager.yml
     ```
