package main

import (
	"crypto/tls"
	"io"
	"log"
	"net"
	"os"

	"howett.net/plist"
)

type PairRecord struct {
	HostCertificate []byte `plist:"HostCertificate"`
	HostPrivateKey  []byte `plist:"HostPrivateKey"`
	RootCertificate []byte `plist:"RootCertificate"`
}

func main() {
	if len(os.Args) < 5 {
		log.Fatalf("Usage: %s <listen_port> <target_ip> <target_port> <pair_record_path>", os.Args[0])
	}
	listenPort := os.Args[1]
	targetIP := os.Args[2]
	targetPort := os.Args[3]
	pairRecordPath := os.Args[4]

	data, err := os.ReadFile(pairRecordPath)
	if err != nil {
		log.Fatalf("Read PairRecord: %v", err)
	}

	var pr PairRecord
	if err := plist.Unmarshal(data, &pr); err != nil {
		log.Fatalf("Parse PairRecord: %v", err)
	}

	cert, err := tls.X509KeyPair(pr.HostCertificate, pr.HostPrivateKey)
	if err != nil {
		log.Fatalf("Load KeyPair: %v", err)
	}

	config := &tls.Config{
		Certificates:       []tls.Certificate{cert},
		InsecureSkipVerify: true,
	}

	l, err := net.Listen("tcp", "127.0.0.1:"+listenPort)
	if err != nil {
		log.Fatalf("Listen: %v", err)
	}
	defer l.Close()

	for {
		c, err := l.Accept()
		if err != nil {
			log.Printf("Accept: %v", err)
			continue
		}
		go handle(c, targetIP, targetPort, config)
	}
}

func handle(c net.Conn, targetIP string, targetPort string, config *tls.Config) {
	defer c.Close()
	t, err := tls.Dial("tcp", targetIP+":"+targetPort, config)
	if err != nil {
		log.Printf("Dial %s:%s err: %v", targetIP, targetPort, err)
		return
	}
	defer t.Close()

	go io.Copy(t, c)
	io.Copy(c, t)
}
