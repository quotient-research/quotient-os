// The Mainframe's screen. Replaces getty on tty1 and shows, in a kit-style
// window, the name, address and health of this Mainframe and, until it is
// claimed, the setup link as a QR code for the Terminal app. Any key opens a
// normal login. Standard library only; the QR code comes from qrencode.
//
// Run as root it also writes what it shows to /run/quotient-os/screen.json,
// which the screen kiosk reads (the kiosk user cannot ask for the setup code).
// --no-login is the kiosk's fallback when the graphical screen cannot start:
// the same window, and keys do nothing.
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"syscall"
	"time"
)

const (
	reset   = "\033[0m"
	bold    = "\033[1m"
	dim     = "\033[2m"
	green   = "\033[32m"
	ink     = "\033[30m"
	onGreen = "\033[42m"
	width   = 74
)

var linkRe = regexp.MustCompile(`https?://[^\s"']+`)

var noLogin bool

func main() {
	noLogin = len(os.Args) > 1 && os.Args[1] == "--no-login"
	stty("raw", "-echo")
	defer stty("sane")
	keys := make(chan struct{}, 1)
	go func() {
		r := bufio.NewReader(os.Stdin)
		for {
			if _, err := r.ReadByte(); err != nil {
				time.Sleep(time.Second)
				continue
			}
			keys <- struct{}{}
		}
	}()
	for {
		draw()
		select {
		case <-keys:
			if noLogin {
				continue
			}
			stty("sane")
			fmt.Print("\033[2J\033[H")
			if err := syscall.Exec("/bin/login", []string{"login"}, os.Environ()); err != nil {
				fmt.Fprintln(os.Stderr, "login:", err)
				os.Exit(1)
			}
		case <-time.After(15 * time.Second):
		}
	}
}

func stty(args ...string) {
	c := exec.Command("stty", args...)
	c.Stdin = os.Stdin
	_ = c.Run()
}

type state struct {
	name, version, health, link string
	addrs                       []string
	firstBoot, configured       bool
}

func collect() state {
	s := state{}
	h, _ := os.Hostname()
	s.name = h
	if b, err := os.ReadFile("/etc/quotient-os-release"); err == nil {
		s.version = strings.TrimSpace(string(b))
	}
	_, e1 := os.Stat("/var/lib/quotient-os/.firstboot-done")
	s.firstBoot = e1 == nil
	_, e2 := os.Stat("/var/lib/quotient/.configured")
	s.configured = e2 == nil
	if out, err := exec.Command("ip", "-4", "-o", "addr", "show", "scope", "global").Output(); err == nil {
		for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
			f := strings.Fields(line)
			// Pod networking (Calico's vxlan, cali*, cni*) is not an address anyone can reach.
			if len(f) >= 4 && !strings.HasPrefix(f[1], "vxlan") && !strings.HasPrefix(f[1], "cali") && !strings.HasPrefix(f[1], "cni") && !strings.HasPrefix(f[1], "flannel") {
				s.addrs = append(s.addrs, strings.Split(f[3], "/")[0]+"  ("+f[1]+")")
			}
		}
	}
	switch {
	case !s.firstBoot:
		s.health = "first boot: installing the Mainframe software"
	case !s.configured:
		s.health = "setting up (this takes a few minutes)"
	default:
		s.health = "starting"
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		req, _ := http.NewRequestWithContext(ctx, "GET", "http://localhost/api/health", nil)
		if resp, err := http.DefaultClient.Do(req); err == nil {
			resp.Body.Close()
			if resp.StatusCode == 200 {
				s.health = "healthy"
			}
		}
	}
	if s.configured {
		if out, err := exec.Command("quotient", "setup-code").Output(); err == nil {
			if m := linkRe.FindString(string(out)); m != "" {
				s.link = m
			}
		}
	}
	writeScreenState(s)
	return s
}

// writeScreenState hands the kiosk what this console shows. Only root can
// (the directory is root's); anyone else skips it.
func writeScreenState(s state) {
	if os.Geteuid() != 0 {
		return
	}
	const dir = "/run/quotient-os"
	b, err := json.Marshal(map[string]any{
		"name": s.name, "version": s.version, "health": s.health,
		"healthy": s.health == "healthy", "link": s.link, "addresses": s.addrs,
	})
	if err != nil {
		return
	}
	tmp := dir + "/.screen.json"
	if err := os.WriteFile(tmp, b, 0o640); err != nil {
		return
	}
	// Readable by the kiosk user's group only: it carries the setup code.
	if g, err := lookupGroup("quotient-kiosk"); err == nil {
		_ = os.Chown(tmp, 0, g)
	}
	_ = os.Rename(tmp, dir+"/screen.json")
}

// lookupGroup reads /etc/group (os/user needs cgo for NSS; plain files do).
func lookupGroup(name string) (int, error) {
	b, err := os.ReadFile("/etc/group")
	if err != nil {
		return 0, err
	}
	for _, line := range strings.Split(string(b), "\n") {
		f := strings.Split(line, ":")
		if len(f) >= 3 && f[0] == name {
			var gid int
			if _, err := fmt.Sscanf(f[2], "%d", &gid); err == nil {
				return gid, nil
			}
		}
	}
	return 0, fmt.Errorf("no group %s", name)
}

func draw() {
	s := collect()
	var b strings.Builder
	b.WriteString("\033[2J\033[H\n")
	// Title bar: green with an ink label, like the kit's window title bar.
	title := " QUOTIENT MAINFRAME · " + strings.ToUpper(s.name) + " "
	b.WriteString("  " + onGreen + ink + bold + pad(title, width) + reset + "\n")
	b.WriteString("  " + strings.Repeat("─", width) + "\n")
	row := func(label, value string) {
		b.WriteString(fmt.Sprintf("  %s%-10s%s %s\n", dim, label, reset, value))
	}
	if len(s.addrs) == 0 {
		row("Address", dim+"waiting for the network"+reset)
	} else {
		row("Address", s.addrs[0])
		for _, a := range s.addrs[1:] {
			row("", a)
		}
	}
	dot := dim + "○" + reset
	if s.health == "healthy" {
		dot = green + "●" + reset
	}
	row("Status", dot+" "+s.health)
	b.WriteString("\n")
	switch {
	case s.link != "":
		b.WriteString("  " + bold + "Not claimed yet." + reset + " Open the Terminal app on your phone and scan this code,\n")
		b.WriteString("  or open the link on a computer on the same network:\n\n")
		b.WriteString("  " + green + s.link + reset + "\n\n")
		if out, err := exec.Command("qrencode", "-t", "ANSIUTF8", "-m", "1", s.link).Output(); err == nil {
			for _, line := range strings.Split(strings.TrimRight(string(out), "\n"), "\n") {
				b.WriteString("    " + line + "\n")
			}
		}
	case s.health == "healthy":
		b.WriteString("  This Mainframe is claimed. Open the Terminal app on your phone to use it.\n")
	default:
		b.WriteString("  The setup code appears here when the Mainframe is ready.\n")
	}
	hint := " · press any key to sign in"
	if noLogin {
		hint = " · the console on Ctrl+Alt+F1 has a login"
	}
	b.WriteString("\n  " + dim + s.version + hint + reset + "\n")
	fmt.Print(strings.ReplaceAll(b.String(), "\n", "\r\n"))
}

func pad(s string, n int) string {
	if l := len([]rune(s)); l < n {
		return s + strings.Repeat(" ", n-l)
	}
	return s
}
