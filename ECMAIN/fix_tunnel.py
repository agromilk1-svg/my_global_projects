from pbxproj import XcodeProject
try:
    project = XcodeProject.load('/Users/hh/Desktop/my/ECMAIN/ECMAIN.xcodeproj/project.pbxproj')
    target = project.get_target_by_name('Tunnel')
    if target:
        files = project.get_build_files_for_target(target.name)
        for f in files:
            file_ref = project.objects.get(f.fileRef)
            if file_ref and hasattr(file_ref, 'name') and file_ref.name and file_ref.name in ['ECTaskPollManager.m', 'ECTaskListViewController.m']:
                project.remove_build_file(f.get_id())
                print('Removed', file_ref.name)
            elif file_ref and hasattr(file_ref, 'path') and file_ref.path and ('ECTaskPollManager.m' in file_ref.path or 'ECTaskListViewController.m' in file_ref.path):
                project.remove_build_file(f.get_id())
                print('Removed path', file_ref.path)
        project.save()
        print('Fixed pbxproj.')
except Exception as e:
    print('Failed:', e)
