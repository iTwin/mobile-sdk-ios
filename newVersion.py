#!/usr/bin/env python3
import argparse
from concurrent.futures import process
import fileinput
import re
import subprocess
import sys
import os
import textwrap

# ===================================================================================
# Begin editable globals.
# This section contains global variables with values that might change in the future.
# ===================================================================================

# iTwin base version to search for. 3.0.x for now.
itwin_base_version_search = "3\\.0\\."
# iTwin Mobile SDK base version. 0.10.x for now.
mobile_base_version = "0.10."
# iTwin Mobile SDK base version to search for. 0.10.x for now.
mobile_base_version_search = "0\\.10\\."
# The search string for Bentley's JS package (iTwin.js or imodeljs).
js_package_search = "__iTwin\\.js "
# The search string for itwin-mobile-native
native_package_search = "`itwin-mobile-native` CocoaPod to version "
# Subdirectory under mobile-samples of react-app.
react_app_subdir = 'cross-platform/react-app'
# Subdirectory under mobile-samples of token-server.
token_server_subdir = 'cross-platform/token-server'
# The scope for iTwin npm packages.
itwin_scope = '@itwin'
# The package used to determine the current version of iTwin
itwin_version_package = '@itwin/core-common'
# The package whose dependencies determine the current add-on version.
native_version_package = '@itwin/core-backend'
# The names of the sample apps
sample_names = [
    'MobileStarter',
    'SwiftUIStarter',
    'ThirdPartyAuth',
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
        self.sdk_core = self.dirs[1]
        self.ui_react = self.dirs[2]
        self.samples = self.dirs[3]

    def __iter__(self):
        return iter(self.dirs)

def replace_all(filename, replacements):
    num_found = 0
    for line in fileinput.input(filename, inplace=1):
        newline = line
        for (search_exp, replace_exp) in replacements:
            if re.search(search_exp, newline):
                num_found += 1
                newline = re.sub(search_exp, replace_exp, newline)
        sys.stdout.write(newline)
    return num_found

def modify_package_json(args, dir):
    filename = os.path.join(dir, 'package.json')
    if os.path.exists(filename):
        print("Processing: " + filename)
        # IMPORTANT: The @itwin/mobile-sdk-core and @itwin/mobile-ui-react replacements must
        # come last.
        if replace_all(filename, [
            ('("version": )"[.0-9a-z-]+', '\\1"' + args.new_mobile),
            ('("' + itwin_scope + '/[0-9a-z-]+"): "' + itwin_base_version_search + '[.0-9a-z-]+', '\\1: "' + args.new_itwin),
            ('("@itwin/mobile-sdk-core"): "[.0-9a-z-]+', '\\1: "' + args.current_mobile),
            ('("@itwin/mobile-ui-react"): "[.0-9a-z-]+', '\\1: "' + args.current_mobile),
        ]) < 2:
            raise Exception("Not enough replacements")

def modify_readme_md(args):
    filename = os.path.join(sdk_dirs.sdk_ios, 'README.md')
    if not os.path.exists(filename):
        raise Exception("Error: Cannot find mobile-sdk-ios/README.md")
    print("Processing: " + filename)
    if replace_all(filename, [
        ('("Dependency Rule" to "Exact Version" and the version to ")' + mobile_base_version_search + '[.0-9a-z-]+', '\\g<1>' + args.new_mobile),
        ('("https:\\/\\/github.com\\/iTwin\\/mobile-sdk-ios", .exact\\(")' + mobile_base_version_search + '[.0-9a-z-]+', '\\g<1>' + args.new_mobile),
        ('(https:\\/\\/github.com\\/iTwin\\/mobile-native-ios\\/releases\\/download\\/)' + itwin_base_version_search + '[.0-9a-z-]+', '\\g<1>' + args.new_add_on),
        ('(https:\\/\\/github.com\\/iTwin\\/mobile-sdk-ios\\/releases\\/download\\/)' + mobile_base_version_search + '[.0-9a-z-]+', '\\g<1>' + args.new_mobile),
        ('(' + js_package_search + ')' + itwin_base_version_search + '[.0-9a-z-]+', '\\g<1>' + args.new_itwin),
        ('(' + native_package_search + ')' + itwin_base_version_search + '[.0-9a-z-]+', '\\g<1>' + args.new_add_on),
    ]) < 6:
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

def modify_package_resolved(args, filename):
    print("Processing: " + os.path.realpath(filename))
    package = None
    for line in fileinput.input(filename, inplace=1):
        match = re.search('"package": "(.*)"', line)
        if match and len(match.groups()) == 1:
            package = match.group(1)
        if package == 'itwin-mobile-native':
            line = re.sub('("version": )".*"', '\\1"' + args.new_add_on + '"', line)
            if (args.new_add_on_commit_id):
                line = re.sub('("revision": )".*"', '\\1"' + args.new_add_on_commit_id + '"', line)
        elif package == 'itwin-mobile-sdk':
            line = re.sub('("version": )".*"', '\\1"' + args.new_mobile + '"', line)
            if (args.new_commit_id):
                line = re.sub('("revision": )".*"', '\\1"' + args.new_commit_id + '"', line)
        sys.stdout.write(line)

def change_command(args):
    if not args.force:
        ensure_no_dirs_have_diffs()
    if not args.current_mobile:
        args.current_mobile = get_last_release()
    modify_package_swift(args, os.path.join(sdk_dirs.sdk_ios, 'Package.swift'))
    modify_package_swift(args, os.path.join(sdk_dirs.sdk_ios, 'Package@swift-5.5.swift'))
    modify_package_resolved(args, os.path.join(sdk_dirs.sdk_ios, 'Package.resolved'))
    modify_podspec(args, os.path.join(sdk_dirs.sdk_ios, 'itwin-mobile-sdk.podspec'))
    modify_package_json(args, sdk_dirs.sdk_core)
    modify_readme_md(args)

def bump_command(args):
    if not args.force:
        ensure_no_dirs_have_diffs()
    get_versions(args)
    change_command(args)
    npm_install_dir(args, sdk_dirs.sdk_core)

def changeui_command(args):
    args.current_mobile = args.new_mobile
    modify_package_json(args, sdk_dirs.ui_react)

def npm_install_dir(args, dir):
    subprocess.check_call(['npm', 'install'], cwd=dir)

def bumpui_command(args):
    get_versions(args)
    changeui_command(args)
    npm_install_dir(args, sdk_dirs.ui_react)

def changesamples_command(args):
    args.current_mobile = args.new_mobile
    modify_package_json(args, os.path.join(sdk_dirs.samples, react_app_subdir))
    modify_package_json(args, os.path.join(sdk_dirs.samples, token_server_subdir))
    modify_samples_package_resolved(args)
    modify_samples_project_pbxproj(args)

def bumpsamples_command(args):
    get_versions(args)
    changesamples_command(args)
    npm_install_dir(args, os.path.join(sdk_dirs.samples, react_app_subdir))
    npm_install_dir(args, os.path.join(sdk_dirs.samples, token_server_subdir))

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
        subprocess.check_call(['git', 'add', '.'], cwd=dir)
        subprocess.check_call(['git', 'commit', '-m', 'Update version to ' + args.new_mobile], cwd=dir)
    else:
        print("Nothing to commit.")

def get_xcodeproj_dirs():
    xcodeproj_dirs = []
    for sample_name in sample_names:
        xcodeproj_dirs.append(os.path.join(sdk_dirs.samples, 'iOS', sample_name, sample_name + '.xcodeproj'))
        xcodeproj_dirs.append(os.path.join(sdk_dirs.samples, 'iOS', sample_name, 'LocalSDK_' + sample_name + '.xcodeproj'))
    return xcodeproj_dirs

def modify_samples_project_pbxproj(args):
    if not hasattr(args, 'new_commit_id'):
        args.new_commit_id = get_last_commit_id(sdk_dirs.sdk_ios, args.new_mobile)
    for dir in get_xcodeproj_dirs():
        modify_project_pbxproj(args, os.path.join(dir, 'project.pbxproj'))

def modify_samples_package_resolved(args):
    if not hasattr(args, 'new_commit_id'):
        args.new_commit_id = get_last_commit_id(sdk_dirs.sdk_ios, args.new_mobile)
    for dir in get_xcodeproj_dirs():
        modify_package_resolved(args, os.path.join(dir, 'project.xcworkspace/xcshareddata/swiftpm/Package.resolved'))

def populate_mobile_versions(args, current = False):
    args.current_mobile = get_last_release()
    if not hasattr(args, 'new_mobile') or not args.new_mobile:
        if current:
            args.new_mobile = args.current_mobile
        else:
            args.new_mobile = get_next_release(args.current_mobile)

def push_dir(args, dir):
    dir = os.path.realpath(dir)
    print("Pushing in dir: " + dir)
    subprocess.check_call(['git', 'push'], cwd=dir)

def release_dir(args, dir):
    dir = os.path.realpath(dir)
    print("Releasing in dir: " + dir)
    if not args.title:
        args.title = 'Release ' + args.new_mobile
    if not args.notes:
        itwin_version = get_latest_itwin_version()
        args.notes = 'Release ' + args.new_mobile + ' on iTwin ' + itwin_version + ''
    subprocess.check_call(['git', 'pull'], cwd=dir)
    subprocess.check_call(['git', 'tag', args.new_mobile], cwd=dir)
    subprocess.check_call(['git', 'push', 'origin', args.new_mobile], cwd=dir)
    subprocess.check_call([
        'gh', 'release',
        'create', args.new_mobile,
        '--target', 'main',
        '--title', args.title,
        '--notes', args.notes,
        ], cwd=dir)
    subprocess.check_call(['git', 'pull'], cwd=dir)
    if dir.endswith('mobile-sdk-ios'):
        release_upload(args, dir, 'itwin-mobile-sdk.podspec')

def release_upload(args, dir, filename):
    print("Uploading in dir: {} file: {}".format(dir, filename))
    subprocess.check_call(['gh', 'release', 'upload', args.new_mobile, filename], cwd=dir)

def push_command(args, dir, current = False):
    populate_mobile_versions(args, current)
    print("Pushing version: " + args.new_mobile + "\nin dir: " + dir)
    commit_dir(args, dir)
    push_dir(args, dir)

def push1_command(args):
    push_command(args, sdk_dirs.sdk_ios)
    push_command(args, sdk_dirs.sdk_core)

def push2_command(args):
    push_command(args, sdk_dirs.ui_react, True)

def push3_command(args):
    push_command(args, sdk_dirs.samples, True)

def stage1_command(args):
    bump_command(args)
    push1_command(args)

def stage2_command(args):
    bumpui_command(args)
    push2_command(args)

def stage3_command(args):
    populate_mobile_versions(args)
    # iTiwn/mobile-sdk-ios must be released before we can update the samples to point to it.
    # Release the three main packages in a row, then update and release the samples.
    release_dir(args, sdk_dirs.sdk_ios)
    release_dir(args, sdk_dirs.sdk_core)
    release_dir(args, sdk_dirs.ui_react)
    bumpsamples_command(args)
    push3_command(args)
    release_dir(args, sdk_dirs.samples)

def get_last_release():
    result = subprocess.check_output(['git', 'tag'], cwd=sdk_dirs.sdk_ios, encoding='UTF-8')
    tags = result.splitlines()
    last_patch = 0
    if isinstance(tags, list):
        for tag in tags:
            match = re.search('^' + mobile_base_version_search + '([0-9]+)$', tag)
            if match and len(match.groups()) == 1:
                this_patch = int(match.group(1))
                if this_patch > last_patch:
                    last_patch = this_patch
    if last_patch > 0:
        return mobile_base_version + str(last_patch)
    raise Exception("Error: could not determine last release.")

def get_next_release(last_release):
    parts = last_release.split('.')
    if len(parts) == 3:
        parts[2] = str(int(parts[2]) + 1)
        new_release = '.'.join(parts)
        return new_release
    raise Exception("Error: Could not parse last release: " + last_release)

def get_latest_itwin_version():
    dist_tags = subprocess.check_output(['npm', 'dist-tag', itwin_version_package], encoding='UTF-8')
    match = re.search('latest: ([.0-9]+)', dist_tags)
    if match and len(match.groups()) == 1:
        return match.group(1)

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
    results = subprocess.check_output(['git', 'show-ref', '--tags', tag_filter], cwd=dir, encoding='UTF-8')
    return get_first_entry_of_last_line(results)

def get_last_remote_commit_id(repo, tag_filter):
    results = subprocess.check_output(['git', 'ls-remote', '--tags', repo, tag_filter], encoding='UTF-8')
    return get_first_entry_of_last_line(results)

def get_versions(args, current = False):
    found_all = False
    populate_mobile_versions(args, current)

    print("New release: " + args.new_mobile)
    itwin_version = get_latest_itwin_version()
    print("iTwin version: " + itwin_version)
    add_on_version = get_latest_native_version(itwin_version)
    if add_on_version:
        found_all = True
        print("mobile-native-ios version: " + add_on_version)
        add_on_commit_id = get_last_remote_commit_id('https://github.com/iTwin/mobile-native-ios.git', add_on_version)
        print("mobile-native-ios revision: " + add_on_commit_id)

    if not found_all:
        raise Exception("Error: Unable to determine all versions.")
    args.new_mobile = args.new_mobile
    args.new_itwin = itwin_version
    args.new_add_on = add_on_version
    args.new_add_on_commit_id = add_on_commit_id

def do_command(args):
    if args.strings:
        all_args = ' '.join(args.strings)
        args = all_args.split()
        for dir in sdk_dirs:
            subprocess.call(args, cwd=dir)

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
    parser_change.add_argument('-n', '--new', dest='new_mobile', help='New iTwin Mobile SDK release version', required=True)
    parser_change.add_argument('-ni', '--newITwin', dest='new_itwin', help='New @itwin package version', required=True)
    parser_change.add_argument('-na', '--newAddOn', dest='new_add_on', help='New itwin-mobile-native-ios version', required=True)
    parser_change.add_argument('-f', '--force', action=argparse.BooleanOptionalAction, dest='force', help='Force even if local changes already exist')

    parser_bump = sub_parsers.add_parser('bump', help='Create new point release')
    parser_bump.set_defaults(func=bump_command)
    parser_bump.add_argument('-n', '--new', dest='new_mobile', help='New iTwin Mobile SDK release version')
    parser_bump.add_argument('-f', '--force', action=argparse.BooleanOptionalAction, dest='force', help='Force even if local changes already exist')

    parser_changeui = sub_parsers.add_parser('changeui', help='Change version for mobile-ui-react (alternative to bumpui, specify versions)')
    parser_changeui.set_defaults(func=changeui_command)
    parser_changeui.add_argument('-n', '--new', dest='new_mobile', help='New iTwin Mobile SDK release version', required=True)
    parser_changeui.add_argument('-ni', '--newITwin', dest='new_itwin', help='New @itwin package version', required=True)
    parser_changeui.add_argument('-na', '--newAddOn', dest='new_add_on', help='New itwin-mobile-native-ios version', required=True)

    parser_bumpui = sub_parsers.add_parser('bumpui', help='Update mobile-ui-react to reflect published mobile-core')
    parser_bumpui.set_defaults(func=bumpui_command)
    parser_bumpui.add_argument('-n', '--new', dest='new_mobile', help='New iTwin Mobile SDK release version')

    parser_changesamples = sub_parsers.add_parser('changesamples', help='Alternative to bumpsamples: must specify versions')
    parser_changesamples.set_defaults(func=changesamples_command)
    parser_changesamples.add_argument('-n', '--new', dest='new_mobile', help='New iTwin Mobile SDK release version', required=True)
    parser_changesamples.add_argument('-ni', '--newITwin', dest='new_itwin', help='New @itwin package version', required=True)
    parser_changesamples.add_argument('-na', '--newAddOn', dest='new_add_on', help='New itwin-mobile-native-ios version', required=True)

    parser_bumpsamples = sub_parsers.add_parser('bumpsamples', help='Update mobile-samples to reflect published mobile-core')
    parser_bumpsamples.set_defaults(func=bumpsamples_command)
    parser_bumpsamples.add_argument('-n', '--new', dest='new_mobile', help='New iTwin Mobile SDK release version')

    parser_stage1 = sub_parsers.add_parser('stage1', help='Execute bump then release1')
    parser_stage1.set_defaults(func=stage1_command)
    parser_stage1.add_argument('-n', '--new', dest='new_mobile', help='New iTwin Mobile SDK release version')
    parser_stage1.add_argument('-t', '--title', dest='title', help='Release title')
    parser_stage1.add_argument('--notes', dest='notes', help='Release notes')
    parser_stage1.add_argument('-f', '--force', action=argparse.BooleanOptionalAction, dest='force', help='Force even if local changes already exist')

    parser_stage2 = sub_parsers.add_parser('stage2', help='Execute bumpui then release2')
    parser_stage2.set_defaults(func=stage2_command)
    parser_stage2.add_argument('-n', '--new', dest='new_mobile', help='New iTwin Mobile SDK release version')
    parser_stage2.add_argument('-t', '--title', dest='title', help='Release title')
    parser_stage2.add_argument('--notes', dest='notes', help='Release notes')

    parser_stage3 = sub_parsers.add_parser('stage3', help='Execute bumpsamples then release3')
    parser_stage3.set_defaults(func=stage3_command)
    parser_stage3.add_argument('-t', '--title', dest='title', help='Release title')
    parser_stage3.add_argument('--notes', dest='notes', help='Release notes')

    parser_do = sub_parsers.add_parser('do', help='Run a command in each dir')
    parser_do.set_defaults(func=do_command)
    parser_do.add_argument('strings', metavar='arg', nargs='+')

    args = parser.parse_args()
    sdk_dirs = MobileSdkDirs(args)

    try:
        if hasattr(args, 'func'):
            args.func(args)
        else:
            parser.print_help()
    except Exception as error:
        print(error)
        exit(1)
