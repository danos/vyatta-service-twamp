#!/usr/bin/python3

# Module: show-twamp-sessions.py
#
# **** License ****
# Copyright (c) 2014-2017, Brocade Communications Systems, Inc.
# All Rights Reserved.
#
# Script to display TWAMP server session information
#
# **** End License ****

import sys
import os
import socket
import argparse
from vyatta import configd

SESSION_FILES_DIR    = "/var/run/twamp"
CONTROL_FILE_PID_SEP = "-"
CONTROL_FILE_PREFIX  = "control" + CONTROL_FILE_PID_SEP

RT_INST_BASE_TREE    = "routing routing-instance"
TWAMP_BASE_TREE      = "service twamp server"

CHVRF                = "/usr/sbin/chvrf"
CHVRF_EXISTS         = os.path.isfile(CHVRF)

class ControlSession (object):

    def __init__(self, pid, origAddr, authMode):
        self.pid = pid
        self.origAddr = origAddr
        self.authMode = authMode
        self.testSessions = []
        self.activeSessions = 0
        self.inactiveSessions = 0

    def getPid(self):
        return self.pid

    def getOrigAddr(self):
        return self.origAddr

    def getTestSessions(self):
        return self.testSessions

    def addTestSession(self, testSession):
        if testSession.getStatus() == 'ACTIVE':
            self.activeSessions+=1
        else:
            self.inactiveSessions+=1
        self.testSessions.append(testSession)

    def getTotalActiveSessions(self):
        return self.activeSessions

    def getTotalInactiveSessions(self):
        return self.inactiveSessions

    def getTotalAllSessions(self):
        return self.activeSessions + self.inactiveSessions

    def ipMatch(self, ip):
        for sessionIp, port in self.getIpAndPortList(self.origAddr):
            if ip == sessionIp:
                return True
        return False

    def getMaxLengthSenderAddr(self):
        max = 1 # not 0 since cannot format() string with width 0
        for testSession in self.testSessions:
            if len(testSession.getSenderAddr()) > max:
                max = len(testSession.getSenderAddr())
        return max

    def getMaxLengthReflectorAddr(self):
        max = 1 # not 0 since cannot format() string with width 0
        for testSession in self.testSessions:
            if len(testSession.getReflectorAddr()) > max:
                max = len(testSession.getReflectorAddr())
        return max

    def toString(self):
        ip, port = ControlSession.getIpAndPortOrUnknown(self.origAddr)
        return '--> Control Session initiated by [' + ip + ']:' + port \
                + ' in ' + self.authMode + ' mode'

    def summaryToString(self):
        ip, port = ControlSession.getIpAndPortOrUnknown(self.origAddr)
        return 'Initiated by [' + ip + ']:' + port + ' in ' + self.authMode + \
        ' mode\n' + '\tActive sessions: ' + str(self.activeSessions) + \
        '\n\tInactive sessions: ' + str(self.inactiveSessions)

    # returns list of tuples containing ip address and port
    @staticmethod
    def getIpAndPortList(addr):
        try:
            splitAddr = addr.split('[')[1]
            hostName = splitAddr.split(']')[0]
            # Set to string after "]:"
            port = splitAddr.split(']:')[1]
        except IndexError:
            return []

        return [ (hostName, port) ]

    @staticmethod
    def getIpAndPortOrUnknown(addr):
        list = ControlSession.getIpAndPortList(addr)
        if len(list) == 0:
            list = [ ('unknown', '0' ) ]        
        return list[0]

class TestSession (object):

    def __init__(self, sid, testSenderAddr, reflectorAddr, status, dscp):
        self.sid = sid;
        self.testSenderAddr = testSenderAddr
        self.reflectorAddr = reflectorAddr
        self.status = status
        self.dscp = dscp

    def getSID(self):
        return self.sid

    def getReflectorAddr(self):
        ip, port = ControlSession.getIpAndPortOrUnknown(self.reflectorAddr)
        return '[' + ip + ']:' + port

    def getSenderAddr(self):
        ip, port = ControlSession.getIpAndPortOrUnknown(self.testSenderAddr)
        return '[' + ip + ']:' + port

    def getStatus(self):
        return self.status

    def getDSCP(self):
        return self.dscp

    def getFormattedData(self, maxSenderAddrLen, maxReflectorAddrLen):
        formatStr = '{0:32}    {1:' + str(maxSenderAddrLen) +'}    {2:'\
                    + str(maxReflectorAddrLen) + '}    {3:8}    {4:5}'
        return formatStr.format(self.sid, self.getSenderAddr(), \
                                self.getReflectorAddr(), \
                                self.status, self.dscp)

