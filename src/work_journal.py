import logging

from fastapi import Request, HTTPException, status
from pydantic import BaseModel

import database
from routes import router, read_current_user


class JournalPost(BaseModel):
    text: str


@router.post("/create/journal")
async def scale_using_recommendation(request: Request, journal_post_request: JournalPost):
    try:
        es = database.get_es_client()

        user = await read_current_user(request.headers.get("Authorization"))
        if not user.get("is_mfa_login"):
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="MFA required")



    except Exception as e:
        logging.exception(f"Unexpected error in /scale/confirm/: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Internal server error while preparing scaling operation."
        )
