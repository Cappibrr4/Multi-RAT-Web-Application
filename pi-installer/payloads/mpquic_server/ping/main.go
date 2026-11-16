package main

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/tls"
	"crypto/x509"
	"encoding/pem"
	"flag"
	"fmt"
	"io"
	"math/big"

	quic "github.com/lucas-clemente/quic-go"
	"github.com/lucas-clemente/quic-go/internal/utils"
)

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

func handlePingSession(sess quic.Session) {
	clientAddr := sess.RemoteAddr().String()
	fmt.Printf("Ping session from %s\n", clientAddr)

	for {
		// Accept incoming ping stream
		stream, err := sess.AcceptStream()
		if err != nil {
			fmt.Printf("Session from %s closed: %v\n", clientAddr, err)
			return
		}

		// Read the ping payload
		buf := make([]byte, 256)
		n, err := io.ReadFull(stream, buf[:8])
		if err != nil || n == 0 {
			stream.Close()
			continue
		}
		payload := buf[:n]
		stream.Close()

		// Echo back on a new stream (server-initiated)
		replyStream, err := sess.OpenStreamSync()
		if err != nil {
			fmt.Printf("Failed to open reply stream: %v\n", err)
			continue
		}
		replyStream.Write(payload)
		replyStream.Close()
	}
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

	fmt.Printf("MPQUIC ping server listening on %s\n", *addr)

	for {
		sess, err := listener.Accept()
		if err != nil {
			fmt.Printf("Accept error: %v\n", err)
			continue
		}
		go handlePingSession(sess)
	}
}