def showAll():
    totalNumberSessions = 0
    totalNumberActiveSessions = 0
    output = ''
    for pid in allControlSessions:
        controlSession = allControlSessions[pid]
        output += controlSession.toString()
        totalNumberActiveSessions += controlSession.getTotalActiveSessions()
        totalNumberSessions += controlSession.getTotalAllSessions()
        maxSenderAddrLen = controlSession.getMaxLengthSenderAddr()
        maxReflectorAddrLen = controlSession.getMaxLengthReflectorAddr()
        output += getTestSessionHeader(maxSenderAddrLen, maxReflectorAddrLen)
        output += '\n\t'
        for testSession in controlSession.getTestSessions():
            output += testSession.getFormattedData(maxSenderAddrLen, maxReflectorAddrLen)
            output += '\n\t'
        output = output[:-1] # remove last tab
        output += '<--\n\n'
    print('Total number of sessions: ' + str(totalNumberSessions))
    print('Total number of active sessions: ' + str(totalNumberActiveSessions))
    print('\n')
    print(output)

def showClient(ip):
    totalActiveTestSessions = 0
    totalInactiveTestSessions = 0
    match = False
    output = ''

    for pid in allControlSessions:
        controlSession = allControlSessions[pid]
        if controlSession.ipMatch(ip):
            output += controlSession.toString()
            totalActiveTestSessions += controlSession.getTotalActiveSessions()
            totalInactiveTestSessions += controlSession.getTotalInactiveSessions()
            maxSenderAddrLen = controlSession.getMaxLengthSenderAddr()
            maxReflectorAddrLen = controlSession.getMaxLengthReflectorAddr()
            output += getTestSessionHeader(maxSenderAddrLen, maxReflectorAddrLen)
            output += '\n\t'
            for testSession in controlSession.getTestSessions():
                output += testSession.getFormattedData(maxSenderAddrLen, maxReflectorAddrLen)
                output += '\n\t'
            output = output[:-1] # remove last tab
            output += '<--\n\n'
    totalConnections = totalActiveTestSessions + totalInactiveTestSessions
    print('Total connections:       ' + str(totalConnections))
    print('Total active test sessions:    ' + str(totalActiveTestSessions))
    print('Total inactive test sessions:  ' + str(totalInactiveTestSessions))
    print('\n')
    print(output)

def showSummary():
    totalConnectedClients = 0
    totalActiveTestSessions = 0
    totalInactiveTestSessions = 0
    output = ''
    clientN = 0

    for pid in allControlSessions:
        totalConnectedClients += 1
        controlSession = allControlSessions[pid]
        totalActiveTestSessions += controlSession.getTotalActiveSessions()
        totalInactiveTestSessions += controlSession.getTotalInactiveSessions()
        output += 'Client ' + str(clientN) + ': ' 
        output += controlSession.summaryToString() + '\n\n'
        clientN += 1
    print('Total connected clients:       ' + str(totalConnectedClients))
    print('Total active test sessions:    ' + str(totalActiveTestSessions))
    print('Total inactive test sessions:  ' + str(totalInactiveTestSessions))
    print('\n')
    print(output)

def getTestSessionHeader(maxSenderAddrLen, maxReflectorAddrLen): 
    formatStr = '\n\n\t{0:32}    {1:' + str(maxSenderAddrLen) +'}    {2:' + \
                 str(maxReflectorAddrLen) + '}    {3:8}    {4:5}'
    return formatStr.format('Session ID', 'Sender', 'Reflector', 'Status', 'DSCP')

def parseArgs():
    """ Define and parse the arguments to the script """

    arg_parser = argparse.ArgumentParser(description = "Show TWAMP server session information")
    mode_group = arg_parser.add_mutually_exclusive_group(required=True)
    mode_group.add_argument("--all", action = "store_true",
                                 help = "Show detailed information for all sessions")
    mode_group.add_argument("--summary", action = "store_true",
                                 help = "Show summary information for all sessions")
    mode_group.add_argument("--client",
                            help = "Show session information for a particular client IP address",
                            metavar = "IP")

    arg_parser.add_argument("--routing-instance",
                            help = "Show session information for the given routing instance, " +
                                    "otherwise sessions of the default instance are shown",
                            metavar = "instance", default = "default")

    return arg_parser.parse_args()

