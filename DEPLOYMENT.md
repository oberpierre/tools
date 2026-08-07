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

## Multi-Workload Deployments

The Quick Start above deploys one Deployment behind one Ingress. Some applications are not shaped that way: a set of background workers and scheduled jobs that share a namespace and central datastores, none of which necessarily serve HTTP. For this shape, set the `playbook` input to `k8s_deploy_workloads.yml` instead of relying on the default.

Like `k8s_deploy_app.yml`, this playbook creates a container registry pull secret named `{{ app_name }}-regcred` when the var file declares `registry` (see the Ansible Variables table below), and every workload's pod spec references it. It also runs [`roles/app_platform`](ansible/roles/app_platform) first, which registers the application's namespace, Postgres databases and Redis ACL users against the cluster's central Postgres and Redis instances (`k8s_deploy_postgresql.yml`, `k8s_deploy_redis.yml`), and writes their resulting credentials into namespace Secrets. None of that requires the calling pipeline to hold the datastores' admin credentials: the role reads those from the cluster itself.

### 1. Prepare Your Variables File

```yaml
# vars/my-app-workloads.yml
app_name: my-app
app_namespace: my-app

# Optional. Registry authentication for private images, the same shape as the Quick
# Start's registry block above. Every workload's pod spec gets an imagePullSecrets
# entry pointing at the resulting Secret when this is declared.
registry:
  host: ghcr.io
  username: my-app-bot
  password: "{{ lookup('ansible.builtin.env', 'REGISTRY_PASSWORD') }}"

# Optional. Each entry registers a role and database against the cluster's central
# PostgreSQL instance, creating either if missing and always (re)setting the password.
postgres_databases:
  - name: my_app_db
    user: my_app
    password: "{{ app_db_password }}"

# Optional. Each entry registers an ACL user against the cluster's central Redis
# instance. `acl` is the raw ACL rule string this application needs (key patterns and
# command categories); this repo never assumes or writes one on your behalf. The name
# must not be "default" and the password must not be empty.
redis_users:
  - name: my-app
    password: "{{ app_redis_password }}"
    acl: "~my-app:* +@read +@write +@connection"

# Optional. Written as Secrets into app_namespace, one Secret per top-level key. Each
# key's value becomes that Secret's stringData verbatim, so nested keys become env var
# names verbatim once referenced via a workload's env_from below.
app_secrets:
  my-app-postgres:
    POSTGRES_HOST: postgresql.data-services.svc.cluster.local
    POSTGRES_PORT: "5432"
    POSTGRES_DB: my_app_db
    POSTGRES_USER: my_app
    POSTGRES_PASSWORD: "{{ app_db_password }}"
  my-app-redis:
    REDIS_HOST: redis-master.data-services.svc.cluster.local
    REDIS_PORT: "6379"
    REDIS_USERNAME: my-app # must match a redis_users name above
    REDIS_PASSWORD: "{{ app_redis_password }}"

# Required. One entry per Deployment or CronJob to deploy.
workloads:
  - name: worker
    kind: Deployment # Deployment | CronJob
    image: "{{ worker_image }}"
    replicas: 1
    env_from: [my-app-postgres, my-app-redis] # Secret names above, applied as envFrom
    resources:
      requests: { cpu: 100m, memory: 128Mi }
      limits: { cpu: 500m, memory: 512Mi }
    # service: and ingress: omitted -> no Service, no Ingress created for this workload
  - name: nightly-job
    kind: CronJob
    schedule: "0 3 * * *" # standard cron syntax
    image: "{{ nightly_job_image }}"
    env_from: [my-app-postgres]
  - name: frontend
    kind: Deployment
    image: "{{ frontend_image }}"
    replicas: 2
    env_from: [my-app-postgres]
    # A workload with `service` but no `ingress` gets a ClusterIP Service only. Both
    # together get a Service plus an Ingress with a cert-manager-issued TLS certificate,
    # honoring the same cluster_issuer_name variable as the Quick Start above (default
    # letsencrypt-prod; see the Ansible Variables table below).
    service:
      port: 8000
    ingress:
      hosts: [my-app.example.com]
```

Every field the template applies a default to (`imagePullPolicy: IfNotPresent`, a non-root pod `securityContext`, `restartPolicy: OnFailure` for CronJobs) is not settable per workload; these are the same for every workload this playbook deploys. `runAsNonRoot: true` means the container image must already run as a non-root user, or the pod fails to start.

`app_db_password`, `app_redis_password`, `worker_image`, `nightly_job_image` and `frontend_image` above are plain variable names, not `lookup('env', ...)`: nothing puts values into the `ansible-playbook` process's environment for this path, only the `ansible_extra_vars` secret does (see [Secrets](#secrets) below). A key the overlay does not supply renders empty rather than undefined, since the var file references it directly; `roles/app_platform` rejects an empty password by name, which is what turns a missing overlay key into a readable failure rather than a silently blank credential.

Beyond the service account rules shown in the Quick Start above, this path additionally needs:

```yaml
sa_rules:
  - apiGroups: ["batch"]
    resources: ["cronjobs"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list"]
  - apiGroups: [""]
    resources: ["pods/exec"]
    verbs: ["create"]
  - apiGroups: [""]
    resources: ["secrets"]
    resourceNames: ["postgresql-credentials", "redis-credentials"]
    verbs: ["get"]
```

`cronjobs` and `pods` get/list back the wait after applying: the playbook waits for every Deployment to reach its declared `replicas` and confirms every CronJob exists, failing the pipeline while the registry token is still alive if either does not happen. `pods/exec` is `roles/app_platform` registering Postgres roles and Redis ACL users by executing into the central `postgresql-0` and `redis-master-0` pods in `data-services`; the two named `secrets` are those pods' admin credentials, read to authenticate as them.

