#!/usr/bin/env python3
import argparse
import fileinput
import re
import subprocess
import sys
import os
import textwrap
import json
import traceback

# ===================================================================================
# Begin editable globals.
# This section contains global variables with values that might change in the future.
# ===================================================================================

# iTwin base versions to search for. 3.2.x - 4.4.x for now.
itwin_base_version_search_list = [
    "3\\.2\\.",
    "3\\.3\\.",
    "3\\.4\\.",
    "3\\.5\\.",
    "3\\.6\\.",
    "3\\.7\\.",
    "4\\.0\\.",
    "4\\.1\\.",
    "4\\.2\\.",
    "4\\.3\\.",
    "4\\.4\\.",
]
# iTwin Mobile SDK base version. 0.21.x for now.
mobile_base_version = "0.22."
# iTwin Mobile SDK base version to search for. 0.21.x for now.
mobile_base_version_search_list = [
    "0\\.21\\.",
    "0\\.22\\.",
]
# The search string for Bentley's JS package (iTwin.js or imodeljs).
js_package_search = "__iTwin\\.js "
# The search string for itwin-mobile-native
native_package_search = "`itwin-mobile-native` CocoaPod to version "
# Subdirectory under mobile-samples of react-app.
react_app_subdir = 'cross-platform/react-app'
# Subdirectory under mobile-samples of token-server.
token_server_subdir = 'cross-platform/token-server'
# The version prefix when determining the latest iTwin version.
itwin_version_prefix = '4.4'
# The scope for iTwin npm packages.
itwin_scope = '@itwin'
# The npm packages with an @itwin/ prefix that aren't part of itwinjs-core.
itwin_non_core_packages = [
    "eslint-plugin",
    "measure-tools-react",
    "mobile-sdk-core",
    "mobile-ui-react",
]
appui_packages = [
    "appui-react",
    "components-react",
    "core-react",
    "imodel-components-react",
]
appui_layout_packages = [
    "appui-layout-react",
]
imodels_access_packages = [
    "imodels-access-backend",
    "imodels-access-frontend",
]
itwins_client_packages = [
    "itwins-client",
]
imodels_client_packages = [
    "imodels-client-management",
]
presentation_packages = [
    "presentation-components",
]
itwin_non_core_packages.extend(appui_packages)
itwin_non_core_packages.extend(appui_layout_packages)
itwin_non_core_packages.extend(imodels_access_packages)
itwin_non_core_packages.extend(itwins_client_packages)
itwin_non_core_packages.extend(imodels_client_packages)
itwin_non_core_packages.extend(presentation_packages)
# The package used to determine the current version of iTwin
itwin_version_package = '@itwin/core-common'
# The package whose dependencies determine the current add-on version.
native_version_package = '@itwin/core-backend'
# The branch this script is running in
git_branch = 'main'
# The names of the iOS sample apps
ios_sample_names = [
    'CameraSample',
    'MobileStarter',
    'SwiftUIStarter',
    'ThirdPartyAuth',
]
# The names of the Android sample apps
android_sample_names = [
    'CameraSample',
    'iTwinStarter',
    'ThirdPartyAuth',
]
# The names of the React Native sample apps
react_native_sample_names = [
    'iTwinRNStarter',
]

# ===================================================================================
# End editable globals.
# ===================================================================================

class MobileSdkDirs:
    def __init__(self, args):
        if args.parent_dir:
            parent_dir = os.path.realpath(args.parent_dir)
        else:
            parent_dir = os.path.realpath(os.path.join(os.path.dirname(os.path.realpath(__file__)), '..'))
        # The relative paths to the iTwin Mobile SDK repository directories.
        # Since these are directly tied to member properties on this class, they cannot
        # be in the editable globals section above.
        relative_dirs = [
            'mobile-sdk-ios',
            'mobile-sdk-android',
            'mobile-sdk-core',
            'mobile-ui-react',
            'mobile-samples',
        ]
        def build_dir(dir_name):
            return os.path.realpath(os.path.join(parent_dir, dir_name))
        self.dirs = []
        for relative_dir in relative_dirs:
            self.dirs.append(build_dir(relative_dir))
        self.sdk_ios = self.dirs[0]
        self.sdk_android = self.dirs[1]
        self.sdk_core = self.dirs[2]
        self.ui_react = self.dirs[3]
        self.samples = self.dirs[4]

    def __iter__(self):
        return iter(self.dirs)

