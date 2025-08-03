# Kubernetes Deployment Guide

This guide explains how to use the reusable [deploy-to-k8s](.github/workflows/deploy-to-k8s.yml) workflow to deploy containerized applications to your Kubernetes cluster via CI/CD pipelines.

## Prerequisites

Before using the deployment system, ensure your Kubernetes cluster has:

1. **NGINX Ingress Controller** - Install using [`k8s_setup_nginx.yml`](ansible/k8s_setup_nginx.yml)
2. **Certificate Manager** - Install using [`k8s_deploy_cert_manager.yml`](ansible/k8s_deploy_cert_manager.yml)
3. **Loadbalancer** (i.e. MetalLB for bare metal clusters) - Install using [`k8s_setup_metallb.yml`](ansible/k8s_setup_metallb.yml)

See the [Ansible README](ansible/README.md) for detailed setup instructions.

## Quick Start

### 1. Prepare Your Variables File

Create a variables file for your application deployment:

```yaml
# vars/my-app-prod.yml
app_name: my-app
app_namespace: production
app_folder: apps/my-app-prod/
app_domains:
  - myapp.example.com
  - www.myapp.example.com
container_image: ghcr.io/username/my-app:latest
container_port: 3000
service_port: 80
replicas: 3

# Registry authentication (for private repositories)
registry:
  host: ghcr.io
  username: username
  password: "{{ lookup('ansible.builtin.env', 'REGISTRY_PASSWORD') }}"
```

### 2. Configure Repository Secrets

In your repository, configure these secrets:

- `ANSIBLE_INVENTORY`: Content of your Ansible inventory file. Any valid inventory format is valid, see [How to build your inventory](https://docs.ansible.com/ansible/latest/inventory_guide/intro_inventory.html). Example:

  ```INI
  # INI file format
  cluster.example.com ansible_user=deploy ansible_python_interpreter=/usr/bin/python3
  ```

  > **Note**: Specify the user to be connected to in the inventory file. Follow a least privileges method, the user does not need to be root or have elevated privileges, if nothing is specified Ansible's default is trying to connect to the root user.
  >
  > Ansible will target all hosts specified in the inventory using its default `all` group. Therefore, specify only one controller node per cluster, as Kubernetes will handle propagating workloads and resource definitions within the cluster.

  The user that is being connected to should have a valid kubernetes config at `~/.kube/config`. You may use [k8s_create_sa.yml](ansible/k8s_create_sa.yml) in order to generate one, the service account should have the following rules:

  ```yaml
  sa_rules:
    - apiGroups: [""]
      resources: ["namespaces"]
      verbs: ["get", "create", "patch"]
    - apiGroups: ["apps", "extensions", "networking.k8s.io", ""]
      resources:
        - deployments
        - services
        - ingresses
      verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
    - apiGroups: [""]
      resources: ["secrets"]
      verbs: ["get", "create", "update", "patch"]
  ```

- `SSH_PRIVATE_KEY`: The SSH private key for accessing your hosts user. Password authentication is **not** supported.
- `SSH_KNOWN_HOSTS`: SSH fingerprints for your servers for secure connections.

### 3. Use in your CI/CD pipeline

Use the deployment playbook in your CI/CD pipeline in your project (i.e. github.com/username/my-app):

```yaml
name: Deploy container

jobs:
  deploy:
    uses: oberpierre/tools/.github/workflows/deploy-to-k8s.yml@v1
    with:
      ansible_var_file: vars/my-app-prod.yml
    secrets:
      ansible_inventory_content: ${{ secrets.ANSIBLE_INVENTORY }}
      registry_password: ${{ secrets.GITHUB_TOKEN }}
      ssh_known_hosts: ${{ secrets.SSH_KNOWN_HOSTS }}
      ssh_private_key: ${{ secrets.SSH_PRIVATE_KEY }}
```
