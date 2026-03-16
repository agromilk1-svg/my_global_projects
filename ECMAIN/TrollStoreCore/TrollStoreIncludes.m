// Unity build file for TrollStoreCore to avoid modifying project file
// This is a temporary solution for the integration phase

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// Fix for missing includes in TSAppInfo.m if libarchive headers are missing
// We might need to manually define some things/imports if it fails compilation
// But for now, we assume implicit declaration might work or headers are found

// Unity build imports disabled as files are added to project separately
// #import "../ECMAIN/UI/ECAppListViewController.m"
// #import "TSAppInfo.m"
// #import "TSApplicationsManager.m"
// #import "TSInstallationController.m"
// #import "TSPresentationDelegate.m"
// #import "TSUtil.m"
// #include "libroot_dyn.c"
