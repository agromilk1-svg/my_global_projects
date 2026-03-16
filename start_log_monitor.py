import subprocess
import time
import sys
import threading

def read_stream(process, log_file):
    for line in iter(process.stdout.readline, ''):
        print(line, end='')
        log_file.write(line)

print("Starting iOS Log Monitor...")
print("Please run this script, then TAP the app on your phone immediately.")
print("Logs are being saved to 'ios_launch_log.txt'...")

cmd = [
    "python3", "-m", "pymobiledevice3", "syslog", "live",
    "--regex", "deviceinfo|amfid|kill|deny|SpringBoard|kernel"
]

log_file = open("ios_launch_log.txt", "w")

try:
    process = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1
    )
    
    # Read output in a separate thread to keep it flowing
    t = threading.Thread(target=read_stream, args=(process, log_file))
    t.daemon = True
    t.start()

    print("Listening for logs... (Press Ctrl+C to stop)")
    while True:
        time.sleep(1)

except KeyboardInterrupt:
    print("\nStopping...")
    process.terminate()
    log_file.close()
    print("Log saved to ios_launch_log.txt")
except Exception as e:
    print(f"Error: {e}")
    if 'log_file' in locals():
        log_file.close()
