package main

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/tls"
	"crypto/x509"
	"encoding/binary"
	"encoding/pem"
	"flag"
	"fmt"
	"io"
	"math/big"
	"time"

	quic "github.com/lucas-clemente/quic-go"
	"github.com/lucas-clemente/quic-go/internal/utils"
)

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

func handleSession(sess quic.Session, id int) {
	stream, err := sess.AcceptStream()
	if err != nil {
		fmt.Printf("stream accept error: %v\n", err)
		return
	}

	clientAddr := sess.RemoteAddr().String()
	fmt.Printf("[ %2d] local %s connected to %s\n",
		id,
		sess.LocalAddr().String(),
		clientAddr)
	fmt.Printf("[ ID] Interval           Transfer     Bitrate\n")

	buf           := make([]byte, 64*1024)
	totalBytes    := int64(0)
	intervalBytes := int64(0)
	startTime     := time.Now()
	lastReport    := startTime
	intervalStart := 0.0
	reportInterval := 10 * time.Second

	// Drain incoming data, counting bytes
	for {
		n, err := stream.Read(buf)
		if n > 0 {
			totalBytes    += int64(n)
			intervalBytes += int64(n)

			// Print interval report
			if time.Since(lastReport) >= reportInterval {
				elapsed      := time.Since(startTime).Seconds()
				intervalSecs := elapsed - intervalStart

				fmt.Printf("[ %2d]  %4.2f-%-4.2f  sec  %s  %s\n",
					id,
					intervalStart,
					elapsed,
					formatBytes(intervalBytes),
					formatBitrate(intervalBytes, intervalSecs))

				intervalStart = elapsed
				intervalBytes = 0
				lastReport    = time.Now()
			}
		}
		if err == io.EOF || err != nil {
			break
		}
	}

	totalElapsed := time.Since(startTime).Seconds()

	// Print remaining partial interval
	if intervalBytes > 0 {
		intervalSecs := totalElapsed - intervalStart
		fmt.Printf("[ %2d]  %4.2f-%-4.2f  sec  %s  %s\n",
			id,
			intervalStart,
			totalElapsed,
			formatBytes(intervalBytes),
			formatBitrate(intervalBytes, intervalSecs))
	}

	fmt.Println()

	// Receiver summary line
	fmt.Printf("[ %2d]  %4.2f-%-4.2f  sec  %s  %s             receiver\n",
		id,
		0.0,
		totalElapsed,
		formatBytes(totalBytes),
		formatBitrate(totalBytes, totalElapsed))

	// Send received byte count back to client as 8-byte little-endian int
	// so the client can print its receiver line accurately
	replyStream, err := sess.OpenStreamSync()
	if err == nil {
		buf8 := make([]byte, 8)
		binary.LittleEndian.PutUint64(buf8, uint64(totalBytes))
		replyStream.Write(buf8)
		replyStream.Close()
	}

	fmt.Printf("\nmpquic Done.\n")
}

func generateTLSConfig() *tls.Config {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		panic(err)
	}
	template := x509.Certificate{SerialNumber: big.NewInt(1)}
	certDER, err := x509.CreateCertificate(rand.Reader, &template, &template, &key.PublicKey, key)
	if err != nil {
		panic(err)
	}
	keyPEM := pem.EncodeToMemory(&pem.Block{
		Type:  "RSA PRIVATE KEY",
		Bytes: x509.MarshalPKCS1PrivateKey(key),
	})
	certPEM := pem.EncodeToMemory(&pem.Block{
		Type:  "CERTIFICATE",
		Bytes: certDER,
	})
	tlsCert, err := tls.X509KeyPair(certPEM, keyPEM)
	if err != nil {
		panic(err)
	}
	return &tls.Config{Certificates: []tls.Certificate{tlsCert}}
}

func main() {
	addr    := flag.String("addr", "0.0.0.0:6121", "bind address")
	verbose := flag.Bool("v", false, "verbose debug output")
	flag.Parse()

	if *verbose {
		utils.SetLogLevel(utils.LogLevelDebug)
	} else {
		utils.SetLogLevel(utils.LogLevelInfo)
	}

	listener, err := quic.ListenAddr(*addr, generateTLSConfig(), &quic.Config{
		CreatePaths: true,
		KeepAlive:   true,
	})
	if err != nil {
		panic(err)
	}
	fmt.Printf("Server listening on %s\n", *addr)
	fmt.Printf("-----------------------------------------------------------\n")

	sessionID := 5 // Start at 5 like iperf does
	for {
		sess, err := listener.Accept()
		if err != nil {
			fmt.Printf("Accept error: %v\n", err)
			continue
		}
		go handleSession(sess, sessionID)
		sessionID++
	}
}
