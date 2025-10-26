from fastapi import HTTPException, APIRouter

router = APIRouter()

async def read_current_user(authorization: str):
    """
    Expects: Header 'Authorization: Bearer <token>'
    """
    try:
        from authentication import verify_jwt_token
        scheme, _, token = authorization.partition(" ")
        if scheme.lower() != "bearer" or not token:
            raise HTTPException(status_code=401, detail="Invalid auth header")
        payload = verify_jwt_token(token)
        return payload
    except Exception as e:
        raise HTTPException(status_code=401, detail=str(e))

