from fastapi import APIRouter, HTTPException, Depends, status
from fastapi.security import OAuth2PasswordRequestForm
from app.models import User
from app.core import auth
from pydantic import BaseModel

router = APIRouter()

class UserCreate(BaseModel):
    username: str
    password: str

@router.post("/register")
async def register(user: UserCreate):
    if await User.filter(username=user.username).exists():
        raise HTTPException(status_code=400, detail="Username already registered")
    
    hashed_password = auth.get_password_hash(user.password)
    user_obj = await User.create(username=user.username, password_hash=hashed_password)
    return {"id": user_obj.id, "username": user_obj.username}

@router.post("/token")
async def login_for_access_token(form_data: OAuth2PasswordRequestForm = Depends()):
    user = await User.get_or_none(username=form_data.username)
    if not user or not auth.verify_password(form_data.password, user.password_hash):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Incorrect username or password",
            headers={"WWW-Authenticate": "Bearer"},
        )
    access_token = auth.create_access_token(data={"sub": user.username})
    return {"access_token": access_token, "token_type": "bearer"}
