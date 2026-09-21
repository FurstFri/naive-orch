// naive-orch-stress: SOCKS5 load generator for memory-leak hunting.
//
// It hammers one naive-orch node port (the sing-box UoT wrapper or a bare
// naive SOCKS) with short-lived TCP requests, UDP datagrams (DNS) and/or a pool
// of idle connections, and prints throughput and error counters. Combine with
// tools/memwatch.sh to see whether RSS returns to baseline afterwards.
//
//	GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -ldflags "-s -w" -o naive-orch-stress .
//
// Examples:
//
//	naive-orch-stress -socks 127.0.0.1:1106 -mode tcp  -conc 64  -duration 5m
//	naive-orch-stress -socks 127.0.0.1:1106 -mode udp  -conc 32  -duration 5m
//	naive-orch-stress -socks 127.0.0.1:1106 -mode idle -conc 500 -duration 2m
package main

import (
	"context"
	"encoding/binary"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

var (
	socksAddr = flag.String("socks", "127.0.0.1:1106", "SOCKS5 proxy address (the naive-orch node port)")
	mode      = flag.String("mode", "tcp", "tcp | udp | idle | mixed")
	conc      = flag.Int("conc", 32, "concurrent workers (idle: number of held connections)")
	duration  = flag.Duration("duration", 2*time.Minute, "how long to run")
	tcpTarget = flag.String("tcp-target", "www.gstatic.com:80", "host:port for TCP requests (plain HTTP GET /generate_204)")
	udpTarget = flag.String("udp-target", "8.8.8.8:53", "host:port for UDP datagrams (DNS A query)")
	dnsName   = flag.String("dns-name", "example.com", "name to query over UDP")
	udpReuse  = flag.Int("udp-reuse", 1, "datagrams per UDP ASSOCIATE session (1 = new session per query)")
	timeout   = flag.Duration("timeout", 8*time.Second, "per-operation timeout")
	report    = flag.Duration("report", 10*time.Second, "progress report interval")
	pause     = flag.Duration("pause", 0, "sleep between operations per worker")
	quiet     = flag.Bool("quiet", false, "do not print individual errors")
)

var ops, errs, bytesRx int64

func main() {
	flag.Parse()
	ctx, cancel := context.WithTimeout(context.Background(), *duration)
	defer cancel()

	var wg sync.WaitGroup
	start := time.Now()
	for i := 0; i < *conc; i++ {
		wg.Add(1)
		w := i
		go func() {
			defer wg.Done()
			switch *mode {
			case "tcp":
				loop(ctx, tcpOnce)
			case "udp":
				loop(ctx, udpOnce)
			case "idle":
				idleHold(ctx)
			case "mixed":
				if w%2 == 0 {
					loop(ctx, tcpOnce)
				} else {
					loop(ctx, udpOnce)
				}
			default:
				fmt.Fprintln(os.Stderr, "unknown mode", *mode)
				os.Exit(2)
			}
		}()
	}
	go func() {
		t := time.NewTicker(*report)
		defer t.Stop()
		var lastOps int64
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				o := atomic.LoadInt64(&ops)
				fmt.Printf("%6.0fs ops=%d (+%d) errs=%d rx=%dKiB\n",
					time.Since(start).Seconds(), o, o-lastOps,
					atomic.LoadInt64(&errs), atomic.LoadInt64(&bytesRx)/1024)
				lastOps = o
			}
		}
	}()
	wg.Wait()
	el := time.Since(start)
	fmt.Printf("done: mode=%s conc=%d elapsed=%.0fs ops=%d errs=%d ops/s=%.1f\n",
		*mode, *conc, el.Seconds(), ops, errs, float64(ops)/el.Seconds())
}

func loop(ctx context.Context, f func(context.Context) error) {
	for ctx.Err() == nil {
		if err := f(ctx); err != nil {
			atomic.AddInt64(&errs, 1)
			if !*quiet && ctx.Err() == nil {
				fmt.Fprintln(os.Stderr, "err:", err)
			}
			select {
			case <-ctx.Done():
			case <-time.After(200 * time.Millisecond):
			}
		} else {
			atomic.AddInt64(&ops, 1)
		}
		if *pause > 0 {
			select {
			case <-ctx.Done():
			case <-time.After(*pause):
			}
		}
	}
}

// ---- SOCKS5 primitives ------------------------------------------------------

func socksDial(ctx context.Context) (net.Conn, error) {
	d := net.Dialer{Timeout: *timeout}
	c, err := d.DialContext(ctx, "tcp", *socksAddr)
	if err != nil {
		return nil, err
	}
	_ = c.SetDeadline(time.Now().Add(*timeout))
	if _, err := c.Write([]byte{5, 1, 0}); err != nil {
		c.Close()
		return nil, err
	}
	var rep [2]byte
	if _, err := io.ReadFull(c, rep[:]); err != nil {
		c.Close()
		return nil, fmt.Errorf("greeting: %w", err)
	}
	if rep[0] != 5 || rep[1] != 0 {
		c.Close()
		return nil, fmt.Errorf("auth method rejected: %v", rep)
	}
	return c, nil
}