def validateArgs(args):
    if args.client is not None:
        ip = args.client
        if ip != 'localhost':
            try:
                socket.inet_aton(ip)
            except:
                try:
                    socket.inet_pton(socket.AF_INET6, ip)
                except:
                    print('Invalid client IP address.')
                    sys.exit(1)

    assert args.routing_instance is not None

    # The routing instance name is used as part of a path, so don't risk
    # path separators being part of the name. Path separators aren't a
    # valid character for a routing instance name anyway.
    if os.sep in args.routing_instance:
        print("Invalid routing instance name")
        sys.exit(1)

def parseAuthMode(authMode):
    if authMode == "O":
        authMode = "Open"
    elif authMode == "M":
        authMode = "Mixed"
    elif authMode == "A":
        authMode = "Authenticated"
    elif authMode == "E":
        authMode = "Encrypted"
    return authMode

####### BEGIN #######
args = parseArgs()
validateArgs(args)

cfg_client = configd.Client()
allControlSessions = {} # pid->controlSession

if args.routing_instance != "default":
    if not CHVRF_EXISTS:
        print("No support for routing instances!")
        sys.exit(1)

    if not cfg_client.node_exists(cfg_client.AUTO, "{} {}".format(
            RT_INST_BASE_TREE, args.routing_instance)):
        print("Routing instance '{}' has not been configured".format(args.routing_instance))
        sys.exit(1)

    if not cfg_client.node_exists(cfg_client.AUTO, "{} {} {}".format(
            RT_INST_BASE_TREE, args.routing_instance, TWAMP_BASE_TREE)):
        print("TWAMP is not configured in routing instance '{}'".format(args.routing_instance))
        sys.exit(1)

    SESSION_FILES_DIR += "-{}".format(args.routing_instance)
else:
    if not cfg_client.node_exists(cfg_client.AUTO, TWAMP_BASE_TREE):
        msg = "TWAMP is not configured"

        if CHVRF_EXISTS:
            msg += " in the default routing instance"

        print(msg)
        sys.exit(1)

if not os.path.exists(SESSION_FILES_DIR):
    print("No TWAMP session details are available")
    sys.exit(1)

for file in os.listdir(SESSION_FILES_DIR):
    if not file.startswith(CONTROL_FILE_PREFIX):
        continue

    filePath = os.path.join(SESSION_FILES_DIR, file)

    try:
        f = open(filePath, 'r')
        lines = f.readlines()
    except IOError:
        print("Failed to read '{}'".format(filePath))
        continue
    finally:
        try:
            f.close()
        except:
            pass

    try:
        pid = file.split(CONTROL_FILE_PID_SEP)[1]
    except IndexError:
        print("Failed to determine PID from '{}'".format(filePath))
        continue

    try:
        controlLine = lines[0].rstrip('\n')
        controlLineSplit = controlLine.split('\t')
        origAddr = controlLineSplit[0]
        authMode = controlLineSplit[1]
    except IndexError:
        print("Failed to parse control session data in '{}'".format(filePath))
        continue

    authMode = parseAuthMode(authMode)
    controlSession = ControlSession(pid, origAddr, authMode)

    # 1 line -> 1 test-session
    for n in range(1, len(lines)):
        try:
            testLineSplit = lines[n].rstrip('\n').split('\t')
            sid = testLineSplit[0]
            testSenderAddr = testLineSplit[1]
            reflectorAddr = testLineSplit[2]
            status = testLineSplit[3]
            dscp = testLineSplit[4]
        except IndexError:
            print("Failed to parse test session data in '{}' (line {})".format(
                    filePath, n+1))
            continue

        testSession = TestSession(sid, testSenderAddr, reflectorAddr, status, dscp)
        controlSession.addTestSession(testSession)

    allControlSessions[pid] = controlSession


if not allControlSessions:
    msg = 'No active TWAMP sessions'

    if CHVRF_EXISTS:
        if args.routing_instance == "default":
            msg += " in the default routing instance"
        elif args.routing_instance is not None:
            msg += " in routing instance '{}'".format(args.routing_instance)

    print(msg)
    sys.exit(0)

if args.all:
    showAll()
elif args.summary:
    showSummary()
elif args.client:
    showClient(args.client)
else:
    # parse_args() should mean we never reach here
    print('Unrecognized argument')
    sys.exit(1)

