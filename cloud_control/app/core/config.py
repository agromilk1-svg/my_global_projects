import os

class Settings:
    PROJECT_NAME: str = "EC Cloud Control"
    VERSION: str = "1.0.0"
    
    # Database
    DB_URL: str = "sqlite://db.sqlite3"
    
    # Security
    SECRET_KEY: str = "YOUR_SUPER_SECRET_KEY_CHANGE_IN_PROD"
    ALGORITHM: str = "HS256"
    ACCESS_TOKEN_EXPIRE_MINUTES: int = 60 * 24 # 1 day

settings = Settings()
