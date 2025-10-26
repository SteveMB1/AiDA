import base64
import os
import ssl
from datetime import datetime
from datetime import timedelta
from typing import Any, Dict
from typing import Optional

import fastapi
import jwt
from fastapi import HTTPException, status
from fastapi import Request
from ldap3 import Server, Connection, ALL, SUBTREE, Tls
from ldap3.core.exceptions import LDAPException
from pydantic import BaseModel, Field

import database
import otp
from routes import router, read_current_user

# ———————— Load the secret once, at startup ————————
secret_path = os.path.join(os.path.dirname(__file__), 'config', 'jwt_secret.key')
with open(secret_path, 'r') as f:
    JWT_SECRET_KEY = f.read().strip()

# ─── Configuration ─────────────────────────────────

JWT_ALGORITHM = os.getenv("JWT_ALGORITHM", "HS256")
ACCESS_TOKEN_EXPIRE_MINUTES = int(os.getenv("ACCESS_TOKEN_EXPIRE_MINUTES", "7220"))

SERVICE_ACCOUNT_PW = os.getenv("SERVICE_ACCOUNT_PW", "")
# CA_CERT_PATH = os.getenv("CA_CERT_PATH", "/path/to/ca.crt")

LDAP_URL = os.getenv("LDAP_URL", "")
# Root of the Azure AD DS directory
LDAP_BASE_DN = os.getenv("LDAP_BASE_DN", "DC=aad")
# A service account in AADDC Users with permission to search
SERVICE_ACCOUNT_DN = os.getenv(
    "SERVICE_ACCOUNT_DN",
    "CN=LDAP Bind,OU=AADDC Users,DC=aad"
)
# Your DevOps group in Azure AD DS
AIDA_GROUP_DN = os.getenv(
    "AIDA_GROUP_DN",
    "CN=AiDA,OU=AADDC Users,DC=aad"
)


# ────────────────────────────────────────────────────

def verify_password(username: str, password: str) -> bool:
    """
    For Azure AD DS:
    1. Bind as the service account.
    2. Search by userPrincipalName (UPN) and memberOf=DevOps group.
    3. Re-bind as that user to verify credentials.
    """
    # 1) TLS + Server setup
    tls = Tls(validate=ssl.CERT_REQUIRED, version=ssl.PROTOCOL_TLSv1_2)
    server = Server(LDAP_URL, port=636, use_ssl=True, tls=tls, get_info=ALL)

    # 2) Service-account bind & search
    try:
        with Connection(
                server,
                user=SERVICE_ACCOUNT_DN,
                password=SERVICE_ACCOUNT_PW,
        ) as svc:
            # Azure AD DS uses userPrincipalName for UPN-based logins
            search_filter = (
                f"(&"
                f"(userPrincipalName={username})"
                f"(memberOf={AIDA_GROUP_DN})"
                f")"
            )
            svc.search(
                search_base=LDAP_BASE_DN,
                search_filter=search_filter,
                search_scope=SUBTREE,
                attributes=[]
            )
            if len(svc.entries) != 1:
                # not found or not in DevOps group
                return False

            user_dn = svc.entries[0].entry_dn

    except Exception:
        return False

    # 3) Re-bind as the user to verify password
    try:
        with Connection(
                server,
                user=user_dn,
                password=password,
        ):
            return True
    except Exception:
        return False


def get_user_full_name(username: str) -> Dict[str, str]:
    """
    Bind as the service account and search for the user's givenName and sn.
    Returns a dict with keys 'first' and 'last'.
    """
    tls = Tls(validate=ssl.CERT_REQUIRED, version=ssl.PROTOCOL_TLSv1_2)
    server = Server(LDAP_URL, port=636, use_ssl=True, tls=tls, get_info=ALL)

    try:
        with Connection(
                server,
                user=SERVICE_ACCOUNT_DN,
                password=SERVICE_ACCOUNT_PW,
        ) as svc:
            search_filter = (
                f"(&"
                f"(userPrincipalName={username})"
                f"(memberOf={AIDA_GROUP_DN})"
                f")"
            )
            svc.search(
                search_base=LDAP_BASE_DN,
                search_filter=search_filter,
                search_scope=SUBTREE,
                attributes=["givenName", "sn"]
            )
            if len(svc.entries) != 1:
                raise LDAPException("User not found or not in DevOps group")

            entry = svc.entries[0]
            first = entry.givenName.value or ""
            last = entry.sn.value or ""
            return {"first": first, "last": last}

    except Exception as e:
        # You can log e if you like
        return {"first": "", "last": ""}


# ─── Pydantic Models ─────────────────────────────────────────────────

class TokenResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"


# ─── JWT Utility Functions ────────────────────────────────────────────

def create_access_token(data: Dict[str, Any], expires_delta: timedelta) -> str:
    to_encode = data.copy()
    expire = datetime.utcnow() + expires_delta
    to_encode.update({"exp": expire})
    token = jwt.encode(to_encode, JWT_SECRET_KEY, algorithm=JWT_ALGORITHM)
    return token


