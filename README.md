## 📑 Table of Contents
- [Overview](#overview)
  - [Repository Structure](#structure)
  - [Helm Chart](#helmchart)
  - [Dockerfile](#dockerfile)
  - ['start.sh' script](#script)
  - [Permissions on Cluster Level](#permissions)
  - [Required Secrets & Expiration](#secrets)
     - [Registration of Self-Hosted Agents](#registration)
     - [Git Authentication](#authentication)
  - [Limitations](#limitations)
  - [Prerequisites](#prerequisites)

---
<a id="overview"></a>

# 🧩 Overview

This repository provides a complete **Helm chart** and supporting files for deploying **self-hosted AzDO Agents** in **Azure Red Hat Openshift** (ARO).  
The deployment supports **KEDA-based auto-scaling job runners**, integrating seamlessly with Azure Pipelines.

---
<a id="structure"></a>

## 📁 Repository Structure

| File  | Description |
|------------------|-------------|
| `templates/buildConfig.yaml` | Defines an OpenShift `BuildConfig` resource that builds the agent image using the specified `Dockerfile`  from this Git repository. |
| `templates/imagestream.yaml` | Creates an `ImageStream` in OpenShift to store and version the built container images. |
| `templates/pod.yaml` | Deploys the template Azure DevOps Agent pod, which registers an offline agent. |
| `templates/kedaJob.yaml` | Defines a KEDA ScaledJob, enabling dynamic agent scaling based on Azure Pipelines workload. |
| `templates/serviceaccount.yaml` | Creates a dedicated ServiceAccount for running the agent with appropriate permissions. |
| `templates/triggerAuthentication.yaml` | Configures KEDA authentication using a secret containing the Azure DevOps PAT and organization URL. |
| `values.yaml` | Centralized configuration for image build, resource limits, secrets, and KEDA parameters. |
| `Dockerfile` | The definition of the base image for the Azure DevOps Agent, preloaded with all the neccessary tools. |
| `start.sh` | Entrypoint script that dynamically downloads, configures and runs the Azure Pipelines Agent. |

---
<a id="helmchart"></a>

## ⚙️ Helm Chart

This Helm chart supports two modes of operation:

#### **Template Agent Pod**
- A single pod is deployed directly & registers an offline agent in Azure DevOps to ensure the agent pool always contains at least one agent, preventing pipeline failures when no active agents exist.
- This pod exits immediately after registration, it is not restarted.

#### **2. KEDA-Scaled Job Agents**
- KEDA automatically scales agents dynamically based on the number of queued jobs in Azure DevOps.
- Agents run a single job, then terminate, ensuring resources are allocated only when needed.

#### Values Configuration (`values.yaml`):
Below are the parameters configurable values.

| Parameter | Description 
|-----|--------------|
| `namespace` | Target OpenShift namespace for deployment 
| `sourceSecret.name` | Secret name in ARO containing SSH private key for Git repository access 
| `image.buildConfig.enabled` | Enables internal image build via BuildConfig  
| `image.name` | Image name used for template pod and KEDA jobs 
| `image.tag` | Image tag 
| `image.registry` | OpenShift internal image registry 
| `secret.name` | Secret name in ARO storing Azure DevOps credentials 
| `serviceAccount.name` | Name of ServiceAccount used by pods 
| `azdo.poolName` | Azure DevOps agent pool name 
| `resources` | Pod resource requests and limits 

---       
<a id="dockerfile"></a>

## 🧱 Dockerfile 

The provided `Dockerfile` builds a robust base image containing:
- Azure DevOps Agent runtime requirements (.NET SDK 6.0)
- Development and automation tools, including:
  - PowerShell
  - Azure CLI
  - Terraform 
  - TFLint 
  - Git LFS
  - Podman (with Docker wrapper)
- Runs as a non-root user (`azdo_agent`, UID 1001)

---
<a id="script"></a>

## 🚀 'start.sh' script

The script (start.sh) dynamically registers and runs an Azure DevOps Agent:
1. **Validates Environment Variables**
   - Ensures `AZP_URL` and `AZP_TOKEN` are set.

2. **Downloads Latest Agent**
   - Fetches the newest compatible Azure Pipelines agent package for Linux.

3. **Configures the Agent**
   - Runs `config.sh` in unattended mode with supplied parameters:
     - Organization URL
     - PAT token
     - Agent pool name
     - Working directory

4. **Handles Template Agent Logic**
   - It checks the AZP_AGENT_NAME environment variable to determine if the pod is a template agent.
   - If the agent name contains "agents-template", the pod exits immediately, leaving an offline agent in Azure DevOps for pool availability.
   - To ensure the script recognizes the pod as a template agent, `AZP_AGENT_NAME` is explicitly set in the `pod.yaml` definition.
   - Tackled by this part:
```hcl
if ! grep -q "azdo-template" <<< "$AZP_AGENT_NAME"; then
  echo "Cleanup Traps Enabled"
  trap 'cleanup; exit 0' EXIT
  trap 'cleanup; exit 130' INT
  trap 'cleanup; exit 143' TERM
else
  # directly exit the template agent
  trap - EXIT
  exit 0
fi
```
> Note =>The template pod also has `restartPolicy` set to `Never`, to ensure it does not restart after exiting.

5. **Runs the Agent Once**
   - Uses `./run.sh --once` to process a single build job per pod execution.

---
<a id="permissions"></a>

## 🛡️ Permissions on Cluster Level
- The non-root user responsible for installing agent packages requires additional permissions to operate correctly.  
To accommodate this while maintaining cluster security, a **custom Security Context Constraint (SCC)** is created by cluster admins and assigned to the service account of the pods that run the `start.sh` script to install agent packages:
```hcl
# scc.yaml:
apiVersion: security.openshift.io/v1
kind: SecurityContextConstraints
metadata:
  name: azdo-agent-scc
allowHostDirVolumePlugin: false
allowHostIPC: false
allowHostNetwork: false
allowHostPID: false
allowHostPorts: false
allowPrivilegeEscalation: false
allowPrivilegedContainer: false
allowedCapabilities: null
defaultAddCapabilities: null
fsGroup:
  type: RunAsAny
groups: []
readOnlyRootFilesystem: false
requiredDropCapabilities:
  - ALL
runAsUser:
  type: MustRunAs
  uid: 1001 
seLinuxContext:
  type: MustRunAs
supplementalGroups:
  type: RunAsAny
users: []
volumes:
  - configMap
  - downwardAPI
  - emptyDir
  - persistentVolumeClaim
  - projected
  - secret
{{- end }}
fi
```
```hcl
# oc create -f scc.yaml
# oc adm policy add-scc-to-user azdo-agent-scc -z azdo-agent-sa
```
This SCC ensures that the pods running the script execute as non-root (UID 1001) while still having neccessary access permissions, required for package installation and temporary storage.

- If the solution is deployed via **ArgoCD**, some permissions must be granted to the **ArgoCD service account**, in order to be able to create the related KEDA resources (`scaledjobs` and `triggerauthentications`).

---
<a id="secrets"></a>

## 🔑 Required Secrets & Expiration

<a id="registration"></a>

### Registration of Self-Hosted Agents:
**Secret:** `azdo-secret`  (Manually created in the the specified namespace) 

**Purpose:** Required for agent registration, the implementation depends on it.

It contains:
- AZP_URL="https://dev.azure.com/>azdo-organization<"
- AZP_POOL=">azdo-agent-pool-name<"
- AZP_TOKEN=">personal-access-token<"
    - **Expiration:** 30 days   
    - **Required Permissions:**
  Agent Pools: *(Read & Manage)*, Build: *(Read & Execute)*,Code: *(Read, Write & Manage)*, Project and Team: *(Read)*, User Profile: *(Read)*
    - **Rotation:**  
      - This is AzDO PAT created on user level, when it's near expiration, generate a new PAT with the permissions above.  
      - Update the `AZP_TOKEN` value on the secret in ARO.
      - Delete the template pod so the new agent takes place.

>  Note: For security purposes, it is enforced on AzDO organization level for PATs to have a **30-day maximum duration**.

<a id="authentication"></a>

###  Git Authentication:
**Secret:** `>git-ssh-key<` (Manually created in the ARO namespace)

**Purpose:** The Dockerfile build process uses it to authenticate against this private Git repo where the Dockerfile is stored. 

It just contains the **private SSH key**.
The **public key** must be registered in **Azure DevOps** to allow access.

> Note: Regarding expiration, the SSH keys will not expire, but their validity evaluation inside Azure DevOps will, so we must re-generate or re-upload the keys.

**Rotation:** Required only when building a new image version with additional tools.
This is AzDO SSH-key created on user level.
When the SSH key in AzDO is near expiration:
1. Generate a new SSH key pair locally  
2. Create a new SSH key in your Azure DevOps profile & provide the **new public key**
3. Update the secret in ARO with the **new private key**

---
<a id="limitations"></a>

## ⚠️ Limitations
- The Azure DevOps organization can be limited to **a specific number of parallel jobs** for **self-hosted agents**, which affects build concurrency and queue times - for example if we have 10 parallel jobs defined, **no more than 10 builds can run simultaneously** in organization level including builds from other projects that can be using other agent pools.

---
<a id="prerequisites"></a>

## ▶ Prerequisites
- The Agent Pool in AzDO is already in place.
- The PAT & SSH key are defined in AzDO & implemented as secrets in ARO.
- KEDA operator is already installed in ARO.