def is_itwin_non_core_project_line(line, is_itwin):
    if not is_itwin: return False
    for itwin_non_core_package in itwin_non_core_packages:
        if line.find(f'@itwin/{itwin_non_core_package}') != -1:
            return True
    return False

def parse_replacement_tuple(tuple):
    if len(tuple) == 2:
        return (tuple[0], tuple[1], False)
    else:
        return (tuple[0], tuple[1], tuple[2])

def replace_all(filename, replacements):
    num_found = 0
    for line in fileinput.input(filename, inplace=1):
        newline = line
        for tuple in replacements:
            (search_exp, replace_exp, is_itwin) = parse_replacement_tuple(tuple)
            if re.search(search_exp, newline) and not is_itwin_non_core_project_line(newline, is_itwin):
                num_found += 1
                newline = re.sub(search_exp, replace_exp, newline)
        sys.stdout.write(newline)
    return num_found

def itwin_base_version_search_tuples(first_format_string, second_value, is_itwin = False):
    result = []
    for itwin_base_version_search in itwin_base_version_search_list:
        result.append((first_format_string.format(itwin_base_version_search), second_value, is_itwin))
    return result

def mobile_base_version_search_tuples(first_format_string, second_value):
    result = []
    for mobile_base_version_search in mobile_base_version_search_list:
        result.append((first_format_string.format(mobile_base_version_search), second_value))
    return result

def get_packages_tuples(packages, prefix, group_name):
    version = get_latest_version(f'@itwin/{packages[0]}', prefix)
    print(f'{group_name} version: {version}')
    result = []
    for package in packages:
        result.append((f'("@itwin/{package}"): "[0-9][.0-9a-z-]+', '\\1: "' + version))
    return result

def get_itwin_non_core_tuples():
    result = []
    result.extend(get_packages_tuples(appui_packages, '4', 'appui'))
    result.extend(get_packages_tuples(appui_layout_packages, '4', 'appui_layout'))
    result.extend(get_packages_tuples(imodels_access_packages, '4', 'imodels_access'))
    result.extend(get_packages_tuples(itwins_client_packages, '1', 'itwins_client'))
    result.extend(get_packages_tuples(imodels_client_packages, '4', 'imodels_client'))
    result.extend(get_packages_tuples(presentation_packages, '4', 'presentation'))
    return result

def modify_package_json(args, dir):
    filename = os.path.join(dir, 'package.json')
    if os.path.exists(filename):
        print("Processing: " + filename)
        tuples = get_itwin_non_core_tuples()
        # IMPORTANT: The @itwin/mobile-sdk-core and @itwin/mobile-ui-react replacements must
        # come last.
        tuples.extend(
            [
                ('("version": )"[.0-9a-z-]+', '\\1"' + args.new_mobile),
            ] + itwin_base_version_search_tuples(
                '("' + itwin_scope + '/[0-9a-z-]+"): "{0}[.0-9a-z-]+',
                '\\1: "' + args.new_itwin,
                True
            ) + [
                ('("@itwin/mobile-sdk-core"): "[0-9][.0-9a-z-]+', '\\1: "' + args.current_mobile),
                ('("@itwin/mobile-ui-react"): "[0-9][.0-9a-z-]+', '\\1: "' + args.current_mobile),
            ]
        )
        if replace_all(filename, tuples) < 2:
            raise Exception("Not enough replacements")

def modify_readme_md(args, dir):
    filename = os.path.join(dir, 'README.md')
    if not os.path.exists(filename):
        raise Exception("Error: Cannot find " + filename)
    print("Processing: " + filename)
    if replace_all(
        filename,
        itwin_base_version_search_tuples(
            '(' + js_package_search + '){0}[.0-9a-z-]+',
            '\\g<1>' + args.new_itwin
        )
    ) < 1:
        raise Exception("Not enough replacements")

    # Replacements specific to the mobile-sdk-ios/README.md
    if dir == sdk_dirs.sdk_ios and replace_all(
        filename,
        mobile_base_version_search_tuples(
            '("Dependency Rule" to "Exact Version" and the version to "){0}[.0-9a-z-]+',
            '\\g<1>' + args.new_mobile
        ) + mobile_base_version_search_tuples(
            '("https:\\/\\/github.com\\/iTwin\\/mobile-sdk-ios", .exact\\("){0}[.0-9a-z-]+',
            '\\g<1>' + args.new_mobile
        ) + itwin_base_version_search_tuples(
            '(https:\\/\\/github.com\\/iTwin\\/mobile-native-ios\\/releases\\/download\\/){0}[.0-9a-z-]+',
            '\\g<1>' + args.new_add_on
        ) + mobile_base_version_search_tuples(
            '(https:\\/\\/github.com\\/iTwin\\/mobile-sdk-ios\\/releases\\/download\\/){0}[.0-9a-z-]+',
            '\\g<1>' + args.new_mobile
        ) + itwin_base_version_search_tuples(
            '(' + native_package_search + '){0}[.0-9a-z-]+',
            '\\g<1>' + args.new_add_on
        )
    ) < 5:
        raise Exception("Not enough replacements")

