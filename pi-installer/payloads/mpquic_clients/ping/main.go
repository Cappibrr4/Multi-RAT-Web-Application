package main

import (
	"crypto/tls"
	"flag"
	"fmt"
	"math"
	"os"
	"os/signal"
	"syscall"
	"time"

	quic "github.com/lucas-clemente/quic-go"
	"github.com/lucas-clemente/quic-go/internal/utils"
)

// pingStats tracks RTT samples like the ping command does
type pingStats struct {
	rtts []float64
}

func (p *pingStats) add(rtt float64) {
	p.rtts = append(p.rtts, rtt)
}

func (p *pingStats) min() float64 {
	if len(p.rtts) == 0 {
		return 0
	}
	m := p.rtts[0]
	for _, v := range p.rtts {
		if v < m {
			m = v
		}
	}
	return m
}

func (p *pingStats) max() float64 {
	if len(p.rtts) == 0 {
		return 0
	}
	m := p.rtts[0]
	for _, v := range p.rtts {
		if v > m {
			m = v
		}
	}
	return m
}

func (p *pingStats) avg() float64 {
	if len(p.rtts) == 0 {
		return 0
	}
	sum := 0.0
	for _, v := range p.rtts {
		sum += v
	}
	return sum / float64(len(p.rtts))
}

func (p *pingStats) mdev() float64 {
	if len(p.rtts) == 0 {
		return 0
	}
	avg := p.avg()
	sum := 0.0
	for _, v := range p.rtts {
		diff := v - avg
		sum += diff * diff
	}
	return math.Sqrt(sum / float64(len(p.rtts)))
}

func (p *pingStats) count() int {
	return len(p.rtts)
}

func main() {
	addr      := flag.String("addr", "127.0.0.1:6121", "server address")
	count     := flag.Int("c", 0, "number of pings to send (0 = unlimited like ping default)")
	interval  := flag.Float64("i", 1.0, "interval between pings in seconds")
	multipath := flag.Bool("multipath", true, "enable multipath")
	verbose   := flag.Bool("v", false, "verbose debug output")
	flag.Parse()

	if *verbose {
		utils.SetLogLevel(utils.LogLevelDebug)
	} else {
		utils.SetLogLevel(utils.LogLevelInfo)
	}

	// Connect to server
	sess, err := quic.DialAddr(*addr, &tls.Config{
		InsecureSkipVerify: true,
	}, &quic.Config{
		CreatePaths: *multipath,
		KeepAlive:   true,
	})
	if err != nil {
		fmt.Printf("Failed to connect to %s: %v\n", *addr, err)
		os.Exit(1)
	}
	defer sess.Close(nil)

	stats    := &pingStats{}
	sent     := 0
	received := 0
	seq      := 1

	// Handle Ctrl+C to print summary like ping does
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

	fmt.Printf("MPQUIC PING %s\n", *addr)

	pingLoop:
	for {
		// Check if we hit the count limit
		if *count > 0 && sent >= *count {
			break pingLoop
		}

		// Check for interrupt
		select {
		case <-sigChan:
			break pingLoop
		default:
		}

		// Open a stream, send a small payload and measure round-trip time
		// This measures QUIC-level RTT (stream open + write + read)
		start := time.Now()

		stream, err := sess.OpenStreamSync()
		if err != nil {
			fmt.Printf("ping: stream open failed: %v\n", err)
			sent++
			time.Sleep(time.Duration(*interval * float64(time.Second)))
			continue
		}

		// Send a small ping payload (8 bytes: sequence number + timestamp)
		payload := fmt.Sprintf("PING%04d", seq)
		_, err = stream.Write([]byte(payload))
		if err != nil {
			fmt.Printf("ping: write failed: %v\n", err)
			stream.Close()
			sent++
			time.Sleep(time.Duration(*interval * float64(time.Second)))
			continue
		}
		stream.Close()

		// Wait for the echo back
		buf := make([]byte, len(payload))
		replyStream, err := sess.AcceptStream()
		if err != nil {
			fmt.Printf("ping: accept reply failed: %v\n", err)
			sent++
			time.Sleep(time.Duration(*interval * float64(time.Second)))
			continue
		}

		_, err = replyStream.Read(buf)
		rtt := time.Since(start).Seconds() * 1000 // convert to ms
		replyStream.Close()

		sent++
		if err == nil {
			received++
			stats.add(rtt)
			fmt.Printf("8 bytes from %s: mpquic_seq=%d time=%.3f ms\n",
				*addr, seq, rtt)
		} else {
			fmt.Printf("Request timeout for mpquic_seq %d\n", seq)
		}

		seq++
		time.Sleep(time.Duration(*interval * float64(time.Second)))
	}

	// Print ping-style summary — matches your mptcp ping output format
	fmt.Println()
	fmt.Printf("--- %s mpquic ping statistics ---\n", *addr)

	loss := 0.0
	if sent > 0 {
		loss = float64(sent-received) / float64(sent) * 100
	}
	fmt.Printf("%d packets transmitted, %d received, %.0f%% packet loss, time %dms\n",
		sent,
		received,
		loss,
		int(float64(sent)*(*interval)*1000))

	if stats.count() > 0 {
		fmt.Printf("rtt min/avg/max/mdev = %.3f/%.3f/%.3f/%.3f ms\n",
			stats.min(),
			stats.avg(),
			stats.max(),
			stats.mdev())
	}
}
