# Copyright (c) 2017-2019, AT&T Intellectual Property. All rights reserved.
# Copyright (c) 2017 Brocade Communications Systems, Inc.
# All rights reserved
#
# SPDX-License-Identifier: LGPL-2.1-only

""" twping (TWAMP client) module """

import subprocess
from threading import RLock

class TwpingJson(object):
    """
    Wrapper around a twping invocation, encoding its statistics output
    in JSON format.
    """

    TWPING_TO_JSON_BIN = "/opt/vyatta/bin/twping-output-to-json"

    def __init__(self, twping_arg_l):
        self._twping_arg_l = twping_arg_l

        self._twping_proc = None
        self._twping_json_proc = None
        self._proc_lock = RLock()

    def run(self, json_only=False, accumulate=False, callback_func=None):
        """
        Runs the given twping argument list, blocking until the tests
        complete or an error occurs.

        callback_func should be a function which accepts a single str
        argument. It will be called with each line of output.

        If json_only is True then callback_func will only be called with
        JSON encoded strings, unless an error occurs.

        This method can only be called once in the object's lifetime.

        The caller is expected to handle exceptions raised by subprocess.Popen.

        False is returned in the case of a twping or parsing error,
        otherwise True is returned.
        """
        assert self._twping_proc is None and self._twping_json_proc is None

        # If no callback is specified print the output to STDOUT
        if callback_func is None:
            callback_func = lambda line: print(line, end="", flush=True)

        # Run twping
        self._twping_proc = subprocess.Popen(self._twping_arg_l, bufsize=1,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            universal_newlines=True)

        twping_json_arg_l = [TwpingJson.TWPING_TO_JSON_BIN]
        if json_only:
            twping_json_arg_l.extend(["--json-only"])
        if accumulate:
            twping_json_arg_l.extend(["--accumulate"])

        # Run the twping output JSON encoder and connect STDIN to twping's STDOUT
        try:
            self._twping_json_proc = subprocess.Popen(twping_json_arg_l,
                bufsize=1, stdin=self._twping_proc.stdout, stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT, universal_newlines=True)
        except Exception:
            self.terminate()
            raise

        # Handle the output from the JSON encoder
        for line in self._twping_json_proc.stdout:
            callback_func(line)

        self.terminate()

        return self._twping_json_proc.returncode == 0 and \
               self._twping_proc.returncode == 0

    @property
    def _twping_running(self):
        with self._proc_lock:
            return self._twping_proc is not None and \
                   self._twping_proc.poll() is None

    @property
    def _twping_json_running(self):
        with self._proc_lock:
            return self._twping_json_proc is not None and \
                   self._twping_json_proc.poll() is None

    @property
    def running(self):
        """ Returns True if twping is running """
        return self._twping_running and self._twping_json_running

    def terminate(self):
        """ Stops the twping process """
        with self._proc_lock:
            if self._twping_json_running:
                self._twping_json_proc.terminate()
                self._twping_json_proc.wait()

            if self._twping_running:
                self._twping_proc.terminate()
                self._twping_proc.wait()