def modify_package_swift(args, filename):
    print("Processing: " + os.path.realpath(filename))
    if replace_all(filename, [('(mobile-native-ios", .exact\\()"[.0-9a-z-]+', '\\1"' + args.new_add_on)]) != 1:
        raise Exception("Not enough replacements")

def modify_podspec(args, filename):
    print("Processing: " + os.path.realpath(filename))
    replacements = [('(spec\\.version\\s+=\\s+")[.0-9a-z-]+"', '\\g<1>' + args.new_mobile + '"')]
    replacements.append(('(spec\\.dependency\\s+"itwin-mobile-native",\\s+")[.0-9a-z-]+"', '\\g<1>' + args.new_add_on + '"'))
    if replace_all(filename, replacements) != 2:
        raise Exception("Not enough replacements")

def modify_project_pbxproj(args, filename):
    print("Processing: " + os.path.realpath(filename))
    repository = None
    new_mobile = args.new_mobile
    if re.search('[a-z-]', new_mobile):
        new_mobile = '"' + new_mobile + '"'
    for line in fileinput.input(filename, inplace=1):
        if re.search('repositoryURL = "https://github.com/iTwin/mobile-sdk-ios.git";', line):
            repository = 'mobile-sdk-ios'
        if repository == 'mobile-sdk-ios':
            if re.search('version\\s+=\\s+[.0-9a-z"-]+;', line):
                line = re.sub('(version\\s+=\\s+)[.0-9a-z"-]+;', '\\g<1>' + new_mobile + ';', line)
                repository = None
        sys.stdout.write(line)

# Note: the "itwin-mobile-sdk" Swift Package is now showing up as "mobile-sdk-ios" inside the
# Package.resolved files. I don't know if this is due to an Xcode update or some other change
# that I'm unaware of. Because of that uncertainty, this code recognizes both package names as
# being valid. The same thing is done for the 'itwin-mobile-native" package. In that case,
# both names are definitely used (one here in mobile-sdk-ios, and another in mobile-samples).
def modify_package_resolved(args, filename):
    print("Processing: " + os.path.realpath(filename))
    package = None
    for line in fileinput.input(filename, inplace=1):
        match = re.search('"package"\\s*: "(.*)"', line)
        if match and len(match.groups()) == 1:
            package = match.group(1)
        else:
            match = re.search('"identity"\\s*:\\s*"(.*)"', line)
            if match and len(match.groups()) == 1:
                package = match.group(1)
        if package == 'itwin-mobile-native' or package == 'mobile-native-ios':
            line = re.sub('("version"\\s*:\\s*)"[0-9].*"', '\\1"' + args.new_add_on + '"', line)
            if hasattr(args, 'new_add_on_commit_id') and args.new_add_on_commit_id:
                line = re.sub('("revision"\\s*:\\s*)"[0-9A-Fa-f]*"', '\\1"' + args.new_add_on_commit_id + '"', line)
        elif (package == 'itwin-mobile-sdk' or package == 'mobile-sdk-ios') and not skip_commit_id(args):
            line = re.sub('("version"\\s*:\\s*)"[0-9].*"', '\\1"' + args.new_mobile + '"', line)
            if hasattr(args, 'new_commit_id') and args.new_commit_id:
                line = re.sub('("revision"\\s*:\\s*)"[0-9A-Fa-f]*"', '\\1"' + args.new_commit_id + '"', line)
        sys.stdout.write(line)

def modify_build_gradle(args, filename):
    print("Processing: " + os.path.realpath(filename))
    if replace_all(
        filename,
        [
            ("(versionName ')[.0-9a-z-]+", "\\g<1>" + args.new_mobile),
            ("(version = ')((?!-debug'$)[.0-9a-z-])+", "\\g<1>" + args.new_mobile),
            ("(api 'com.github.itwin:mobile-native-android:)[.0-9a-z-]+", "\\g<1>" + args.new_add_on),
        ]
    ) != 4:
        raise Exception("Wrong number of replacements")

