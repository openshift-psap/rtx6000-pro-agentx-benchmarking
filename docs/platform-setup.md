# Platform installation notes

The benchmark environment used **OpenShift Container Platform (OCP) 4.22** and **Red Hat OpenShift AI (RHOAI) 3.6-ea1** on the **beta** channel. The following notes summarize the platform setup; the benchmark runner connects to an already-running model endpoint.

| Component | Version |
|---|---|
| OCP | 4.22.0 |
| RHOAI | 3.6-ea1, beta channel |

## OCP installation summary

OCP was installed on Lenovo bare metal with a single-node OpenShift (SNO) control plane on a ThinkSystem SR675 V3 and an additional worker on a ThinkSystem SR650a V4. The initial installation used the **agent-based installer**, with a self-contained boot ISO generated locally and no bastion host.

1. Prepare the OCP installation and agent configuration, including static networking and a Red Hat pull secret, and generate the agent ISO with the OCP 4.22.0 installer.
2. Mount the ISO through the SR675 V3's BMC virtual media, boot the server, and wait for the SNO installation to complete.
3. Add the SR650a V4 worker using the Assisted Installer Day-2 **Add hosts** flow: configure its static networking and cluster DNS, boot its discovery ISO through BMC virtual media, and approve the node certificate signing requests.
4. Install Node Feature Discovery and the NVIDIA GPU Operator through OperatorHub, then apply the GPU ClusterPolicy.
5. Verify that both nodes are Ready and that their GPUs are detected before deploying the model service.

## RHOAI version

The OpenShift AI serving environment used **RHOAI 3.6-ea1** on the **beta** channel.
