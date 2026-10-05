# Muviq-4 read-only information upgrade

This upgrade uses the documented U-WAVE API v1 IR information requests. It does
not change group, band, pairing, measurement mode or data-loss settings and does
not initiate noise scans. The old undocumented `02 0D` INIT has been removed.

## Files

- `uwave_info.py`: protocol parsing and bounded inventory polling.
- `uwave_aggregator.py`: single owner of physical receivers, JSON over `/dev/ttyUWave`.
- `bind-mitutoyo-readonly.sh`: FTDI binding only.
- `upgrade-muviq4.py`: target-specific upgrade of existing `uwave-nodered` deployment,
  with backup and rollback on deployment exceptions. Not a fresh installer.
- `test_uwave.py`, `test_uwave_linux.py`: unit and isolated Linux PTY integration tests.

**Do not rerun the old `install-mitutoyo-uwave.sh` over this deployment.** It still
embeds the legacy aggregator and INIT behavior and would overwrite this upgrade.

## MQTT contract

Topics remain `mitutoyo/uwave/<USB_SERIAL>/<type>`. JSON payloads include
`receiver`, `receiverUsbSerial`, `port`, `type`, `raw`, `ts` and available IDs.
ID fields are strings; unavailable information is null, never a guessed ID.

| Type | Content |
| --- | --- |
| measurement | value, legacy channel/unit, groupId, transmitterChannel, unitName, receiverDeviceId, transmitterDeviceId |
| receiver_info | receiverDeviceId, groupId, bandId, dataLossCheckLevel, duplicateReceiver, stored noiseByBand |
| transmitter_info | transmitterDeviceId, transmitterChannel, groupId, bandId, transmitterState, measurementMode |
| status | statusCode, statusMeaning, available transmitter ID/channel |
| inventory | receiverInfo, transmitters, complete, error |
| health | usbConnected, lastReceivedAt, lastMeasurementAt, lastStatus, inventoryComplete, inventoryError |
| raw | unrecognized packet preserved verbatim |

Legacy `channel` includes API version/group/channel (e.g. `10005`); use new
`transmitterChannel` (`05`) and `groupId` (`00`) for correct channel addressing.
Legacy unit is `M`/`I`; new `unitName` is `mm`/`inch`.

Information is queried on opening USB, then every 60 seconds. Health is emitted
every 30 seconds and on USB open/close. Inventory has completion/error markers;
individual information records have observation times. USB presence does not
prove a working wireless link. Transmitter state is the receiver's reported state,
not a fresh instrument ping. Status 51 is normal end-of-search, not an alarm.
Measurements received before inventory resolution
can have null device IDs. Noise values are stored scan results, not live RSSI;
255 is represented as null. Battery-low events are supported, battery percentage
and undocumented firmware details are not invented.

Outgoing commands on the virtual port are ignored. Do not add Node-RED INIT nodes.
The output queue is bounded at 1 MiB and is not a durable offline spool. MQTT QoS 1
is not a guarantee against data loss before publication or during power failure.

## Verify

```sh
python3 -m unittest -v test_uwave test_uwave_linux
sudo systemctl status mitutoyo-uwave-aggregator
sudo journalctl -u mitutoyo-uwave-aggregator -n 30 --no-pager
```

Subscribe to `mitutoyo/uwave/<USB_SERIAL>/#` using the existing broker credentials.
Do not open the physical serial port with another reader while the service runs.

Protocol reference: Mitutoyo U-WAVEPAK manual 99MAL216A, section 6.1:
https://manuals.plus/m/2f120eeb3093100ebcc09e19e7f74fb0feb3bdc95e7f9736b91ad4596ff5239d_optim.pdf