def modify_sample_build_gradle(args, filename):
    print("Processing: " + os.path.realpath(filename))
    if replace_all(
        filename,
        [
            ("(implementation 'com.github.itwin:mobile-sdk-android:)[.0-9a-z-]+", "\\g<1>" + args.new_mobile),
            # ("(debugImplementation 'com.github.itwin:mobile-sdk-android:)[.0-9a-z-]+-debug", "\\g<1>" + args.new_mobile + "-debug"),
        ]
    ) != 1:
        raise Exception("Wrong number of replacements")

def change_command(args):
    if not args.force:
        ensure_no_dirs_have_diffs()
    if not hasattr(args, 'current_mobile') or not args.current_mobile:
        args.current_mobile = get_last_release()
    modify_package_swift(args, os.path.join(sdk_dirs.sdk_ios, 'Package.swift'))
    modify_package_resolved(args, os.path.join(sdk_dirs.sdk_ios, 'Package.resolved'))
    modify_podspec(args, os.path.join(sdk_dirs.sdk_ios, 'itwin-mobile-sdk.podspec'))
    modify_readme_md(args, sdk_dirs.sdk_ios)
    modify_readme_md(args, sdk_dirs.sdk_android)
    modify_build_gradle(args, os.path.join(sdk_dirs.sdk_android, 'mobile-sdk', 'build.gradle'))
    # modify_android_yml(args, os.path.join(sdk_dirs.sdk_android, '.github', 'workflows', 'android.yml'))
    modify_package_json(args, sdk_dirs.sdk_core)

def bump_command(args):
    if not args.force:
        ensure_no_dirs_have_diffs()
    get_versions(args)
    change_command(args)
    npm_install_dir(sdk_dirs.sdk_core)

def changeitwin_command(args):
    args.skip_commit_id = True
    change_command(args)
    npm_install_dir(sdk_dirs.sdk_core)
    changeui_command(args)
    npm_install_dir(sdk_dirs.ui_react)
    changesamples_command(args)
    npm_install_dir(os.path.join(sdk_dirs.samples, react_app_subdir))
    npm_install_dir(os.path.join(sdk_dirs.samples, token_server_subdir))

def bumpitwin_command(args):
    if not args.force:
        ensure_no_dirs_have_diffs()
    get_versions(args, True)
    changeitwin_command(args)

def changeui_command(args):
    args.current_mobile = args.new_mobile
    modify_package_json(args, sdk_dirs.ui_react)

def npm_build_dir(dir, relativeDeps = False):
    print('Performing npm run build in dir: ' + dir)
    if relativeDeps:
        rm_args = ['rm', '-rf', 'node_modules/@itwin/mobile-sdk-core', 'node_modules/@itwin/mobile-ui-react']
        subprocess.check_call(rm_args, cwd=dir)
        npx_args = ['npx', 'relative-deps']
        subprocess.check_call(npx_args, cwd=dir)
    build_args = ['npm', 'run', 'build']
    subprocess.check_call(build_args, cwd=dir)

def npm_install_dir(dir):
    print('Performing npm install in dir: ' + dir)
    subprocess.check_call(['npm', 'install', '--force'], cwd=dir)

def bumpui_command(args):
    get_versions(args)
    changeui_command(args)
    npm_install_dir(sdk_dirs.ui_react)

def changesamples_command(args):
    args.current_mobile = args.new_mobile
    modify_package_json(args, os.path.join(sdk_dirs.samples, react_app_subdir))
    modify_package_json(args, os.path.join(sdk_dirs.samples, token_server_subdir))
    modify_samples_project_pbxproj(args)
    modify_samples_build_gradle(args)
    modify_sample_build_gradle(args, os.path.join(sdk_dirs.samples, 'Android/Shared/build.gradle'))
    modify_samples_package_resolved(args)

def bumpsamples_command(args):
    get_versions(args)
    changesamples_command(args)
    npm_install_dir(os.path.join(sdk_dirs.samples, react_app_subdir))
    npm_install_dir(os.path.join(sdk_dirs.samples, token_server_subdir))

def dir_has_diff(dir):
    return subprocess.call(['git', 'diff', '--quiet'], cwd=dir) != 0

