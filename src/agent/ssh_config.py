import ipaddress
import os
from pathlib import Path


def ssh_config():
    # Expand paths
    ssh_dir = os.path.expanduser("~/.ssh")
    config_path = os.path.join(ssh_dir, "config")  # adjust to "conf" if that's really your filename

    include_line = ("Host *.*.*.*\n  IdentityFile ~/.ssh/ai-diagnostics-user.pem\n  StrictHostKeyChecking no\n"
                    "Include ~/.ssh/config.d/*.conf")

    # 1. Make sure ~/.ssh exists
    os.makedirs(ssh_dir, exist_ok=True)

    # 2. Read existing config (if any)
    if os.path.exists(config_path):
        with open(config_path, "r") as f:
            lines = [l.rstrip("\n") for l in f]
    else:
        lines = []

    # 3. Append the Include‐line if it's not already there
    if include_line not in lines:
        with open(config_path, "a") as f:
            # ensure there's a blank line before to keep things tidy
            f.write("\n" + include_line + "\n")
        print(f"🔧 Appended `{include_line}` to {config_path}")
    else:
        print(f"✅ `{include_line}` is already present in {config_path}")


def generate_jump_host_ssh_config(
        cidr: str = None,
        user: str = 'root',
        port: int = 22,
        jump_host: str = None,
        output_path: str = None
) -> str:
    # Determine Host pattern and HostName

    # Allow host bits: normalize network address
    net = ipaddress.ip_network(cidr, strict=False)
    if net.prefixlen != 22:
        raise ValueError('CIDR must be a /22 network')
    first, second = net.network_address.exploded.split('.')[:2]

    host_pattern = f"{first}.{second}.*.*"

    lines = [
        f"Host {host_pattern}",
        f"    User {user}",
        f"    Port {port}"]

    proxy = f"{user}@{jump_host}"

    lines.append(f"    ProxyJump {proxy}")

    config_str = "\n".join(lines) + "\n"

    # Write to file if requested
    if output_path:
        path = Path(output_path).expanduser()
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(config_str)

    ssh_config()

    return config_str