### 2. Use in your CI/CD pipeline

```yaml
name: Deploy workloads

jobs:
  deploy:
    uses: oberpierre/tools/.github/workflows/deploy-to-k8s.yml@v1
    with:
      playbook: k8s_deploy_workloads.yml
      ansible_var_file: vars/my-app-workloads.yml
    secrets:
      ansible_inventory_content: ${{ secrets.ANSIBLE_INVENTORY }}
      ssh_known_hosts: ${{ secrets.SSH_KNOWN_HOSTS }}
      ssh_private_key: ${{ secrets.SSH_PRIVATE_KEY }}
      ansible_extra_vars: ${{ secrets.MY_APP_EXTRA_VARS }}
```

`MY_APP_EXTRA_VARS` is a single JSON secret carrying `app_db_password`, `app_redis_password`, `worker_image`, `nightly_job_image` and `frontend_image` (whatever your workloads and registrations reference): the values the committed var file cannot hold. Build it however suits your pipeline, for example a prior job's output assembled from repository secrets and the image references it just pushed.

## Configuration Options

### Ansible Variables

| Variable              | Required | Description                                                                                              | Example                                                      |
| --------------------- | -------- | -------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------ |
| `app_name`            | X        | Application name (used for Kubernetes resources)                                                         | `my-app`                                                     |
| `app_namespace`       | X        | Kubernetes namespace                                                                                     | `production`                                                 |
| `app_folder`          | X        | Local manifest storage path. You may use a common parent folder like `apps` to group deployments.        | `apps/{{ app_name }}/`                                       |
| `app_domains`         | X        | List of domains for ingress                                                                              | `["app.example.com"]`                                        |
| `container_image`     | X        | Container image to deploy                                                                                | `ghcr.io/user/app:latest`                                    |
| `container_port`      |          | Container port                                                                                           | Default: `8080`                                              |
| `service_port`        |          | Service port                                                                                             | Default: `80`                                                |
| `replicas`            |          | Number of replicas                                                                                       | Default: `1`                                                 |
| `wait_for_deployment` |          | Whether to wait for the deployment to reach `READY` status before completing.                            | Default: `true`                                              |
| `cluster_issuer_name` |          | cert-manager cluster issuer name                                                                         | Default: `letsencrypt-prod`                                  |
| `registry.host`       |          | Package registry host. Required for private package registry authentication.                             | `ghcr.io`, `docker.io`, etc.                                 |
| `registry.username`   |          | Username to authenticate against package registry. Required for private package registry authentication. | `user`                                                       |
| `registry.password`   |          | Password to authenticate against package registry. Required for private package registry authentication. | `"{{ lookup('ansible.builtin.env', 'REGISTRY_PASSWORD') }}"` |

> **Note**: Do not directly specify secrets in your var file. Use the `REGISTRY_PASSWORD` environment variable like above.

### Workflow Variables

See also [Workflow](.github/workflows/deploy-to-k8s.yml) inputs/secrets section.

#### Inputs

| Variable         | Required | Description                                                                                                                                                                                                                                            | Example                                                                                                                                                                                                                                                             |
| ---------------- | -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| ansible_var_file | X        | Path to the variable file (relative to the calling repository root) to pass to ansible. DO NOT specify secrets here.                                                                                                                                   | `vars/my-app-prod.yml`                                                                                                                                                                                                                                              |
| container_image  |          | Container image to deploy. For dynamic generation of the container image name, will be made available as CONTAINER_IMAGE environment variable and can be referenced using `"{{ lookup('ansible.builtin.env', 'CONTAINER_IMAGE') }}"` in your var file. | Enables dynamically targeting specific versions of the container, potentially based on an output of your previous jobs like `${{ needs.release.outputs.container_tag }}`, instead of relying on `latest` or manually updating the version in your Ansible var file. |
| playbook         |          | Playbook in `tools/ansible` to run. See [Multi-Workload Deployments](#multi-workload-deployments) for the alternative shape this enables.                                                                                                              | Default: `k8s_deploy_app.yml`                                                                                                                                                                                                                                       |

#### Secrets

| Variable                  | Required | Description                                                                                                                                                                                                                                         | Example                                                                                                                                           |
| ------------------------- | -------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| ansible_inventory_content | X        | Content of the Ansible inventory file to use for deployment.                                                                                                                                                                                        | `cluster.example.com ansible_user=deploy`                                                                                                         |
| registry_password         |          | Password for the container registry. May be a personal access token, GITHUB_TOKEN, or password. GITHUB_TOKEN is recommended for ghcr.io                                                                                                             | `${{ secrets.GITHUB_TOKEN }}`                                                                                                                     |
| ssh_known_hosts           |          | SSH known hosts content for secure connections.                                                                                                                                                                                                     | Content of the known_hosts file, i.e. generated by `ssh-keyscan cluster.example.com > my_known_hosts`                                             |
| ssh_private_key           |          | SSH private key for accessing the deployment target.                                                                                                                                                                                                | SSH private key compatible with `webfactory/ssh-agent` action, see [Creating SSH Keys](https://github.com/webfactory/ssh-agent#creating-ssh-keys) |
| ansible_extra_vars        |          | Optional JSON object of additional Ansible variables, written to a file and passed as a second `--extra-vars` after `ansible_var_file`. Outranks the committed var file wherever both define a key. Never put secrets in `ansible_var_file` itself. | `${{ secrets.MY_APP_EXTRA_VARS }}`                                                                                                                |
