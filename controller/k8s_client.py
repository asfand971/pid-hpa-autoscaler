"""
k8s_client.py — Kubernetes API client for the PID controller.

Reads the current replica count and applies scaling decisions to the
go-plant Deployment in the default namespace.

Uses the in-cluster service account credentials mounted automatically
by Kubernetes. The RBAC permissions required are defined in rbac.yaml.
"""

import logging
from kubernetes import client, config

logger = logging.getLogger(__name__)


class KubernetesClient:
    def __init__(
            self,
            deployment_name: str = "go-plant",
            namespace: str = "default",
    ):
        """
        Parameters
        ----------
        deployment_name : Name of the Deployment to scale.
        namespace       : Kubernetes namespace containing the Deployment.
        """
        self.deployment_name = deployment_name
        self.namespace = namespace

        # Load in-cluster config (service account token + CA cert)
        # Falls back to kubeconfig for local development
        try:
            config.load_incluster_config()
            logger.info("Loaded in-cluster Kubernetes config.")
        except config.ConfigException:
            config.load_kube_config()
            logger.info("Loaded local kubeconfig (development mode).")

        self.apps_v1 = client.AppsV1Api()

    def get_current_replicas(self) -> int:
        """
        Return the current desired replica count for the Deployment.
        Returns 1 on error to fail safe.
        """
        try:
            deployment = self.apps_v1.read_namespaced_deployment(
                name=self.deployment_name,
                namespace=self.namespace,
            )
            replicas = deployment.spec.replicas or 1
            logger.debug("Current replicas: %d", replicas)
            return replicas
        except client.exceptions.ApiException as e:
            logger.error("Failed to read Deployment replicas: %s. Defaulting to 1.", e)
            return 1

    def set_replicas(self, desired: int) -> bool:
        """
        Patch the Deployment to the desired replica count.

        Parameters
        ----------
        desired : Target replica count. Must already be clamped by caller.

        Returns
        -------
        bool : True if the patch succeeded, False otherwise.
        """
        try:
            current = self.get_current_replicas()
            if current == desired:
                logger.debug("Replicas already at %d. No patch needed.", desired)
                return True

            patch = {"spec": {"replicas": desired}}
            self.apps_v1.patch_namespaced_deployment(
                name=self.deployment_name,
                namespace=self.namespace,
                body=patch,
            )
            logger.info(
                "Scaled %s/%s: %d → %d replicas.",
                self.namespace, self.deployment_name, current, desired,
            )
            return True

        except client.exceptions.ApiException as e:
            logger.error("Failed to patch Deployment replicas: %s", e)
            return False

    def get_ready_replicas(self) -> int:
        """Return the number of ready (healthy) replicas."""
        try:
            deployment = self.apps_v1.read_namespaced_deployment(
                name=self.deployment_name,
                namespace=self.namespace,
            )
            return deployment.status.ready_replicas or 0
        except client.exceptions.ApiException as e:
            logger.error("Failed to read ready replicas: %s", e)
            return 0