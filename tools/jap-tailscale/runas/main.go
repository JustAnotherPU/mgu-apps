// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 JustAnotherPU
//
// jap-runas UID PROGRAM [ARGS...]: drops root to UID:UID (no supplementary groups) and runs PROGRAM.
// The unit's systemd refuses User= for a uid without an account, and the uplink routes traffic by uid.
package main

import (
	"fmt"
	"os"
	"strconv"
	"syscall"
)

func main() {
	if len(os.Args) < 3 {
		fmt.Fprintln(os.Stderr, "usage: jap-runas UID PROGRAM [ARGS...]")
		os.Exit(2)
	}
	uid, err := strconv.Atoi(os.Args[1])
	if err != nil || uid <= 0 || uid > 65533 {
		fmt.Fprintln(os.Stderr, "jap-runas: UID must be a number from 1 to 65533")
		os.Exit(2)
	}
	if err := syscall.Setgroups(nil); err != nil {
		fail("setgroups", err)
	}
	if err := syscall.Setgid(uid); err != nil {
		fail("setgid", err)
	}
	if err := syscall.Setuid(uid); err != nil {
		fail("setuid", err)
	}
	if syscall.Getuid() != uid || syscall.Geteuid() != uid || syscall.Getgid() != uid || syscall.Setuid(0) == nil {
		fmt.Fprintln(os.Stderr, "jap-runas: root was not dropped")
		os.Exit(1)
	}
	fail("exec "+os.Args[2], syscall.Exec(os.Args[2], os.Args[2:], os.Environ()))
}

func fail(what string, err error) {
	fmt.Fprintf(os.Stderr, "jap-runas: %s: %v\n", what, err)
	os.Exit(1)
}
