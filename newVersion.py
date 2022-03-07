#!/usr/bin/env python3
import argparse
import fileinput
import re
import subprocess
import sys
import os
import textwrap

# iTwin base version to search for. 3.0.x for now.
itwin_base_version = "3\\.0\\."
# iTwin Mobile SDK base version to search for. 0.10.x for now.
mobile_base_version = "0\\.10\\."
# Subdirectory under mobile-samples of react-app.
react_app_subdir = 'cross-platform/react-app'
# The relative paths to the elements in the dirs array
relative_dirs = [
    '.',
    '../mobile-sdk-core',
    '../mobile-ui-react',
    '../mobile-samples',
]
# The names of the sample apps
sample_names = [
    'MobileStarter',
    'SwiftUIStarter',
    'ThirdPartyAuth',
]
# Indices of the elements of the dirs array
mobile_sdk_ios_dir_index = 0
mobile_sdk_core_dir_index = 1
mobile_ui_react_dir_index = 2
mobile_samples_dir_index = 3

def get_executing_directory():
    return os.path.dirname(os.path.realpath(__file__))

def replace_all(filename, replacements):
    num_found = 0
    for line in fileinput.input(filename, inplace=1):
        newline = line
        found_on_line = False
        for (search_exp, replace_exp) in replacements:
            if re.search(search_exp, newline):
                found_on_line = True
                newline = re.sub(search_exp, replace_exp, newline)
        sys.stdout.write(newline)
        if found_on_line:
            num_found += 1
    return num_found

def modify_package_json(args, dir):
    filename = os.path.join(dir, 'package.json')
    if os.path.exists(filename):
        print("Processing: " + filename)
        # IMPORTANT: The @itwin/mobile-sdk-core and @itwin/mobile-ui-react replacements must
        # come last.
        if replace_all(filename, [
            ('("version": )"[.0-9a-z-]+', '\\1"' + args.new_mobile),
            ('("@itwin/[0-9a-z-]+"): "' + itwin_base_version + '[.0-9a-z-]+', '\\1: "' + args.new_itwin),
            ('("@itwin/mobile-sdk-core"): "[.0-9a-z-]+', '\\1: "' + args.current_mobile),
            ('("@itwin/mobile-ui-react"): "[.0-9a-z-]+', '\\1: "' + args.current_mobile),
        ]) < 2:
            print("Not enough replacements")
        # if not args.skip_install:
        #     result = subprocess.check_output(['npm', 'install', '--no-progress', '--loglevel=error', '--audit=false', '--fund=false'], cwd=dir)

def modify_package_swift(args, filename):
    print("Processing: " + os.path.realpath(filename))
    if replace_all(filename, [('(mobile-native-ios", .exact\\()"[.0-9a-z-]+', '\\1"' + args.new_add_on)]) != 1:
        print("Not enough replacements")

def modify_podspec(args, filename):
    print("Processing: " + os.path.realpath(filename))
    replacements = [('(spec\\.version\\s+=\\s+")[.0-9a-z-]+"', '\\g<1>' + args.new_mobile + '"')]
    replacements.append(('(spec\\.dependency\\s+"itwin-mobile-native",\\s+")[.0-9a-z-]+"', '\\g<1>' + args.new_add_on + '"'))
    if replace_all(filename, replacements) != 2:
        print("Not enough replacements")

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

def change_command(args, dirs):
    if not args.force:
        ensure_no_dirs_have_diffs(dirs)
    mobile_core_ios_dir = executing_dir
    if not args.current_mobile:
        args.current_mobile = get_last_release()
    modify_package_swift(args, os.path.join(mobile_core_ios_dir, 'Package.swift'))
    modify_package_swift(args, os.path.join(mobile_core_ios_dir, 'Package@swift-5.5.swift'))
    modify_package_resolved(args, os.path.join(mobile_core_ios_dir, 'Package.resolved'))
    modify_podspec(args, os.path.join(mobile_core_ios_dir, 'itwin-mobile-sdk.podspec'))
    modify_package_json(args, dirs[mobile_sdk_core_dir_index])
    modify_package_json(args, dirs[mobile_ui_react_dir_index])
    modify_package_json(args, os.path.join(dirs[mobile_samples_dir_index], react_app_subdir))

