#!/usr/bin/env python3

from ansible.module_utils.basic import AnsibleModule
import socket

try:
    from kubernetes import client, config
    from kubernetes.client.rest import ApiException
    HAS_K8S = True
except ImportError:
    HAS_K8S = False


def check_pods_for_status(module, v1_api, node, status_keyword):
    try:
        resp = v1_api.list_pod_for_all_namespaces(field_selector=f"spec.nodeName={node}")
    except ApiException as e:
        module.fail_json(msg="Failed to list pods via Kubernetes API", error=str(e), status=e.status, reason=e.reason)

    keyword = status_keyword.lower()
    for pod in resp.items:
        if pod.status.phase and pod.status.phase.lower() == keyword:
            return True
        if pod.status.container_statuses:
            for cs in pod.status.container_statuses:
                if cs.state.waiting and cs.state.waiting.reason:
                    if cs.state.waiting.reason.lower() == keyword:
                        return True
                if cs.state.terminated and cs.state.terminated.reason:
                    if cs.state.terminated.reason.lower() == keyword:
                        return True
    return False


def main():
    module = AnsibleModule(
        argument_spec=dict(
            hostname=dict(type='str', required=False, default=None),
        ),
        supports_check_mode=True,
    )

    if not HAS_K8S:
        module.fail_json(msg="The kubernetes Python client is required (pip install kubernetes)")

    host = module.params['hostname'] or socket.gethostname()

    try:
        config.load_kube_config(config_file='/etc/kubernetes/kubelet.conf')
    except Exception as e:
        module.fail_json(msg="Failed to load kubeconfig", error=str(e))

    v1 = client.CoreV1Api()

    kubernetes = dict(
        has_crashloopbackoff=check_pods_for_status(module, v1, host, 'CrashLoopBackOff'),
        has_oomkilled=check_pods_for_status(module, v1, host, 'OOMKilled'),
        has_imagepullbackoff=check_pods_for_status(module, v1, host, 'ImagePullBackOff'),
        has_pending=check_pods_for_status(module, v1, host, 'Pending'),
        has_errimagepull=check_pods_for_status(module, v1, host, 'ErrImagePull'),
        has_containercreating=check_pods_for_status(module, v1, host, 'ContainerCreating'),
    )

    module.exit_json(changed=False, failed=False, kubernetes=kubernetes)


if __name__ == '__main__':
    main()