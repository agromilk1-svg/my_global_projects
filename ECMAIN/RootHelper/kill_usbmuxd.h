#import <Foundation/Foundation.h>
#import <sys/sysctl.h>
#import <signal.h>

static void kill_native_usbmuxd(void) {
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t size;
    if (sysctl(mib, 4, NULL, &size, NULL, 0) < 0) return;
    
    struct kinfo_proc *kp = (struct kinfo_proc *)malloc(size);
    if (sysctl(mib, 4, kp, &size, NULL, 0) < 0) {
        free(kp);
        return;
    }
    
    int proc_count = (int)(size / sizeof(struct kinfo_proc));
    for (int i = 0; i < proc_count; i++) {
        NSString *pName = [NSString stringWithUTF8String:kp[i].kp_proc.p_comm];
        if ([pName isEqualToString:@"usbmuxd"]) {
            pid_t pid = kp[i].kp_proc.p_pid;
            NSLog(@"[usbmuxd-shim] Found native usbmuxd (PID: %d). Sending SIGKILL...", pid);
            kill(pid, SIGKILL);
            break;
        }
    }
    free(kp);
}
