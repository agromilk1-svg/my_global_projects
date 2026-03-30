package ios

func ConnectLockdownLocal(device DeviceEntry) (*LockDownConnection, error) {
	muxConn, err := NewUsbMuxConnectionSimple()
	if err != nil {
		return nil, err
	}
	return muxConn.ConnectLockdown(device.DeviceID)
}
