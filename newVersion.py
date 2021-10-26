#!/usr/bin/env python
import argparse
import fileinput
import re
import subprocess
import sys
import os

def getExecutingDirectory():
    return os.path.dirname(os.path.realpath(__file__))

def replaceAll(fileName, replacements):
    for line in fileinput.input(fileName, inplace=1):
        for (searchExp, replaceExp) in replacements:
            line = re.sub(searchExp, replaceExp, line)
        sys.stdout.write(line)

def modifyPackageJson(args, fileName):
    print "Processing: " + os.path.realpath(fileName)
    replaceAll(fileName, [
        ('("version": )"[\.0-9]+', '\\1"' + args.newVersion),
        ('("@bentley/[a-z-0-9]*"): "2\.19\.[0-9]+', '\\1: "' + args.newBentley)
    ])

def modifyPackageSwift(args, fileName):
    print "Processing: " + os.path.realpath(fileName)
    replaceAll(fileName, [('(mobile-ios-package", .exact\()"[\.0-9]+', '\\1"' + args.newIos)])

def modifyPodspec(args, fileName):
    print "Processing: " + os.path.realpath(fileName)
    replacements = [('(spec.version.*= )"[\.0-9]+', '\\1"' + args.newVersion)]
    replacements.append(('(spec.dependency +"itwin-mobile-ios-package", +"~>) [\.0-9]+', '\\1 ' + args.newIos))
    replaceAll(fileName, replacements)

def changeCommand(args, dirs):
    dir = executingDir
    modifyPackageSwift(args, dir + '/Package.swift')
    modifyPackageSwift(args, dir + '/Package@swift-5.5.swift')
    modifyPodspec(args, dir + '/itwin-mobile-sdk.podspec')
    modifyPackageJson(args, dir + '/../mobile-sdk-core/package.json')
    modifyPackageJson(args, dir + '/../mobile-ui-react/package.json')
    modifyPackageJson(args, dir + '/../mobile-sdk-samples/ios/MobileStarter/react-app/package.json')

def commitDir(args, dir):
    print "Committing in dir: " + dir
    rc = subprocess.call(['git', 'diff', '--quiet'], cwd=dir)
    if rc:
        subprocess.check_call(['git', 'add', '.'], cwd=dir)
        subprocess.check_call(['git', 'commit', '-m', 'v' + args.newVersion], cwd=dir)
    else:
        print "Nothing to commit."

def commitCommand(args, dirs):
    if not args.newVersion:
        args.newVersion = getNextRelease()

    if args.newVersion:
        for dir in dirs:
            commitDir(args, dir)

def pushDir(args, dir):
    dir = os.path.realpath(dir)
    print "Pushing in dir: " + dir;
    subprocess.check_call(['git', 'push'], cwd=dir)

def pushCommand(args, dirs):
    for dir in dirs:
        pushDir(args, dir)

def releaseDir(args, dir):
    dir = os.path.realpath(dir)
    print "Releasing in dir: " + dir
    subprocess.check_call(['gh', 'release', 'create', '-t', 'v' + args.newVersion, args.newVersion], cwd=dir)
    subprocess.check_call(['git', 'pull'], cwd=dir)

def releaseUpload(args, dir, fileName):
    dir = os.path.realpath(dir)
    print "Uploading in dir: {} file: {}".format(dir, fileName)
    subprocess.check_call(['gh', 'release', 'upload', args.newVersion, fileName], cwd=dir)

def releaseCommand(args, dirs):
    if not args.newVersion:
        args.newVersion = getNextRelease()
    print "Releasing version: " + args.newVersion

    if args.newVersion:
        for dir in dirs:
            releaseDir(args, dir)
        releaseUpload(args, '.', 'itwin-mobile-sdk.podspec')

def getLastRelease():
    result = subprocess.check_output(['git', 'tag'], cwd=executingDir)
    tags = result.splitlines()
    if isinstance(tags, list):
        return tags[len(tags)-1]

def getNextRelease():
    lastRelease = getLastRelease()
    if lastRelease:
        parts = lastRelease.split('.')
        if len(parts) == 3:
            parts[2] = str(int(parts[2]) + 1)
            newRelease = '.'.join(parts)
            return newRelease

def getLatestBentleyVersion():
    return subprocess.check_output(['npm', 'show', '@bentley/imodeljs-backend', 'version']).strip()

def getLatestNativeVersion():
    deps = subprocess.check_output(['npm', 'show', '@bentley/imodeljs-backend', 'dependencies'])
    match = re.search("'@bentley/imodeljs-native': '([0-9\.]+)'", deps)
    if match and len(match.groups()) == 1:
        return match.group(1)

def getLastMobilePackageVersion(packageSwiftFile):
    with open(packageSwiftFile) as file:
        for line in file:
            match = re.search('mobile-ios-package", .exact\("([0-9\.]+)', line)
            if match and len(match.groups()) == 1:
                return match.group(1)

def bumpCommand(args, dirs):
    foundAll = False
    newRelease = getNextRelease()
    if newRelease:
        print "New release: " + newRelease
        imodeljsVersion = getLatestBentleyVersion()
        print "@bentley version: " + imodeljsVersion
        addOnVersion = getLatestNativeVersion()
        if addOnVersion:
            foundAll = True
            print "mobile-ios-package version: " + addOnVersion           

    if foundAll:
        args.newVersion = newRelease
        args.newBentley = imodeljsVersion
        args.newIos = addOnVersion
        changeCommand(args, dirs)
    else:
        print "Unable to determine all versions."

def doCommand(args, dirs):
    if args.strings:
        allArgs = ' '.join(args.strings)
        args = allArgs.split()
        for dir in dirs:
            subprocess.call(args, cwd=dir)
    
if __name__ == '__main__':
    executingDir = getExecutingDirectory()
    dirs = []
    for dir in ['.', '../mobile-sdk-core', '../mobile-ui-react', '../mobile-sdk-samples']:
        dirs.append(os.path.realpath(executingDir + '/' + dir))

    parser = argparse.ArgumentParser(description='Script for helping with creating a new Mobile SDK version.')
    sub_parsers = parser.add_subparsers(title='Commands', metavar='')
    
    parser_change = sub_parsers.add_parser('change', help='Change version')
    parser_change.set_defaults(func=changeCommand)
    parser_change.add_argument('-n', '--new', dest='newVersion', help='New release version', required=True)
    parser_change.add_argument('-nb', '--newBentley', dest='newBentley', help='New @bentley package version', required=True)
    parser_change.add_argument('-ni', '--newIos', dest='newIos', help='New itwin-mobile-ios-package version', required=True)

    parser_commit = sub_parsers.add_parser('commit', help='Commit changes')
    parser_commit.set_defaults(func=commitCommand)
    parser_commit.add_argument('-n', '--new', dest='newVersion', help='New release version')

    parser_push = sub_parsers.add_parser('push', help='Push changes')
    parser_push.set_defaults(func=pushCommand)

    parser_release = sub_parsers.add_parser('release', help='Create releases')
    parser_release.set_defaults(func=releaseCommand)
    parser_release.add_argument('-n', '--new', dest='newVersion', help='New release version')

    parser_bump = sub_parsers.add_parser('bump', help='Create new point release')
    parser_bump.set_defaults(func=bumpCommand)

    parser_do = sub_parsers.add_parser('do', help='Run a command in each dir')    
    parser_do.set_defaults(func=doCommand)
    parser_do.add_argument('strings', metavar='arg', nargs='+')

    args = parser.parse_args()
    args.func(args, dirs)
    