def ensure_all_dirs_have_diffs():
    should_throw = False
    for dir in sdk_dirs:
        if not dir_has_diff(dir):
            print("No diffs in dir: " + dir)
            should_throw = True
    if should_throw:
        raise Exception("Error: Diffs are required")

def ensure_no_dirs_have_diffs():
    should_throw = False
    for dir in sdk_dirs:
        if dir_has_diff(dir):
            print("Diffs in dir: " + dir)
            should_throw = True
    if should_throw:
        raise Exception("Error: Diffs are not allowed")

def commit_dir(args, dir):
    print("Committing in dir: " + dir)
    if dir_has_diff(dir):
        subprocess.check_call(['git', 'checkout', git_branch], cwd=dir)
        subprocess.check_call(['git', 'add', '.'], cwd=dir)
        subprocess.check_call(['git', 'commit', '-m', 'Update version to ' + args.new_mobile], cwd=dir)
    else:
        print("Nothing to commit.")

def get_xcodeproj_dirs():
    xcodeproj_dirs = []
    for sample_name in ios_sample_names:
        xcodeproj_dirs.append(os.path.join(sdk_dirs.samples, 'iOS', sample_name, sample_name + '.xcodeproj'))
        xcodeproj_dirs.append(os.path.join(sdk_dirs.samples, 'iOS', sample_name, 'LocalSDK_' + sample_name + '.xcodeproj'))
    for sample_name in react_native_sample_names:
        xcodeproj_dirs.append(os.path.join(sdk_dirs.samples, 'ReactNative', sample_name, 'ios', sample_name + '.xcodeproj'))
    return xcodeproj_dirs

def modify_samples_project_pbxproj(args):
    for dir in get_xcodeproj_dirs():
        modify_project_pbxproj(args, os.path.join(dir, 'project.pbxproj'))

def skip_commit_id(args):
    return hasattr(args, 'skip_commit_id') and args.skip_commit_id

def modify_samples_package_resolved(args):
    if not hasattr(args, 'new_commit_id') and not skip_commit_id(args):
        args.new_commit_id = get_last_commit_id(sdk_dirs.sdk_ios, args.new_mobile)
    for dir in get_xcodeproj_dirs():
        modify_package_resolved(args, os.path.join(dir, 'project.xcworkspace/xcshareddata/swiftpm/Package.resolved'))

def modify_samples_build_gradle(args):
    for sample_name in android_sample_names:
        modify_sample_build_gradle(args, os.path.join(sdk_dirs.samples, 'Android', sample_name, 'app/build.gradle'))
    for sample_name in react_native_sample_names:
        modify_sample_build_gradle(args, os.path.join(sdk_dirs.samples, 'ReactNative', sample_name, 'android', 'app/build.gradle'))

def populate_mobile_versions(args, current = False):
    args.current_mobile = get_last_release()
    if not hasattr(args, 'new_mobile') or not args.new_mobile:
        if current:
            args.new_mobile = args.current_mobile
        else:
            args.new_mobile = get_next_release(args.current_mobile)

def get_repo(dir):
    return 'https://' + os.getenv('GH_TOKEN') + '@github.com/iTwin/' + os.path.basename(dir)

def push_dir(dir):
    dir = os.path.realpath(dir)
    print("Pushing in dir: " + dir)
    subprocess.check_call(['git', 'push', get_repo(dir)], cwd=dir)

def release_dir(args, dir):
    dir = os.path.realpath(dir)
    print("Releasing in dir: " + dir)
    if not args.title:
        args.title = 'Release ' + args.new_mobile
    if not args.notes:
        itwin_version = get_latest_itwin_version()
        args.notes = 'Release ' + args.new_mobile + ' on iTwin ' + itwin_version + ''
    subprocess.check_call(['git', 'checkout', git_branch], cwd=dir)
    subprocess.check_call(['git', 'pull'], cwd=dir)
    subprocess.check_call(['git', 'tag', args.new_mobile], cwd=dir)
    subprocess.check_call(['git', 'push', get_repo(dir), args.new_mobile], cwd=dir)
    subprocess.check_call([
        'gh', 'release',
        'create', args.new_mobile,
        '--target', git_branch,
        '--title', args.title,
        '--notes', args.notes,
        ], cwd=dir)
    subprocess.check_call(['git', 'pull'], cwd=dir)
    if dir.endswith('mobile-sdk-ios'):
        release_upload(args, dir, 'itwin-mobile-sdk.podspec')
        release_upload(args, dir, 'AsyncLocationKit.podspec')