def bump_command(args, dirs):
    if not args.force:
        ensure_no_dirs_have_diffs(dirs)
    get_versions(args)
    change_command(args, dirs)

def bumpbranch_command(args, dirs):
    bump_command(args, dirs)
    branch_command(args, dirs)

def changeui_command(args, dirs):
    args.current_mobile = args.new_mobile
    modify_package_json(args, dirs[mobile_ui_react_dir_index])

def npm_install_dir(args, dir):
    subprocess.check_call(['npm', 'install'], cwd=dir)

def bumpui_command(args, dirs):
    get_versions(args, True)
    changeui_command(args, dirs)
    npm_install_dir(args, dirs[mobile_ui_react_dir_index])

def changesamples_command(args, dirs):
    samples_dir = dirs[mobile_samples_dir_index]
    args.current_mobile = args.new_mobile
    modify_package_json(args, os.path.join(samples_dir, react_app_subdir))
    modify_samples_package_resolved(args, samples_dir)
    modify_samples_project_pbxproj(args, samples_dir)

def bumpsamples_command(args, dirs):
    get_versions(args, True)
    changesamples_command(args, dirs)
    npm_install_dir(args, os.path.join(dirs[mobile_samples_dir_index], react_app_subdir))

def dir_has_diff(dir):
    return subprocess.call(['git', 'diff', '--quiet'], cwd=dir) != 0

def ensure_all_dirs_have_diffs(dirs):
    should_throw = False
    for dir in dirs:
        if not dir_has_diff(dir):
            print("No diffs in dir: " + dir)
            should_throw = True
    if should_throw:
        raise Exception("Error: Diffs are required")

def ensure_no_dirs_have_diffs(dirs):
    should_throw = False
    for dir in dirs:
        if dir_has_diff(dir):
            print("Diffs in dir: " + dir)
            should_throw = True
    if should_throw:
        raise Exception("Error: Diffs are not allowed")

def branch_dir(args, dir):
    print("Branching in dir: " + dir)
    if dir_has_diff(dir):
        subprocess.check_call(['git', 'checkout', '-b', 'stage-release/' + args.new_mobile], cwd=dir)
    else:
        print("Branch unnecessary: nothing to commit.")

def commit_dir(args, dir):
    print("Committing in dir: " + dir)
    if dir_has_diff(dir):
        subprocess.check_call(['git', 'add', '.'], cwd=dir)
        subprocess.check_call(['git', 'commit', '-m', 'Update version to ' + args.new_mobile], cwd=dir)
    else:
        print("Nothing to commit.")

def get_xcodeproj_dirs(samples_dir):
    dirs = []
    for sample_name in sample_names:
        dirs.append(os.path.join(samples_dir, 'iOS', sample_name, sample_name + '.xcodeproj'))
        dirs.append(os.path.join(samples_dir, 'iOS', sample_name, 'LocalSDK_' + sample_name + '.xcodeproj'))
    return dirs

def modify_samples_project_pbxproj(args, samples_dir):
    if not hasattr(args, 'new_commit_id'):
        args.new_commit_id = get_last_commit_id(executing_dir, args.new_mobile)
    for dir in get_xcodeproj_dirs(samples_dir):
        modify_project_pbxproj(args, os.path.join(dir, 'project.pbxproj'))

def modify_samples_package_resolved(args, samples_dir):
    if not hasattr(args, 'new_commit_id'):
        args.new_commit_id = get_last_commit_id(executing_dir, args.new_mobile)
    for dir in get_xcodeproj_dirs(samples_dir):
        modify_package_resolved(args, os.path.join(dir, 'project.xcworkspace/xcshareddata/swiftpm/Package.resolved'))

def branch_command(args, dirs):
    if not args.force:
        ensure_all_dirs_have_diffs(dirs)
    populate_mobile_versions(args)

    print("Branching version: " + args.new_mobile)
    for dir in dirs:
        branch_dir(args, dir)

