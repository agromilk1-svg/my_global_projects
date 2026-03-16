#import <Foundation/Foundation.h>

#define NIL_LAUNCHD_RESPONSE                                                   \
  (LaunchdResponse_t) { nil, 0, -1, NO }

typedef struct LaunchdResponse {
  NSUUID *job_handle;
  NSUInteger job_state;
  pid_t pid;
  BOOL removing;
} LaunchdResponse_t;

LaunchdResponse_t responseFromXPCObject(xpc_object_t responseObj);
NSString *NSStringFromLaunchdResponse(LaunchdResponse_t response);

typedef NS_ENUM(int, OSLaunchdJobSelector) {
  OSLaunchdJobSelectorSubmitAndStart = 1000,
  OSLaunchdJobSelectorMonitor = 1001,
  OSLaunchdJobSelectorRemove = 1003,
  OSLaunchdJobSelectorCopyJobsManagedBy = 1004,
  OSLaunchdJobSelectorCopyJobWithLabel = 1005,
  OSLaunchdJobSelectorStart = 1006,
  OSLaunchdJobSelectorSubmitExtension = 1007,
  OSLaunchdJobSelectorCopyJobWithPID = 1008,
  OSLaunchdJobSelectorPropertiesForRB = 1009,
  OSLaunchdJobSelectorCreateInstance = 1010,
  OSLaunchdJobSelectorSubmit = 1011,
  OSLaunchdJobSelectorCopyJobWithHandle = 1013,
  OSLaunchdJobSelectorSubmitAll = 1014,
  OSLaunchdJobSelectorGetCurrentJobInfo = 1015
};

// Private API declarations
kern_return_t _launch_job_routine(OSLaunchdJobSelector selector,
                                  xpc_object_t request, id *response);
xpc_object_t _CFXPCCreateXPCObjectFromCFObject(id cfObject);