def release_upload(args, dir, filename):
    print("Uploading in dir: {} file: {}".format(dir, filename))
    subprocess.check_call(['gh', 'release', 'upload', args.new_mobile, filename], cwd=dir)

def push_command(args, dir, current = False):
    populate_mobile_versions(args, current)
    print("Pushing version: " + args.new_mobile + "\nin dir: " + dir)
    commit_dir(args, dir)
    push_dir(dir)

def push1_command(args):
    push_command(args, sdk_dirs.sdk_ios)
    push_command(args, sdk_dirs.sdk_android)
    push_command(args, sdk_dirs.sdk_core)

def push2_command(args):
    push_command(args, sdk_dirs.ui_react, True)

def push3_command(args):
    push_command(args, sdk_dirs.samples, True)

def show_node_version():
    print("Using node version:")
    subprocess.check_call(['node', '--version'])
    print("Using npm version:")
    subprocess.check_call(['npm', '--version'])

def stage1_command(args):
    show_node_version()
    bump_command(args)
    push1_command(args)

def stage2_command(args):
    show_node_version()
    bumpui_command(args)
    push2_command(args)

def stage3_command(args):
    show_node_version()
    populate_mobile_versions(args)
    # iTiwn/mobile-sdk-ios must be released before we can update the samples to point to it.
    # Release the three main packages in a row, then update and release the samples.
    release_dir(args, sdk_dirs.sdk_ios)
    release_dir(args, sdk_dirs.sdk_android)
    release_dir(args, sdk_dirs.sdk_core)
    release_dir(args, sdk_dirs.ui_react)
    bumpsamples_command(args)
    push3_command(args)
    release_dir(args, sdk_dirs.samples)

def changesamplestest_command(args):
    args.new_commit_id = 'new_commit_id'
    args.new_add_on_commit_id = 'new_add_on_commit_id'
    args.new_mobile = 'new_mobile'
    args.new_add_on = 'new_add_on'
    modify_samples_package_resolved(args)
    modify_samples_project_pbxproj(args)
    modify_samples_build_gradle(args)

def test_command(args):
    show_node_version()
    get_versions(args, True)
    change_command(args)
    changeui_command(args)
    changesamples_command(args)
    npm_install_dir(sdk_dirs.sdk_core)
    npm_install_dir(sdk_dirs.ui_react)
    npm_install_dir(os.path.join(sdk_dirs.samples, react_app_subdir))
    npm_install_dir(os.path.join(sdk_dirs.samples, token_server_subdir))
    npm_build_dir(sdk_dirs.sdk_core)
    npm_build_dir(sdk_dirs.ui_react, True)
    npm_build_dir(os.path.join(sdk_dirs.samples, react_app_subdir), True)
    npm_build_dir(os.path.join(sdk_dirs.samples, token_server_subdir))

def checkversions_command(args):
    get_versions(args)
    print("-------------------------------------------------------------------------------")
    show_node_version()
    print("new_mobile: " + args.new_mobile)
    print("new_itwin: " + args.new_itwin)
    print("new_add_on: " + args.new_add_on)
    print("new_add_on_commit_id: " + args.new_add_on_commit_id)
    get_itwin_non_core_tuples()

def fetch_arg_from_environment(args, env_name):
    value = os.getenv(env_name)
    if not value is None:
        setattr(args, env_name.lower()[4:], value)
        print("Using version from env: " + env_name + "=" + value)

def process_environment(args):
    fetch_arg_from_environment(args, 'ITM_NEW_MOBILE')
    fetch_arg_from_environment(args, 'ITM_NEW_ITWIN')
    fetch_arg_from_environment(args, 'ITM_NEW_ADD_ON')
    fetch_arg_from_environment(args, 'ITM_NEW_ADD_ON_COMMIT_ID')

def get_last_release():
    result = subprocess.check_output(['git', 'tag'], cwd=sdk_dirs.sdk_ios, encoding='UTF-8')
    tags = result.splitlines()
    last_patch = 0
    if isinstance(tags, list):
        for tag in tags:
            match = re.search('^' + mobile_base_version_search_list[-1] + '([0-9]+)$', tag)
            if match and len(match.groups()) == 1:
                this_patch = int(match.group(1))
                if this_patch > last_patch:
                    last_patch = this_patch
    if last_patch > 0:
        return mobile_base_version + str(last_patch)
    return f'{mobile_base_version}0'

