import secrets
import os
import stat

# 64 bytes = 512 bits; hex-encoded → 128 chars
secret = secrets.token_hex(64)

# write somewhere safe & git-ignored
out_dir = os.path.join(os.path.dirname(__file__), 'config')
os.makedirs(out_dir, exist_ok=True)
secret_path = os.path.join(out_dir, 'jwt_secret.key')

with open(secret_path, 'w') as f:
    f.write(secret)

# restrict permissions to owner read/write
os.chmod(secret_path, stat.S_IRUSR | stat.S_IWUSR)

print(f"🔑 JWT secret written to {secret_path}")