def commit_command(args, dirs):
    ensure_all_dirs_have_diffs(dirs)
    populate_mobile_versions(args)

    print("Committing version: " + args.new_mobile)
    for dir in dirs:
        # The Package.resolved files in the sample projects need to be updated with the latest info.
        # This assumes we've already committed in the mobile-sdk dir so we'll have  a commit id that we can write to the files.
        if dir.endswith('mobile-samples'):
            modify_samples_package_resolved(args, dir)
        commit_dir(args, dir)

def pr_dir(args, dir):
    print("Creating GitHub PR in dir: " + dir)
    subprocess.check_call(['gh', 'pr', 'create', '--fill'], cwd=dir)

def populate_mobile_versions(args, current = False):
    args.current_mobile = get_last_release()
    if not args.new_mobile:
        if current:
            args.new_mobile = args.current_mobile
        else:
            args.new_mobile = get_next_release(args.current_mobile)

def create_pr(args, dir, current = False):
    if not dir_has_diff(dir):
        raise Exception("Error: Diffs are required")
    populate_mobile_versions(args, current)

    print("PR processing for version: " + args.new_mobile + "\nin dir: " + dir)
    commit_dir(args, dir)
    push_dir(args, dir)
    pr_dir(args, dir)

def pr1_command(args, dirs):
    create_pr(args, dirs[mobile_sdk_ios_dir_index])
    create_pr(args, dirs[mobile_sdk_core_dir_index])

def pr2_command(args, dirs):
    create_pr(args, dirs[mobile_ui_react_dir_index], True)

def pr3_command(args, dirs):
    create_pr(args, dirs[mobile_samples_dir_index], True)

def push_dir(args, dir):
    dir = os.path.realpath(dir)
    print("Pushing in dir: " + dir)
    subprocess.check_call(['git', 'push', '--set-upstream', 'origin', 'stage-release/' + args.new_mobile], cwd=dir)

def push_command(args, dirs):
    for dir in dirs:
        push_dir(args, dir)

def release_dir(args, dir):
    dir = os.path.realpath(dir)
    print("Releasing in dir: " + dir)
    if not args.title:
        args.title = 'Release ' + args.new_mobile
    if not args.notes:
        itwin_version = get_latest_itwin_version()
        args.notes = 'Release ' + args.new_mobile + ' on iTwin ' + itwin_version + ''
    subprocess.check_call(['git', 'checkout', 'main'], cwd=dir)
    subprocess.check_call(['git', 'pull'], cwd=dir)
    subprocess.check_call(['git', 'tag', args.new_mobile], cwd=dir)
    subprocess.check_call(['git', 'push', 'origin', args.new_mobile], cwd=dir)
    subprocess.check_call(['gh', 'release', 'create', args.new_mobile, '--title', args.title, '--notes', args.notes], cwd=dir)
    subprocess.check_call(['git', 'pull'], cwd=dir)

def release_upload(args, dir, filename):
    print("Uploading in dir: {} file: {}".format(dir, filename))
    subprocess.check_call(['gh', 'release', 'upload', args.new_mobile, filename], cwd=dir)

def create_release(args, dir, current = False):
    populate_mobile_versions(args, current)
    print("Releasing version: " + args.new_mobile + "\nin dir: " + dir)
    release_dir(args, dir)
    if dir.endswith('mobile-sdk-ios'):
        release_upload(args, dir, 'itwin-mobile-sdk.podspec')

def release1_command(args, dirs):
    create_release(args, dirs[mobile_sdk_ios_dir_index])
    create_release(args, dirs[mobile_sdk_core_dir_index])

def release2_command(args, dirs):
    create_release(args, dirs[mobile_ui_react_dir_index], True)

def release3_command(args, dirs):
    create_release(args, dirs[mobile_samples_dir_index], True)