def get_next_release(last_release):
    parts = last_release.split('.')
    if len(parts) == 3:
        parts[2] = str(int(parts[2]) + 1)
        new_release = '.'.join(parts)
        return new_release
    raise Exception("Error: Could not parse last release: " + last_release)

def get_latest_itwin_version():
    return get_latest_version(itwin_version_package, itwin_version_prefix)

latest_versions = {}

def get_latest_version(package, prefix):
    key = f'{package}@{prefix}'
    if key in latest_versions:
        return latest_versions[key]
    version_json = subprocess.check_output(['npm', 'view', '--json', key, 'version'])
    version = json.loads(version_json)
    if isinstance(version, str):
        result = version
    else:
        result = version[-1]
    latest_versions[key] = result
    return result

def get_latest_native_version(itwin_version):
    deps = subprocess.check_output(['npm', 'show', native_version_package + '@' + itwin_version, 'dependencies'], encoding='UTF-8')
    match = re.search("'@bentley/imodeljs-native': '([.0-9]+)'", deps)
    if match and len(match.groups()) == 1:
        return match.group(1)

def get_first_entry_of_last_line(results):
    if results:
        lines = results.splitlines()
        last = lines[len(lines)-1]
        entries = last.split()
        return entries[0]

def get_last_commit_id(dir, tag_filter):
    # Todo: Handle first release with a new prefix
    results = subprocess.check_output(['git', 'show-ref', '--tags', tag_filter], cwd=dir, encoding='UTF-8')
    return get_first_entry_of_last_line(results)

def get_last_remote_commit_id(repo, tag_filter):
    results = subprocess.check_output(['git', 'ls-remote', '--tags', repo, tag_filter], encoding='UTF-8')
    return get_first_entry_of_last_line(results)

def get_versions(args, current = False):
    found_all = False
    populate_mobile_versions(args, current)
    print("New release: " + args.new_mobile)

    if not hasattr(args, 'new_itwin') or not args.new_itwin:
        args.new_itwin = get_latest_itwin_version()
    print("iTwin version: " + args.new_itwin)

    if not hasattr(args, 'new_add_on') or not args.new_add_on:
        args.new_add_on = get_latest_native_version(args.new_itwin)

    if args.new_add_on:
        found_all = True
        print("mobile-native-ios version: " + args.new_add_on)
        if not hasattr(args, 'new_add_on_commit_id') or not args.new_add_on_commit_id:
            args.new_add_on_commit_id = get_last_remote_commit_id('https://github.com/iTwin/mobile-native-ios.git', args.new_add_on)
        print("mobile-native-ios revision: " + args.new_add_on_commit_id)

    if not found_all:
        raise Exception("Error: Unable to determine all versions.")

def do_command(args):
    if args.strings:
        all_args = ' '.join(args.strings)
        args = all_args.split()
        for dir in sdk_dirs:
            subprocess.call(args, cwd=dir)

def add_force_argument(parser):
    parser.add_argument('-f', '--force', action='store_true', default=False, help='Force even if local changes already exist')

def add_new_mobile_argument(parser, required=False):
    parser.add_argument('-n', '--new', dest='new_mobile', help='New iTwin Mobile SDK release version', required=required)

def add_common_change_arguments(parser, required=True):
    add_new_mobile_argument(parser, required)
    parser.add_argument('-ni', '--newITwin', dest='new_itwin', help='New @itwin package version', required=required)
    parser.add_argument('-na', '--newAddOn', dest='new_add_on', help='New itwin-mobile-native-ios version', required=required)

def add_common_stage_arguments(parser, new_mobile=True):
    if new_mobile:
        add_new_mobile_argument(parser)
    parser.add_argument('-t', '--title', dest='title', help='Release title')
    parser.add_argument('--notes', dest='notes', help='Release notes')

# We always want to publish our packages using Node 16 (>= 16.11), so check for that.
# This insures that our package-lock.json files are conistent for npm.
def check_node_version():
    print("Verifying that node version is 18.x, with minimum of 18.16.")
    results = subprocess.check_output(['node', '--version'], encoding='UTF-8')
    match = re.search('^v18\\.([0-9]+)\\.', results)
    if not match or int(match.group(1)) < 16:
        raise Exception("Error: Node 18.x required, with minimum of 18.16. You have " + results.rstrip('\n') + ".")
    if len(match.groups()) != 1:
        raise Exception("Error parsing Node version string: " + results.rstrip('\n') + ".")

