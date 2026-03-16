import sys
print(f"Python: {sys.executable}")
try:
    import uvicorn
    print(f"uvicorn: {uvicorn.__version__} at {uvicorn.__file__}")
except ImportError:
    print("uvicorn: MISSING")

try:
    import websockets
    print(f"websockets: {websockets.__version__} at {websockets.__file__}")
except ImportError:
    print("websockets: MISSING")

try:
    import wsproto
    print(f"wsproto: {wsproto.__version__}")
except ImportError:
    print("wsproto: MISSING")