def verify_jwt_token(token: str) -> Dict[str, Any]:
    """
    Decode & validate a JWT. Raises HTTPException if invalid/expired.
    Returns the token payload on success.
    """
    # Base exception for any invalid-token case
    credentials_exception = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="The access token provided is expired, revoked, malformed, or invalid for other reasons.",
        headers={
            "WWW-Authenticate": (
                'Bearer realm="api", '
                'error="invalid_token", '
                'error_description="The access token provided is expired, revoked, malformed, or invalid for other '
                'reasons."'
            )
        },
    )

    try:
        payload = jwt.decode(token, JWT_SECRET_KEY, algorithms=[JWT_ALGORITHM])
        return payload

    except jwt.ExpiredSignatureError:
        # Explicit expired case
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="The access token provided has expired.",
            headers={
                "WWW-Authenticate": (
                    'Bearer realm="api", '
                    'error="invalid_token", '
                    'error_description="The access token provided has expired."'
                )
            },
        )

    except jwt.DecodeError:
        # Invalid signature or token structure
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="The access token provided is malformed or has an invalid signature.",
            headers={
                "WWW-Authenticate": (
                    'Bearer realm="api", '
                    'error="invalid_token", '
                    'error_description="The access token provided is malformed or has an invalid signature."'
                )
            },
        )

    except jwt.PyJWTError:
        # Any other PyJWT error
        raise credentials_exception


class LoginRequest(BaseModel):
    username: str = Field(..., description="User's login name")
    password: str = Field(..., description="User's password")
    token: Optional[str] = Field(
        default=None,
        description="TOTP token from authenticator app (optional)"
    )


@router.get('/register-token/')
async def register_token_api(request: fastapi.Request):
    user = await read_current_user(request.headers.get("Authorization"))

    # Do Database count to prevent token overwrites if the user makes a manual request without token in the login request.
    currently_registered = await database.es_client.count(
        index="users_otp",
        body={
            "query": {
                "bool": {
                    "must": [
                        {"term": {"user": user['sub']}},
                        {"term": {"pending": False}},
                    ]
                }
            }
        }
    )

    if currently_registered['count'] == 0:
        secret = base64.b32encode(os.urandom(10)).decode()
        await database.es_client.index(index="users_otp", id=user['sub'],
                          body={"user": user['sub'], "pending": True, "secret": secret})

        uri = otp.provisioning_uri(secret, user=user['sub'], issuer="AI Diagnostics")
        return {"uri": uri}
    else:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Already Registered MFA Token"
        )


class TokenValidation(BaseModel):
    code: str


@router.post('/register-token/')
async def confirm_token_api(request: TokenValidation, fastapi_request: Request):
    user = await read_current_user(fastapi_request.headers.get("Authorization"))

    # Do Database count to prevent token overwrites if the user makes a manual request without token in the login request.
    currently_registered = await database.es_client.search(
        index="users_otp",
        body={
            "query": {
                "bool": {
                    "must": [
                        {"term": {"user": user['sub']}},
                        {"term": {"pending": True}},
                    ]
                }
            }
        }
    )

    if len(currently_registered['hits']['hits']) == 1:
        verify = otp.verify_totp(secret=currently_registered['hits']['hits'][0]['_source']['secret'],
                                 token=request.code)
        if verify is True:
            await database.es_client.update(
                index="users_otp",
                id=user["sub"],
                body={
                    "doc": {
                        "pending": False,
                    }
                }
            )

        return {"result": verify}
    else:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Already Registered MFA Token"
        )


@router.post("/login/", response_model=TokenResponse)
async def login(request: LoginRequest):
    index = "users_otp"
    # 1) Verify credentials
    if not verify_password(request.username, request.password):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid username or password",
            headers={"WWW-Authenticate": "Bearer"},
        )

    if request.token is not None:
        # 2) Verify OTP token
        try:
            resp = await database.es_client.search(
                index=index,
                body={
                    "query": {
                        "bool": {
                            "must": [
                                {"term": {"user": request.username}},
                                {"term": {"pending": False}},
                            ]
                        }
                    }}
            )
        except Exception as e:
            raise HTTPException(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                detail=f"Elasticsearch error: {e}"
            )

        hits = resp.get("hits", {}).get("hits", [])
        if not hits:
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="OTP device not registered for this user"
            )

        # Use the first registered device
        otp_secret = hits[0]["_source"]["secret"]
        verify_result = otp.verify_totp(token=request.token, secret=otp_secret)

        if not verify_result:
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="Invalid OTP token",
                headers={"WWW-Authenticate": "Bearer"},
            )

        if str(hits[0]["_source"].get("last_code")) == str(request.token):
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="OTP token already redeemed",
                headers={"WWW-Authenticate": "Bearer"},
            )
        await database.es_client.update(
            index="users_otp",
            id=request.username,
            body={
                "doc": {
                    "last_code": str(request.token),
                }
            }
        )

    name = get_user_full_name(request.username)

    token_data = {
        "sub": request.username,
        "is_mfa_login": request.token is not None,
        "name": {"first": name["first"], "last": name["last"]},
    }

    access_token = create_access_token(
        data=token_data,
        expires_delta=timedelta(minutes=ACCESS_TOKEN_EXPIRE_MINUTES)
    )

    return TokenResponse(access_token=access_token)


@router.get("/requires-mfa/")
async def read_current_user_api(fastapi_request: Request):
    user = await read_current_user(fastapi_request.headers.get("Authorization"))

    currently_registered = await database.es_client.count(
        index="users_otp",
        body={
            "query": {
                "bool": {
                    "must": [
                        {"term": {"user": user['sub']}},
                        {"term": {"pending": False}},
                    ]
                }
            }
        }
    )

    return {"result": bool(currently_registered['count'])}
