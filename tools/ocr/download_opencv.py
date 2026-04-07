import requests
import os
import sys

URL = "https://github.com/opencv/opencv/releases/download/4.10.0/opencv-4.10.0-ios-framework.zip"
DEST = "/Users/hh/Desktop/my/WebDriverAgentLib/Vendor/opencv2.framework.zip"

def download_file():
    if os.path.exists(DEST):
        os.remove(DEST)
        
    print(f"Downloading {URL}...")
    try:
        with requests.get(URL, stream=True) as r:
            r.raise_for_status()
            total_length = int(r.headers.get('content-length'))
            print(f"Total size: {total_length / 1024 / 1024:.2f} MB")
            
            dl = 0
            with open(DEST, 'wb') as f:
                for chunk in r.iter_content(chunk_size=8192): 
                    if chunk: 
                        dl += len(chunk)
                        f.write(chunk)
                        done = int(50 * dl / total_length)
                        sys.stdout.write(f"\r[{'=' * done}{' ' * (50-done)}] {dl/total_length*100:.2f}%")
                        sys.stdout.flush()
        print("\nDownload complete.")
        return True
    except Exception as e:
        print(f"\nError: {e}")
        return False

if __name__ == "__main__":
    if download_file():
        print("Unzipping...")
        os.system(f"unzip -q {DEST} -d /Users/hh/Desktop/my/WebDriverAgentLib/Vendor/")
        print("Done.")
        os.remove(DEST)
    else:
        sys.exit(1)