func socksRequest(c net.Conn, cmd byte, hostport string) (*net.UDPAddr, error) {
	host, portStr, err := net.SplitHostPort(hostport)
	if err != nil {
		return nil, err
	}
	var port uint16
	fmt.Sscanf(portStr, "%d", &port)
	req := []byte{5, cmd, 0}
	if ip := net.ParseIP(host); ip != nil && ip.To4() != nil {
		req = append(req, 1)
		req = append(req, ip.To4()...)
	} else if ip != nil {
		req = append(req, 4)
		req = append(req, ip.To16()...)
	} else {
		req = append(req, 3, byte(len(host)))
		req = append(req, host...)
	}
	req = binary.BigEndian.AppendUint16(req, port)
	if _, err := c.Write(req); err != nil {
		return nil, err
	}
	var hdr [4]byte
	if _, err := io.ReadFull(c, hdr[:]); err != nil {
		return nil, fmt.Errorf("reply: %w", err)
	}
	if hdr[1] != 0 {
		return nil, fmt.Errorf("socks reply code %d", hdr[1])
	}
	var bnd net.IP
	switch hdr[3] {
	case 1:
		var b [4]byte
		if _, err := io.ReadFull(c, b[:]); err != nil {
			return nil, err
		}
		bnd = net.IP(b[:])
	case 4:
		var b [16]byte
		if _, err := io.ReadFull(c, b[:]); err != nil {
			return nil, err
		}
		bnd = net.IP(b[:])
	case 3:
		var l [1]byte
		if _, err := io.ReadFull(c, l[:]); err != nil {
			return nil, err
		}
		b := make([]byte, l[0])
		if _, err := io.ReadFull(c, b); err != nil {
			return nil, err
		}
		bnd = net.ParseIP(string(b))
	}
	var p [2]byte
	if _, err := io.ReadFull(c, p[:]); err != nil {
		return nil, err
	}
	if bnd == nil || bnd.IsUnspecified() {
		bnd = c.RemoteAddr().(*net.TCPAddr).IP
	}
	return &net.UDPAddr{IP: bnd, Port: int(binary.BigEndian.Uint16(p[:]))}, nil
}

// ---- workloads ---------------------------------------------------------------

func tcpOnce(ctx context.Context) error {
	c, err := socksDial(ctx)
	if err != nil {
		return err
	}
	defer c.Close()
	if _, err := socksRequest(c, 1, *tcpTarget); err != nil {
		return err
	}
	host, _, _ := net.SplitHostPort(*tcpTarget)
	req := "GET /generate_204 HTTP/1.1\r\nHost: " + host + "\r\nConnection: close\r\n\r\n"
	if _, err := c.Write([]byte(req)); err != nil {
		return err
	}
	n, err := io.Copy(io.Discard, c)
	atomic.AddInt64(&bytesRx, n)
	if err != nil && !errors.Is(err, io.EOF) {
		return err
	}
	if n == 0 {
		return errors.New("empty response")
	}
	return nil
}

func udpOnce(ctx context.Context) error {
	c, err := socksDial(ctx)
	if err != nil {
		return err
	}
	defer c.Close()
	relay, err := socksRequest(c, 3, "0.0.0.0:0")
	if err != nil {
		return err
	}
	u, err := net.DialUDP("udp", nil, relay)
	if err != nil {
		return err
	}
	defer u.Close()
	host, portStr, _ := net.SplitHostPort(*udpTarget)
	var port uint16
	fmt.Sscanf(portStr, "%d", &port)
	ip4 := net.ParseIP(host).To4()
	if ip4 == nil {
		return fmt.Errorf("-udp-target must be IPv4:port, got %q", *udpTarget)
	}
	hdr := []byte{0, 0, 0, 1}
	hdr = append(hdr, ip4...)
	hdr = binary.BigEndian.AppendUint16(hdr, port)

	for i := 0; i < *udpReuse; i++ {
		q := dnsQuery(*dnsName, uint16(time.Now().UnixNano()))
		_ = u.SetDeadline(time.Now().Add(*timeout))
		if _, err := u.Write(append(append([]byte{}, hdr...), q...)); err != nil {
			return err
		}
		buf := make([]byte, 2048)
		n, err := u.Read(buf)
		if err != nil {
			return fmt.Errorf("udp read: %w", err)
		}
		atomic.AddInt64(&bytesRx, int64(n))
		if n < 10+12 {
			return errors.New("short dns reply")
		}
		if i+1 < *udpReuse {
			atomic.AddInt64(&ops, 1)
		}
	}
	return nil
}

func idleHold(ctx context.Context) {
	c, err := socksDial(ctx)
	if err != nil {
		atomic.AddInt64(&errs, 1)
		if !*quiet {
			fmt.Fprintln(os.Stderr, "err:", err)
		}
		return
	}
	defer c.Close()
	if _, err := socksRequest(c, 1, *tcpTarget); err != nil {
		atomic.AddInt64(&errs, 1)
		if !*quiet {
			fmt.Fprintln(os.Stderr, "err:", err)
		}
		return
	}
	_ = c.SetDeadline(time.Time{})
	atomic.AddInt64(&ops, 1)
	<-ctx.Done()
}

func dnsQuery(name string, id uint16) []byte {
	b := binary.BigEndian.AppendUint16(nil, id)
	b = append(b, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0) // RD, QDCOUNT=1
	for _, l := range strings.Split(strings.TrimSuffix(name, "."), ".") {
		b = append(b, byte(len(l)))
		b = append(b, l...)
	}
	b = append(b, 0, 0, 1, 0, 1) // A IN
	return b
}
