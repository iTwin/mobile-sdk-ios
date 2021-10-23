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
        ('("version": )"' + args.oldVersion, '\\1"' + args.newVersion),
        ('("@bentley/[a-z-]*"): "' + args.oldBentley, '\\1: "' + args.newBentley)
    ])

def modifyPackageSwift(args, fileName):
    print "Processing: " + os.path.realpath(fileName)
    replaceAll(fileName, [
        ('(https://github.com/iTwin/mobile-ios-package", .exact\()"' + args.oldIos, '\\1"' + args.newIos)
    ])

def modifyPodspec(args, fileName):
    print "Processing: " + os.path.realpath(fileName)
    replaceAll(fileName, [
        ('(spec.version.*= )"' + args.oldVersion, '\\1"' + args.newVersion),
        ('(spec.dependency +"itwin-mobile-ios-package", +"~>) ' + args.oldIos, '\\1 ' + args.newIos)
    ])

def changeCommand(args):
    dir = getExecutingDirectory()
    modifyPackageSwift(args, dir + '/Package.swift')
    modifyPackageSwift(args, dir + '/Package@swift-5.5.swift')
    modifyPodspec(args, dir + '/itwin-mobile-sdk.podspec')
    modifyPackageJson(args, dir + '/../mobile-sdk-core/package.json')
    modifyPackageJson(args, dir + '/../mobile-ui-react/package.json')
    modifyPackageJson(args, dir + '/../mobile-sdk-samples/ios/MobileStarter/react-app/package.json')

def commitDir(args, dir):
    dir = os.path.realpath(dir)
    print "Committing in dir: " + dir;
    rc = subprocess.call(['git', 'diff', '--quiet'], cwd=dir)
    if rc:
        subprocess.check_call(['git', 'add', '.'], cwd=dir)
        subprocess.check_call(['git', 'commit', '-m', 'v' + args.newVersion], cwd=dir)
    else:
        print "Nothing to commit."

def commitCommand(args):
    commitDir(args, '.')
    commitDir(args, '../mobile-sdk-core')
    commitDir(args, '../mobile-ui-react')
    commitDir(args, '../mobile-sdk-samples')

def releaseCommand(args):
    print "Release not implemented yet"

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Script for helping with creating a new Mobile SDK version.')
    sub_parsers = parser.add_subparsers(title='Commands', metavar='')
    
    parser_change = sub_parsers.add_parser('change', help='Change version')
    parser_change.set_defaults(func=changeCommand)
    parser_change.add_argument('-n', '--new', dest='newVersion', required=True, help='New release version')
    parser_change.add_argument('-o', '--old', dest='oldVersion', required=True, help='Old release version')
    parser_change.add_argument('-nb', '--newBentley', dest='newBentley', required=True, help='New @bentley package version')
    parser_change.add_argument('-ob', '--oldBentley', dest='oldBentley', required=True, help='Old @bentley package version')
    parser_change.add_argument('-ni', '--newIos', dest='newIos', required=True, help='New itwin-mobile-ios-package version')
    parser_change.add_argument('-oi', '--oldIos', dest='oldIos', required=True, help='Old itwin-mobile-ios-package version')

    parser_commit = sub_parsers.add_parser('commit', help='Commit changes')
    parser_commit.set_defaults(func=commitCommand)
    parser_commit.add_argument('-n', '--new', dest='newVersion', required=True, help='New release version')

    parser_release = sub_parsers.add_parser('release', help='Create releases')
    parser_release.set_defaults(func=releaseCommand)
    parser_release.add_argument('-n', '--new', dest='newVersion', required=True, help='New release version')

    args = parser.parse_args()
    args.func(args)