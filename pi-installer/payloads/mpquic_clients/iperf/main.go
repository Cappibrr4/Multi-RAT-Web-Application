package main

import (
	"crypto/tls"
	"flag"
	"fmt"
	"time"

	quic "github.com/lucas-clemente/quic-go"
	"github.com/lucas-clemente/quic-go/internal/utils"
)

// pathStatsProvider is a type assertion interface to access per-path stats
// from the session. Requires GetPathStats() to be added to session.go.
type pathStatsProvider interface {
	GetPathStats() map[uint8][3]uint64 // pathID → [sent, retrans, lost]
}

func formatBytes(b int64) string {
	mb := float64(b) / (1024 * 1024)
	return fmt.Sprintf("%.2f MBytes", mb)
}

func formatBitrate(bytes int64, seconds float64) string {
	kbits := float64(bytes) * 8 / seconds / 1000
	if kbits >= 1000 {
		return fmt.Sprintf("%.2f Mbits/sec", kbits/1000)
	}
	return fmt.Sprintf("%.0f Kbits/sec", kbits)
}

func main() {
	addr      := flag.String("addr", "127.0.0.1:6121", "server address")
	duration  := flag.Int("t", 60, "duration in seconds (like iperf -t)")
	interval  := flag.Int("i", 10, "reporting interval in seconds (like iperf -i)")
	multipath := flag.Bool("multipath", true, "enable multipath")
	verbose   := flag.Bool("v", false, "verbose debug output")
	id        := flag.Int("id", 5, "stream ID shown in output (like iperf [ID])")
	flag.Parse()

	if *verbose {
		utils.SetLogLevel(utils.LogLevelDebug)
	} else {
		utils.SetLogLevel(utils.LogLevelInfo)
	}

	sess, err := quic.DialAddr(*addr, &tls.Config{
		InsecureSkipVerify: true,
	}, &quic.Config{
		CreatePaths: *multipath,
		KeepAlive:   true,
	})
	if err != nil {
		fmt.Printf("Failed to connect to %s: %v\n", *addr, err)
		return
	}
	defer sess.Close(nil)

	stream, err := sess.OpenStreamSync()
	if err != nil {
		fmt.Printf("Failed to open stream: %v\n", err)
		return
	}

	// Print iperf-style header
	fmt.Printf("Connecting to host %s\n", *addr)
	fmt.Printf("[ %2d] local %s connected to %s\n",
		*id,
		sess.LocalAddr().String(),
		sess.RemoteAddr().String())
	fmt.Printf("[ ID] Interval           Transfer     Bitrate         Retr\n")

	buf            := make([]byte, 64*1024) // 64KB chunks like iperf
	totalBytes     := int64(0)
	intervalBytes  := int64(0)
	startTime      := time.Now()
	lastReport     := startTime
	intervalStart  := 0.0
	totalDuration  := time.Duration(*duration) * time.Second
	reportInterval := time.Duration(*interval) * time.Second

	// Send data for the specified duration
	for time.Since(startTime) < totalDuration {
		n, err := stream.Write(buf)
		if err != nil {
			break
		}
		totalBytes    += int64(n)
		intervalBytes += int64(n)

		// Print interval report
		if time.Since(lastReport) >= reportInterval {
			elapsed      := time.Since(startTime).Seconds()
			intervalSecs := elapsed - intervalStart

			fmt.Printf("[ %2d]  %4.2f-%-4.2f  sec  %s  %s\n",
				*id,
				intervalStart,
				elapsed,
				formatBytes(intervalBytes),
				formatBitrate(intervalBytes, intervalSecs))

			intervalStart = elapsed
			intervalBytes = 0
			lastReport    = time.Now()
		}
	}

	stream.Close()

	totalElapsed := time.Since(startTime).Seconds()

	// Print remaining partial interval if any
	if intervalBytes > 0 {
		intervalSecs := totalElapsed - intervalStart
		fmt.Printf("[ %2d]  %4.2f-%-4.2f  sec  %s  %s\n",
			*id,
			intervalStart,
			totalElapsed,
			formatBytes(intervalBytes),
			formatBitrate(intervalBytes, intervalSecs))
	}

	fmt.Println()

	// --- Retransmission stats ---
	// Get accurate per-path retransmission count via GetPathStats()
	// This requires GetPathStats() to be added to interface.go and session.go
	totalRetrans := uint64(0)
	if statsProvider, ok := sess.(pathStatsProvider); ok {
		pathStats := statsProvider.GetPathStats()
		fmt.Printf("Per-path statistics:\n")
		// Iterate in path ID order for consistent output
		for pathID := uint8(0); pathID < 8; pathID++ {
			if stats, exists := pathStats[pathID]; exists {
				fmt.Printf("  Path %d: sent=%d retrans=%d lost=%d\n",
					pathID, stats[0], stats[1], stats[2])
				totalRetrans += stats[1]
			}
		}
		fmt.Println()
	} else {
		// Fallback: estimate retrans from stream byte counters
		// if GetPathStats() has not been added to session.go yet
		bytesSent, _    := stream.GetBytesSent()
		bytesRetrans, _ := stream.GetBytesRetrans()
		if bytesRetrans > 0 && bytesSent > 0 {
			// Estimate packets retransmitted assuming ~1200 byte avg QUIC packet
			totalRetrans = uint64(bytesRetrans) / 1200
		}
	}

	// Sender summary line — matches iperf format exactly
	fmt.Printf("[ %2d]  %4.2f-%-4.2f  sec  %s  %s  %d             sender\n",
		*id,
		0.0,
		totalElapsed,
		formatBytes(totalBytes),
		formatBitrate(totalBytes, totalElapsed),
		totalRetrans)

	// Receiver line — server prints its own received stats to its terminal
	fmt.Printf("[ %2d]  %4.2f-%-4.2f  sec  (see server output for receiver stats)\n",
		*id,
		0.0,
		totalElapsed)

	fmt.Println()
	fmt.Println("mpquic Done.")
}