def get_last_release():
    result = subprocess.check_output(['git', 'tag'], cwd=executing_dir, encoding='UTF-8')
    tags = result.splitlines()
    last_patch = 0
    if isinstance(tags, list):
        for tag in tags:
            match = re.search('^' + mobile_base_version + '([0-9]+)$', tag)
            if match and len(match.groups()) == 1:
                this_patch = int(match.group(1))
                if this_patch > last_patch:
                    last_patch = this_patch
    if last_patch > 0:
        return '0.10.' + str(last_patch)
    raise Exception("Error: could not determine last release.")

def get_next_release(last_release):
    parts = last_release.split('.')
    if len(parts) == 3:
        parts[2] = str(int(parts[2]) + 1)
        new_release = '.'.join(parts)
        return new_release
    raise Exception("Error: Could not parse last release: " + last_release)

def get_latest_itwin_version():
    dist_tags = subprocess.check_output(['npm', 'dist-tag', '@itwin/core-common'], encoding='UTF-8')
    match = re.search('latest: ([.0-9]+)', dist_tags)
    if match and len(match.groups()) == 1:
        return match.group(1)

def get_latest_native_version(itwin_version):
    deps = subprocess.check_output(['npm', 'show', '@itwin/core-backend@' + itwin_version, 'dependencies'], encoding='UTF-8')
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

def do_command(args, dirs):
    if args.strings:
        all_args = ' '.join(args.strings)
        args = all_args.split()
        for dir in dirs:
            subprocess.call(args, cwd=dir)

