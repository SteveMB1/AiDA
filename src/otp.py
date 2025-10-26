import base64
import hashlib
import hmac
import struct
import time
import urllib.parse

__all__ = ["generate_hotp", "generate_totp", "verify_totp", "provisioning_uri"]


def _int_to_bytes(i: int) -> bytes:
    return struct.pack(">Q", i)


def generate_hotp(secret: str, counter: int, digits: int = 6, digest=hashlib.sha1) -> str:
    """
    Generate an HOTP code given a base32 secret and counter.
    """
    key = base64.b32decode(secret, casefold=True)
    msg = _int_to_bytes(counter)
    hmac_digest = hmac.new(key, msg, digest).digest()
    # dynamic truncation
    offset = hmac_digest[-1] & 0x0F
    code = struct.unpack(">I", hmac_digest[offset:offset + 4])[0] & 0x7FFFFFFF
    return str(code % (10 ** digits)).zfill(digits)


def generate_totp(secret: str, interval: int = 30, digits: int = 6,
                  digest=hashlib.sha1, for_time: int = None) -> str:
    """
    Generate a TOTP code (time-based) for now() or a given UNIX timestamp.
    """
    if for_time is None:
        for_time = int(time.time())
    counter = for_time // interval
    return generate_hotp(secret, counter, digits, digest)


def verify_totp(token: str, secret: str, interval: int = 30, window: int = 1,
                digits: int = 6, digest=hashlib.sha1) -> bool:
    """
    Verify a TOTP code, allowing ±window intervals for clock skew.
    """
    now = int(time.time())
    for w in range(-window, window + 1):
        if generate_totp(secret, interval, digits, digest, now + w * interval) == token:
            return True
    return False


def provisioning_uri(secret: str, user: str, issuer: str, algorithm: str = "SHA1",
                     digits: int = 6, interval: int = 30) -> str:
    """
    Return an otpauth:// URI that Google Authenticator & similar apps understand.
    """
    label = urllib.parse.quote(f"{issuer}:{user}")
    params = {
        "secret": secret,
        "issuer": issuer,
        "algorithm": algorithm,
        "digits": str(digits),
        "period": str(interval)
    }
    query = urllib.parse.urlencode(params)
    return f"otpauth://totp/{label}?{query}"
