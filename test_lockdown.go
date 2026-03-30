package main

import (
	"fmt"
	"io/ioutil"
	"log"
	"net"
	"os"

	"howett.net/plist"
)

func main() {
	fmt.Println("Testing direct connection to /var/run/lockdown.sock...")
	conn, err := net.Dial("unix", "/var/run/lockdown.sock")
	if err != nil {
		log.Fatalf("Failed to dial lockdown.sock: %v", err)
	}
	defer conn.Close()
	fmt.Println("Successfully connected to lockdown.sock!")

	// Try reading something or writing QueryType
    // This is just a proof of concept to be compiled and run on the device
}