if __name__ == '__main__':
    executing_dir = get_executing_directory()
    parent_dir = os.path.realpath(os.path.join(executing_dir, '..'))
    dirs = []
    for dir in relative_dirs:
        dirs.append(os.path.realpath(executing_dir + '/' + dir))

    parser = argparse.ArgumentParser(
        description='Script for helping with creating a new Mobile SDK version.',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=textwrap.dedent('''\
            Order of operations
            -------------------
            1. newVersion.py bumpbranch
            2. newVersion.py pr1
            3. Get iTwin/mobile-sdk-ios PR approved
            4. Get iTwin/mobile-sdk-core PR approved
            5. newVersion.py release1
            6. Wait for @itwin/mobile-sdk-core to be npm published
            7. newVersion.py bumpui
            8. newVersion.py pr2
            9. Get iTwin/mobile-ui-react PR approved
            10. newVersion.py release2
            11. Wait for @itwin/mobile-ui-react to be npm published
            12. newVersion.py bumpsamples
            13. newVersion.py pr3
            14. Get iTwin/mobile-samples PR approved
            15. newVersion.py release3
            '''))
    sub_parsers = parser.add_subparsers(title='Commands', metavar='')

    parser_commit = sub_parsers.add_parser('branch', help='Branch changes')
    parser_commit.set_defaults(func=branch_command)
    parser_commit.add_argument('-n', '--new', dest='new_mobile', help='New iTwin Mobile SDK release version')
    parser_commit.add_argument('-f', '--force', action=argparse.BooleanOptionalAction, dest='force', help='Force even if local changes don\'t exist in all directories')

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

    parser_bump = sub_parsers.add_parser('bumpbranch', help='Execute bump then branch')
    parser_bump.set_defaults(func=bumpbranch_command)
    parser_bump.add_argument('-n', '--new', dest='new_mobile', help='New iTwin Mobile SDK release version')
    parser_bump.add_argument('-f', '--force', action=argparse.BooleanOptionalAction, dest='force', help='Force even if local changes already exist')

    parser_change_ui = sub_parsers.add_parser('changeui', help='Change version for mobile-ui-react (alternative to bumpui, specify versions)')
    parser_change_ui.set_defaults(func=changeui_command)
    parser_change_ui.add_argument('-n', '--new', dest='new_mobile', help='New iTwin Mobile SDK release version', required=True)
    parser_change_ui.add_argument('-ni', '--newITwin', dest='new_itwin', help='New @itwin package version', required=True)
    parser_change_ui.add_argument('-na', '--newAddOn', dest='new_add_on', help='New itwin-mobile-native-ios version', required=True)

    parser_bump_ui = sub_parsers.add_parser('bumpui', help='Update mobile-ui-react to reflect published mobile-core')
    parser_bump_ui.set_defaults(func=bumpui_command)
    parser_bump_ui.add_argument('-n', '--new', dest='new_mobile', help='New iTwin Mobile SDK release version')

    parser_change_samples = sub_parsers.add_parser('changesamples', help='Alternative to bumpsamples: must specify versions')
    parser_change_samples.set_defaults(func=changesamples_command)
    parser_change_samples.add_argument('-n', '--new', dest='new_mobile', help='New iTwin Mobile SDK release version', required=True)
    parser_change_samples.add_argument('-ni', '--newITwin', dest='new_itwin', help='New @itwin package version', required=True)
    parser_change_samples.add_argument('-na', '--newAddOn', dest='new_add_on', help='New itwin-mobile-native-ios version', required=True)

    parser_bump_samples = sub_parsers.add_parser('bumpsamples', help='Update mobile-samples to reflect published mobile-core')
    parser_bump_samples.set_defaults(func=bumpsamples_command)
    parser_bump_samples.add_argument('-n', '--new', dest='new_mobile', help='New iTwin Mobile SDK release version')

    parser_commit = sub_parsers.add_parser('commit', help='Commit changes')
    parser_commit.set_defaults(func=commit_command)
    parser_commit.add_argument('-n', '--new', dest='new_mobile', help='New iTwin Mobile SDK release version')

    parser_push = sub_parsers.add_parser('push', help='Push changes')
    parser_push.set_defaults(func=push_command)

    parser_pr1 = sub_parsers.add_parser('pr1', help='Create PRs for mobile-sdk-ios and mobile-sdk-core')
    parser_pr1.set_defaults(func=pr1_command)
    parser_pr1.add_argument('-n', '--new', dest='new_mobile', help='New iTwin Mobile SDK release version')

    parser_pr2 = sub_parsers.add_parser('pr2', help='Create PR for mobile-ui-react')
    parser_pr2.set_defaults(func=pr2_command)
    parser_pr2.add_argument('-n', '--new', dest='new_mobile', help='New iTwin Mobile SDK release version')

    parser_pr3 = sub_parsers.add_parser('pr3', help='Create PR for mobile-samples')
    parser_pr3.set_defaults(func=pr3_command)
    parser_pr3.add_argument('-n', '--new', dest='new_mobile', help='New iTwin Mobile SDK release version')

    parser_release1 = sub_parsers.add_parser('release1', help='Create releases for mobile-sdk-ios and mobile-sdk-core')
    parser_release1.set_defaults(func=release1_command)
    parser_release1.add_argument('-n', '--new', dest='new_mobile', help='New iTwin Mobile SDK release version')
    parser_release1.add_argument('-t', '--title', dest='title', help='Release title')
    parser_release1.add_argument('--notes', dest='notes', help='Release notes')

    parser_release2 = sub_parsers.add_parser('release2', help='Create release for mobile-ui-react')
    parser_release2.set_defaults(func=release2_command)
    parser_release2.add_argument('-n', '--new', dest='new_mobile', help='New iTwin Mobile SDK release version')
    parser_release2.add_argument('-t', '--title', dest='title', help='Release title')
    parser_release2.add_argument('--notes', dest='notes', help='Release notes')

    parser_release3 = sub_parsers.add_parser('release3', help='Create release for mobile-ui-samples')
    parser_release3.set_defaults(func=release3_command)
    parser_release3.add_argument('-n', '--new', dest='new_mobile', help='New iTwin Mobile SDK release version')
    parser_release3.add_argument('-t', '--title', dest='title', help='Release title')
    parser_release3.add_argument('--notes', dest='notes', help='Release notes')

    parser_do = sub_parsers.add_parser('do', help='Run a command in each dir')
    parser_do.set_defaults(func=do_command)
    parser_do.add_argument('strings', metavar='arg', nargs='+')

    args = parser.parse_args()
    try:
        if hasattr(args, 'func'):
            args.func(args, dirs)
        else:
            parser.print_help()
    except Exception as error:
        print(error)