if __name__ == '__main__':
    parser = argparse.ArgumentParser(
        description='Script for helping with creating a new Mobile SDK version.',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=textwrap.dedent('''\
            Order of operations
            -------------------
            1. newVersion.py stage1
            2. Wait for @itwin/mobile-sdk-core to be npm published
            3. newVersion.py stage2
            4. Wait for @itwin/mobile-ui-react to be npm published
            5. newVersion.py stage3
            '''))
    parser.add_argument('-d', '--parentDir', dest='parent_dir', help='The parent directory of the iTwin Mobile SDK GitHub repositories')
    sub_parsers = parser.add_subparsers(title='Commands', metavar='')

    parser_change = sub_parsers.add_parser('change', help='Change version (alternative to bump, specify versions)')
    parser_change.set_defaults(func=change_command)
    add_common_change_arguments(parser_change)
    add_force_argument(parser_change)

    parser_bump = sub_parsers.add_parser('bump', help='Create new point release')
    parser_bump.set_defaults(func=bump_command)
    add_new_mobile_argument(parser_bump)
    add_force_argument(parser_bump)

    parser_changeitwin = sub_parsers.add_parser('changeitwin', help='Change iTwin version (alternative to bumpitwin, specify versions)')
    parser_changeitwin.set_defaults(func=changeitwin_command)
    add_common_change_arguments(parser_changeitwin)
    add_force_argument(parser_changeitwin)

    parser_bumpitwin = sub_parsers.add_parser('bumpitwin', help='Update all locally for new iTwin version')
    parser_bumpitwin.set_defaults(func=bumpitwin_command)
    add_common_change_arguments(parser_bumpitwin, False)
    add_force_argument(parser_bumpitwin)

    parser_changeui = sub_parsers.add_parser('changeui', help='Change version for mobile-ui-react (alternative to bumpui, specify versions)')
    parser_changeui.set_defaults(func=changeui_command)
    add_common_change_arguments(parser_changeui)

    parser_bumpui = sub_parsers.add_parser('bumpui', help='Update mobile-ui-react to reflect published mobile-core')
    parser_bumpui.set_defaults(func=bumpui_command)
    add_new_mobile_argument(parser_bumpui)

    parser_changesamples = sub_parsers.add_parser('changesamples', help='Alternative to bumpsamples: must specify versions')
    parser_changesamples.set_defaults(func=changesamples_command)
    add_common_change_arguments(parser_changesamples)

    parser_bumpsamples = sub_parsers.add_parser('bumpsamples', help='Update mobile-samples to reflect published mobile-core')
    parser_bumpsamples.set_defaults(func=bumpsamples_command)
    add_new_mobile_argument(parser_bumpsamples)

    parser_stage1 = sub_parsers.add_parser('stage1', help='Execute bump then release1')
    parser_stage1.set_defaults(func=stage1_command)
    add_common_stage_arguments(parser_stage1)
    add_force_argument(parser_stage1)

    parser_stage2 = sub_parsers.add_parser('stage2', help='Execute bumpui then release2')
    parser_stage2.set_defaults(func=stage2_command)
    add_common_stage_arguments(parser_stage2)

    parser_stage3 = sub_parsers.add_parser('stage3', help='Execute bumpsamples then release3')
    parser_stage3.set_defaults(func=stage3_command)
    add_common_stage_arguments(parser_stage3, False)

    parser_do = sub_parsers.add_parser('do', help='Run a command in each dir')
    parser_do.set_defaults(func=do_command)
    parser_do.add_argument('-p', '--print', action='store_true', default=False, help='Print each dir')
    parser_do.add_argument('strings', metavar='arg', nargs='+')

    parser_test = sub_parsers.add_parser('test', help='Local test of new iTwin release.')
    parser_test.set_defaults(func=test_command)
    add_common_change_arguments(parser_test, False)
    add_force_argument(parser_test)

    parser_checkversions = sub_parsers.add_parser('checkversions', help='Check versions for next release.')
    parser_checkversions.set_defaults(func=checkversions_command)

    parser_changesamplestest = sub_parsers.add_parser('changesamplestest', help='Test command')
    parser_changesamplestest.set_defaults(func=changesamplestest_command)

    args = parser.parse_args()

    process_environment(args)
    sdk_dirs = MobileSdkDirs(args)

    try:
        if hasattr(args, 'func'):
            check_node_version()
            args.func(args)
        else:
            parser.print_help()
    except Exception as error:
        # Uncomment this to see the standard traceback
        # traceback.print_exc()
        print(error)
        exit(1)
